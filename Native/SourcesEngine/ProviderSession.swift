import Foundation

typealias SourceJSON = [String: Any]
struct SourceFailure: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

actor ProviderSession {
    private let preload: URL?
    private var runtime: CyMusicUserApiRuntime!
    private var generation = ""
    private var pending = [String: CheckedContinuation<SourceJSON, Error>]()
    private var http = [String: Task<Void, Never>]()
    private let network = URLSession(configuration: .ephemeral)
    private var capabilities = [String: SourceJSON]()

    init(preload: URL?) { self.preload = preload }

    private func start() {
        runtime = CyMusicUserApiRuntime(preload: preload) { [weak self] event in
            guard let action = event["action"] as? String, let generation = event["generation"] as? String,
                  let data = event["data"] as? String else { return }
            Task { await self?.receive(action, generation: generation, json: data) }
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
            guard let continuation = pending.removeValue(forKey: key) else { return }
            // Each session serves one logical operation at a time. Stop its LX
            // transfers as well, rather than leaving them running into a retry.
            for task in http.values { task.cancel() }
            continuation.resume(throwing: SourceFailure("音源响应超时"))
        }
        defer { timer.cancel() }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                pending[key] = continuation
                start()
            }
        } onCancel: {
            Task { await self.cancel(key) }
        }
    }

    private func cancel(_ key: String) { pending.removeValue(forKey: key)?.resume(throwing: CancellationError()) }

    func load(_ item: SourceScript) async throws -> [String: String]? {
        start()
        var info = item.metadata
        info["script"] = item.executable
        info["id"] = item.id
        info["name"] = item.name
        let response = try await wait("init", seconds: 6) { generation = runtime.loadScript(info) }
        capabilities = (response["info"] as? SourceJSON)?["sources"] as? [String: SourceJSON] ?? [:]
        return (response["info"] as? SourceJSON)?["cyMetadata"] as? [String: String]
    }

    static func platform(_ song: Song) -> String {
        switch song.platform?.lowercased() {
        case "qq", "qqmusic", "tx": return "tx"
        default: return song.platform?.lowercased() ?? ""
        }
    }

    func qualities(for song: Song, preferred: SourceEngine.Quality) -> [String] {
        guard let capability = capabilities[Self.platform(song)],
              (capability["actions"] as? [String])?.contains("musicUrl") == true else { return [] }
        let supported = capability["qualitys"] as? [String] ?? []
        let order: [SourceEngine.Quality] = [.lossless, .standard, .low]
        return order.drop(while: { $0 != preferred }).map(\.rawValue).filter(supported.contains)
    }

    var routes: [String: [String]] { capabilities.mapValues { $0["actions"] as? [String] ?? [] } }

    var searchPlatforms: [String] {
        capabilities.keys.filter { (capabilities[$0]?["actions"] as? [String])?.contains("search") == true }.sorted()
    }

    // Opt-in LX extension: search({keyword,title,artist}) returns [{id,title,artist}].
    func search(_ song: Song, platform: String) async throws -> [Song] {
        let key = UUID().uuidString
        let info = ["keyword": "\(song.title) \(song.artist)", "title": song.title, "artist": song.artist]
        let response = try await wait(key, seconds: 4) {
            send("request", ["requestKey": key, "data": ["action": "search", "source": platform, "info": info]])
        }
        let rows = (response["result"] as? SourceJSON)?["data"] as? [SourceJSON] ?? []
        let candidates: [Song] = rows.compactMap { row in
            guard let id = row["id"] as? String, !id.isEmpty, let title = row["title"] as? String,
                  let artist = row["artist"] as? String else { return nil }
            return Song(id: id, title: title, artist: artist, platform: platform, album: row["album"] as? String,
                        duration: (row["duration"] as? NSNumber)?.doubleValue, isrc: row["isrc"] as? String)
        }
        if song.album != nil || song.duration != nil || song.isrc != nil {
            return PoolMatcher.match(song, in: candidates).map { [$0] } ?? []
        }
        // Legacy search-only scripts may supply no recording identifiers. Keep
        // their exact title/artist path, but never pick arbitrarily among IDs.
        func norm(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        let exact = candidates.filter { norm($0.title) == norm(song.title) && norm($0.artist) == norm(song.artist) }
        guard !norm(song.title).isEmpty, !norm(song.artist).isEmpty, Set(exact.map(\.id)).count == 1,
              let first = exact.first else { return [] }
        return [first]
    }

    func requestURL(_ song: Song, quality: String) async throws -> URL {
        let source = Self.platform(song)
        let key = UUID().uuidString
        let music = ["id": song.id, "songmid": song.id, "hash": song.id, "title": song.title, "name": song.title,
                    "artist": song.artist, "singer": song.artist, "source": source]
        let info: SourceJSON = ["musicInfo": music, "type": quality,
                                "requestContext": ["requestKey": key, "requestType": "current"]]
        let response = try await wait(key, seconds: 5) {
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
            guard !pending.isEmpty, http[key] == nil else { return }
            http[key] = Task {
                defer { http.removeValue(forKey: key) }
                do {
                    let response = try await fetch(data)
                    send("response", ["requestKey": key, "error": NSNull(), "response": response])
                } catch { if Task.isCancelled { return }; send("response", ["requestKey": key, "error": error.localizedDescription, "response": NSNull()]) }
            }
        default: break
        }
    }

    private func fetch(_ data: SourceJSON) async throws -> SourceJSON {
        guard let text = data["url"] as? String, let url = Self.webURL(text) else { throw URLError(.badURL) }
        let options = data["options"] as? SourceJSON ?? [:]
        var request = URLRequest(url: url)
        request.timeoutInterval = min(5, max(1, (options["timeout"] as? Double ?? 5_000) / 1000))
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
