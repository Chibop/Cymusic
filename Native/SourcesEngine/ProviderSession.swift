import Foundation

typealias SourceJSON = [String: Any]
struct SourceFailure: ChineseUIError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

/// A bulk job owns one of these scopes. A script or matcher may catch a network
/// error; latch the first 429 so it cannot silently advance to another provider.
final class BulkHTTP: @unchecked Sendable {
    struct Throttled: ChineseUIError {
        let retryAfter: TimeInterval?
        var errorDescription: String? { "服务请求过于频繁 (HTTP 429)" }
    }
    @TaskLocal static var current: BulkHTTP?
    private let lock = NSLock()
    private var throttled: Throttled?
    private var next = Date.distantPast
    let spacing: TimeInterval
    init(spacing: TimeInterval = 0.65) { self.spacing = spacing }

    static func check(_ response: URLResponse) throws {
        guard let scope = current, let http = response as? HTTPURLResponse, http.statusCode == 429 else { return }
        let value = http.value(forHTTPHeaderField: "Retry-After")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        let seconds = Double(value).flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        let delay = seconds ?? formatter.date(from: value).map { max(0, $0.timeIntervalSinceNow) }
        let error = Throttled(retryAfter: delay.map { min($0, Date.distantFuture.timeIntervalSinceNow) })
        scope.lock.withLock { scope.throttled = error }; throw error
    }
    func check() throws {
        try Task.checkCancellation()
        if let error = lock.withLock({ throttled }) { throw error }
    }
    func pace() async throws {
        try check()
        let slot = lock.withLock { let slot = max(Date(), next); next = slot.addingTimeInterval(spacing); return slot }
        while slot.timeIntervalSinceNow > 0 {
            try await Task.sleep(nanoseconds: UInt64(min(1, max(0, slot.timeIntervalSinceNow)) * 1e9))
        }
        try check()
    }
}

actor ProviderSession {
    private let preload: URL?
    private var runtime: CyMusicUserApiRuntime!
    private var generation = ""
    private var pending = [String: CheckedContinuation<SourceJSON, Error>]()
    private var bulkRequestInFlight = false
    private var http = [String: Task<Void, Never>]()
    private let network = URLSession(configuration: .ephemeral)
    private var capabilities = [String: SourceJSON]()

    private let bulk: BulkHTTP?
    init(preload: URL?) { self.preload = preload; bulk = BulkHTTP.current }

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

    func qualities(for song: Song, preferred: SourceEngine.Quality, best: Bool = false) -> [String] {
        guard let capability = capabilities[Self.platform(song)],
              (capability["actions"] as? [String])?.contains("musicUrl") == true else { return [] }
        let supported = capability["qualitys"] as? [String] ?? []
        if best { return Self.bestLevels.filter(supported.contains) }
        let order: [SourceEngine.Quality] = [.lossless, .standard, .low]
        return order.drop(while: { $0 != preferred }).map(\.rawValue).filter(supported.contains)
    }

    static let bestLevels = ["flac24bit", "flac", "320k", "128k"]

    var routes: [String: [String]] { capabilities.mapValues { $0["actions"] as? [String] ?? [] } }

    var searchPlatforms: [String] {
        capabilities.keys.filter { (capabilities[$0]?["actions"] as? [String])?.contains("search") == true }.sorted()
    }

    // Discovery sends a free-text keyword. Recording matching additionally sends
    // title and artist and applies its stricter identity checks after parsing.
    func search(keyword: String, platform: String) async throws -> [Song] {
        try await searchRows(info: ["keyword": keyword], platform: platform)
    }

    private func searchRows(info: [String: String], platform: String) async throws -> [Song] {
        guard searchPlatforms.contains(platform) else { throw SourceFailure("此平台未声明搜索能力") }
        let key = UUID().uuidString
        let response = try await wait(key, seconds: 4) {
            send("request", ["requestKey": key, "data": ["action": "search", "source": platform, "info": info]])
        }
        let rows = (response["result"] as? SourceJSON)?["data"] as? [SourceJSON] ?? []
        return rows.compactMap { row in
            guard let id = row["id"] as? String, !id.isEmpty, let title = row["title"] as? String, !title.isEmpty,
                  let artist = row["artist"] as? String else { return nil }
            let duration = (row["duration"] as? NSNumber)?.doubleValue
            return Song(id: id, title: title, artist: artist, artwork: (row["artwork"] as? String).flatMap(Self.webURL),
                        platform: platform, lyrics: row["lyrics"] as? String, album: row["album"] as? String,
                        albumArtist: row["albumArtist"] as? String, duration: duration.flatMap { $0.isFinite && $0 > 0 ? $0 : nil },
                        isrc: row["isrc"] as? String)
        }
    }

    func search(_ song: Song, platform: String) async throws -> [Song] {
        let info = ["keyword": "\(song.title) \(song.artist)", "title": song.title, "artist": song.artist]
        let candidates = try await searchRows(info: info, platform: platform)
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
            else { continuation.resume(throwing: SourceFailure("音源请求失败")) }
        case "request":
            guard !pending.isEmpty, http[key] == nil else { return }
            http[key] = Task {
                defer { http.removeValue(forKey: key) }
                do {
                    let response = try await BulkHTTP.$current.withValue(bulk) { try await fetch(data) }
                    send("response", ["requestKey": key, "error": NSNull(), "response": response])
                } catch { if Task.isCancelled { return }; send("response", ["requestKey": key, "error": error.localizedDescription, "response": NSNull()]) }
            }
        default: break
        }
    }

    private func fetch(_ data: SourceJSON) async throws -> SourceJSON {
        guard let text = data["url"] as? String, let url = Self.webURL(text) else { throw URLError(.badURL) }
        // LX scripts may issue parallel requests, even within a single song.
        // Serialize their actual HTTP operations in bulk mode only.
        if let bulk {
            while bulkRequestInFlight { try bulk.check(); try await Task.sleep(nanoseconds: 50_000_000) }
            try bulk.check(); bulkRequestInFlight = true
        }
        defer { if bulk != nil { bulkRequestInFlight = false } }
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
        try await bulk?.pace()
        let (bytes, raw) = try await network.data(for: request)
        try BulkHTTP.check(raw)
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
