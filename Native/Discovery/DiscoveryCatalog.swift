import Foundation

enum DiscoveryPlatform: String, CaseIterable, Codable {
    case qq = "tx", netease = "wy", apple
    var name: String { switch self { case .qq: return "QQ 音乐"; case .netease: return "网易云音乐"; case .apple: return "Apple Music" } }
}

struct DiscoveryPlaylist: Codable, Identifiable {
    let id: String
    let platform: DiscoveryPlatform
    let title: String
    let curator: String
    let artwork: URL?
    let source: URL
    var count: Int? = nil
}

/// Read-only, anonymous first-party catalogue metadata. These publisher web feeds are
/// not versioned developer APIs. Absence, region redirects and schema changes are errors,
/// never reasons to substitute a different playlist or to resolve audio here.
enum DiscoveryCatalog {
    private typealias Object = [String: Any]
    private static let session = URLSession(configuration: {
        let c = URLSessionConfiguration.ephemeral
        c.httpShouldSetCookies = false
        c.httpCookieStorage = nil
        c.urlCredentialStorage = nil
        c.timeoutIntervalForRequest = 16
        return c
    }())

    private static func bytes(_ url: URL) async throws -> Data {
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), http.url?.host == url.host else { throw URLError(.badServerResponse) }
        return data
    }
    private static func fetchJSON(_ url: URL) async throws -> Object {
        let data = try await bytes(url)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? Object else { throw URLError(.cannotParseResponse) }
        return obj
    }
    private static func qq(_ module: String, _ method: String, _ params: Object) async throws -> Object {
        let payload = try JSONSerialization.data(withJSONObject: ["req": ["module": module, "method": method, "param": params] as Object])
        var url = URLComponents(string: "https://u.y.qq.com/cgi-bin/musicu.fcg")!
        url.queryItems = [URLQueryItem(name: "data", value: String(decoding: payload, as: UTF8.self))]
        let root = try await fetchJSON(url.url!)
        guard root["code"] as? Int == 0, let req = root["req"] as? Object, req["code"] as? Int == 0, let data = req["data"] as? Object else { throw URLError(.badServerResponse) }
        return data
    }
    private static func appleSections(_ url: URL) async throws -> [Object] {
        let html = String(decoding: try await bytes(url), as: UTF8.self)
        guard let start = html.range(of: #"<script\b[^>]*\bid="serialized-server-data"[^>]*>"#, options: .regularExpression),
              let end = html[start.upperBound...].range(of: "</script>"),
              let payload = try JSONSerialization.jsonObject(with: Data(html[start.upperBound..<end.lowerBound].utf8)) as? Object,
              let page = (payload["data"] as? [Object])?.first?["data"] as? Object, let sections = page["sections"] as? [Object] else { throw URLError(.cannotParseResponse) }
        return sections
    }
    private static func art(_ value: Any?) -> URL? {
        guard let raw = value as? String, var c = URLComponents(string: raw), ["http", "https"].contains(c.scheme), c.host != nil else { return nil }
        c.scheme = "https"; return c.url
    }
    private static func appleArt(_ row: Object) -> URL? {
        let dict = (row["artwork"] as? Object)?["dictionary"] as? Object
        return art((dict?["url"] as? String)?.replacingOccurrences(of: "{w}", with: "300").replacingOccurrences(of: "{h}", with: "300").replacingOccurrences(of: "{f}", with: "jpg"))
    }
    private static func id(_ value: Any?) -> String? { (value as? NSNumber)?.stringValue ?? value as? String }
    private static func labels(_ value: Any?, _ key: String) -> String { (value as? [Object] ?? []).compactMap { $0[key] as? String }.joined(separator: " / ") }
    private static func appleID(_ descriptor: Object?) -> String? { id((descriptor?["identifiers"] as? Object)?["storeAdamID"]) }

    static func playlists(_ p: DiscoveryPlatform) async throws -> [DiscoveryPlaylist] {
        let result: [DiscoveryPlaylist]
        switch p {
        case .qq:
            let data = try await qq("playlist.HotRecommendServer", "get_hot_recommend", ["async": 1, "cmd": 2])
            result = (data["v_hot"] as? [Object] ?? []).compactMap { row in
                guard row["type"] as? Int == 10014, let n = row["content_id"] as? Int64, n > 0, let title = row["title"] as? String else { return nil }
                return .init(id: String(n), platform: p, title: title, curator: row["username"] as? String ?? "", artwork: art(row["cover"]), source: URL(string: "https://y.qq.com/n/ryqq/playlist/\(n)")!)
            }
        case .netease:
            let data = try await fetchJSON(URL(string: "https://music.163.com/api/playlist/highquality/list?limit=24")!)
            result = (data["playlists"] as? [Object] ?? []).compactMap { row in
                guard let n = row["id"] as? Int64, n > 0, let title = row["name"] as? String else { return nil }
                return .init(id: String(n), platform: p, title: title, curator: (row["creator"] as? Object)?["nickname"] as? String ?? "", artwork: art(row["coverImgUrl"]), source: URL(string: "https://music.163.com/playlist?id=\(n)")!, count: row["trackCount"] as? Int)
            }
        case .apple:
            let sections = try await appleSections(URL(string: "https://music.apple.com/cn/new")!)
            result = sections.flatMap { $0["items"] as? [Object] ?? [] }.compactMap { row in
                guard let desc = row["contentDescriptor"] as? Object, desc["kind"] as? String == "playlist", let n = appleID(desc),
                      let raw = desc["url"] as? String, let url = URL(string: raw), url.scheme == "https", url.host == "music.apple.com", url.lastPathComponent == n,
                      let title = row["title"] as? String ?? (row["titleLinks"] as? [Object])?.first?["title"] as? String else { return nil }
                return .init(id: n, platform: p, title: title, curator: row["subtitle"] as? String ?? labels(row["subtitleLinks"], "title"), artwork: appleArt(row), source: url)
            }
        }
        var seen = Set<String>()
        let unique = result.filter { seen.insert($0.id).inserted }
        guard !unique.isEmpty else { throw URLError(.cannotParseResponse) }; return Array(unique.prefix(32))
    }

    static func tracks(_ p: DiscoveryPlaylist) async throws -> [Song] {
        let songs: [Song]
        switch p.platform {
        case .qq:
            guard let n = Int64(p.id) else { throw URLError(.badURL) }
            let data = try await qq("music.srfDissInfo.aiDissInfo", "uniform_get_Dissinfo", ["disstid": n, "song_begin": 0, "song_num": 100, "onlysong": 0])
            guard id((data["dirinfo"] as? Object)?["id"]) == p.id else { throw URLError(.badServerResponse) }
            songs = (data["songlist"] as? [Object] ?? []).compactMap { r in
                guard let mid = r["mid"] as? String, !mid.isEmpty, let title = r["title"] as? String else { return nil }
                let album = r["album"] as? Object
                let cover = (album?["mid"] as? String).flatMap { $0.isEmpty ? nil : art("https://y.gtimg.cn/music/photo_new/T002R500x500M000\($0).jpg") }
                return Song(id: mid, title: title, artist: labels(r["singer"], "name"), artwork: cover, platform: "tx", album: album?["name"] as? String, duration: r["interval"] as? Double)
            }
        case .netease:
            guard let n = Int64(p.id) else { throw URLError(.badURL) }
            let data = try await fetchJSON(URL(string: "https://music.163.com/api/playlist/detail?id=\(n)")!)
            guard let result = data["result"] as? Object, id(result["id"]) == p.id else { throw URLError(.badServerResponse) }
            songs = (result["tracks"] as? [Object] ?? []).compactMap { r in
                guard let n = id(r["id"]), let title = r["name"] as? String else { return nil }
                let album = r["album"] as? Object
                return Song(id: n, title: title, artist: labels(r["artists"], "name"), artwork: art(album?["picUrl"]), platform: "wy", album: album?["name"] as? String, duration: (r["duration"] as? Double).map { $0 / 1000 })
            }
        case .apple:
            let sections = try await appleSections(p.source)
            songs = sections.filter { $0["itemKind"] as? String == "trackLockup" && appleID($0["containerContentDescriptor"] as? Object) == p.id }.flatMap { $0["items"] as? [Object] ?? [] }.compactMap { row in
                guard let desc = row["contentDescriptor"] as? Object, desc["kind"] as? String == "song", let n = appleID(desc), let title = row["title"] as? String else { return nil }
                let album = (row["tertiaryLinks"] as? [Object])?.first?["title"] as? String
                return Song(id: n, title: title, artist: row["artistName"] as? String ?? labels(row["subtitleLinks"], "title"), artwork: appleArt(row), platform: "apple", album: album, duration: (row["duration"] as? Double).map { $0 / 1000 })
            }
        }
        guard !songs.isEmpty else { throw URLError(.zeroByteResource) }; return songs
    }
}
