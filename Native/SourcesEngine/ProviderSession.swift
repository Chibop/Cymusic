import Foundation

typealias SourceJSON = [String: Any]
struct SourceFailure: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

@MainActor final class ProviderSession {
    private var runtime: CyMusicUserApiRuntime!
    private var generation = ""
    private var pending = [String: CheckedContinuation<SourceJSON, Error>]()
    private var http = [String: Task<Void, Never>]()
    private let network = URLSession(configuration: .ephemeral)
    private var capabilities = [String: SourceJSON]()

    init(preload: URL?) {
        runtime = CyMusicUserApiRuntime(preload: preload) { [weak self] event in
            guard let action = event["action"] as? String, let generation = event["generation"] as? String,
                  let data = event["data"] as? String else { return }
            Task { @MainActor in self?.receive(action, generation: generation, json: data) }
        }
        runtime.startObserving()
    }

    func close() {
        generation = ""
        runtime.invalidate()
        network.invalidateAndCancel()
        for task in http.values { task.cancel() }
        http.removeAll()
        for request in pending.values { request.resume(throwing: CancellationError()) }
        pending.removeAll()
    }

    private func wait(_ key: String, seconds: UInt64, start: () -> Void) async throws -> SourceJSON {
        let timer = Task {
            try await Task.sleep(nanoseconds: seconds * 1_000_000_000)
            pending.removeValue(forKey: key)?.resume(throwing: SourceFailure("音源响应超时"))
        }
        defer { timer.cancel() }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                pending[key] = continuation
                start()
            }
        } onCancel: {
            Task { @MainActor in self.pending.removeValue(forKey: key)?.resume(throwing: CancellationError()) }
        }
    }

    func load(_ item: SourceScript) async throws -> [String: String]? {
        var info = item.metadata
        info["script"] = item.executable
        info["id"] = item.id
        info["name"] = item.name
        let response = try await wait("init", seconds: 10) { generation = runtime.loadScript(info) }
        capabilities = (response["info"] as? SourceJSON)?["sources"] as? [String: SourceJSON] ?? [:]
        return (response["info"] as? SourceJSON)?["cyMetadata"] as? [String: String]
    }

    func resolve(_ song: Song, quality: SourceEngine.Quality) async throws -> URL {
        let source = song.platform == "QQ" ? "tx" : song.platform ?? "tx"
        guard let capability = capabilities[source], (capability["actions"] as? [String])?.contains("musicUrl") == true else {
            throw SourceFailure("当前音源不支持此平台")
        }
        let supported = capability["qualitys"] as? [String] ?? []
        let order: [SourceEngine.Quality] = [.lossless, .standard, .low]
        var lastError: Error = SourceFailure("当前音源不支持所选音质")
        for option in order.drop(while: { $0 != quality }) where supported.contains(option.rawValue) {
            try Task.checkCancellation()
            do { return try await requestURL(song, source: source, quality: option.rawValue) }
            catch is CancellationError { throw CancellationError() }
            catch { lastError = error }
        }
        throw lastError
    }

    private func requestURL(_ song: Song, source: String, quality: String) async throws -> URL {
        let key = UUID().uuidString
        let music = ["id": song.id, "songmid": song.id, "hash": song.id, "title": song.title, "name": song.title,
                    "artist": song.artist, "singer": song.artist, "source": source]
        let info: SourceJSON = ["musicInfo": music, "type": quality,
                                "requestContext": ["requestKey": key, "requestType": "current"]]
        let response = try await wait(key, seconds: 20) {
            send("request", ["requestKey": key, "data": ["action": "musicUrl", "source": source, "info": info]])
        }
        guard let result = response["result"] as? SourceJSON, let data = result["data"] as? SourceJSON,
              let address = data["url"] as? String, let url = Self.webURL(address) else { throw SourceFailure("音源返回了无效链接") }
        return url
    }

    static func webURL(_ text: String) -> URL? {
        guard let url = URL(string: text), ["http", "https"].contains(url.scheme?.lowercased()), url.host != nil else { return nil }
        return url
    }

    private func send(_ action: String, _ payload: SourceJSON) {
        guard let data = try? JSONSerialization.data(withJSONObject: payload), let json = String(data: data, encoding: .utf8) else { return }
        runtime.sendAction(action, info: json, generation: generation)
    }

    private func receive(_ action: String, generation: String, json: String) {
        guard self.generation == generation,
              let value = try? JSONSerialization.jsonObject(with: Data(json.utf8), options: .fragmentsAllowed) else { return }
        if action == "cancelRequest", let key = value as? String { http[key]?.cancel(); return }
        guard let data = value as? SourceJSON else { return }
        let key = data["requestKey"] as? String ?? "init"
        switch action {
        case "init", "response":
            guard let continuation = pending.removeValue(forKey: key) else { return }
            if data["status"] as? Bool == true { continuation.resume(returning: data) }
            else { continuation.resume(throwing: SourceFailure(data["errorMessage"] as? String ?? "音源请求失败")) }
        case "request":
            guard http[key] == nil else { return }
            http[key] = Task {
                defer { http.removeValue(forKey: key) }
                do {
                    let response = try await fetch(data)
                    send("response", ["requestKey": key, "error": NSNull(), "response": response])
                } catch { send("response", ["requestKey": key, "error": error.localizedDescription, "response": NSNull()]) }
            }
        default: break
        }
    }

    private func fetch(_ data: SourceJSON) async throws -> SourceJSON {
        guard let text = data["url"] as? String, let url = Self.webURL(text) else { throw URLError(.badURL) }
        let options = data["options"] as? SourceJSON ?? [:]
        var request = URLRequest(url: url)
        request.timeoutInterval = min(60, max(1, (options["timeout"] as? Double ?? 30_000) / 1000))
        request.httpMethod = (options["method"] as? String ?? "GET").uppercased()
        request.allHTTPHeaderFields = options["headers"] as? [String: String]
        if !["GET", "HEAD"].contains(request.httpMethod) {
            if let form = options["form"] as? SourceJSON {
                var allowed = CharacterSet.alphanumerics
                allowed.insert(charactersIn: "-._~")
                func encode(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s }
                request.httpBody = Data(form.map { "\(encode($0.key))=\(encode(String(describing: $0.value)))" }.joined(separator: "&").utf8)
                if request.value(forHTTPHeaderField: "Content-Type") == nil { request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type") }
            } else if options["formData"] != nil { throw SourceFailure("此音源请求使用了暂不支持的 multipart 表单") }
            else if let text = options["body"] as? String { request.httpBody = Data(text.utf8) }
            else if let body = options["body"] { request.httpBody = try JSONSerialization.data(withJSONObject: body, options: .fragmentsAllowed) }
        }
        let (bytes, raw) = try await network.data(for: request)
        guard let response = raw as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        let body: Any
        if options["binary"] as? Bool == true { body = bytes.base64EncodedString() }
        else if response.mimeType?.contains("json") == true, let json = try? JSONSerialization.jsonObject(with: bytes, options: .fragmentsAllowed) { body = json }
        else { body = String(decoding: bytes, as: UTF8.self) }
        var headers = [String: String]()
        for (key, value) in response.allHeaderFields { headers[String(describing: key).lowercased()] = String(describing: value) }
        return ["body": body, "headers": headers, "statusCode": response.statusCode,
                "statusMessage": HTTPURLResponse.localizedString(forStatusCode: response.statusCode)]
    }
}
