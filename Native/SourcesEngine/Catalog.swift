import Foundation

enum SourceCatalog {
    private static func json(_ base: String, query: [String: String] = [:], body: SourceJSON? = nil, referer: String = "https://y.qq.com/") async throws -> SourceJSON {
        var components = URLComponents(string: base)!
        components.queryItems = query.isEmpty ? nil : query.map { URLQueryItem(name: $0.key, value: $0.value) }
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 15
        if components.host?.hasSuffix(".qq.com") == true { request.setValue(referer, forHTTPHeaderField: "Referer") }
        if let body {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        try BulkHTTP.check(response)
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else { throw SourceFailure("目录服务暂不可用") }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? SourceJSON else { throw SourceFailure("目录服务返回了无法读取的数据") }
        return json
    }

    static func qqSong(_ item: SourceJSON) -> CatalogTrack? {
        guard let mid = (item["mid"] ?? item["songmid"]) as? String, !mid.isEmpty,
              let title = (item["title"] ?? item["songname"]) as? String else { return nil }
        let singers = item["singer"] as? [SourceJSON] ?? []
        let artist = singers.compactMap { $0["name"] as? String }.joined(separator: " / ")
        let album = ((item["album"] as? SourceJSON)?["mid"] ?? item["albummid"]) as? String
        let art = album.flatMap { $0.isEmpty ? nil : URL(string: "https://y.gtimg.cn/music/photo_new/T002R500x500M000\($0).jpg") }
        var destinations = singers.compactMap { singer -> CatalogDestination? in
            guard let mid = singer["mid"] as? String, !mid.isEmpty, let name = singer["name"] as? String else { return nil }
            return CatalogDestination(kind: .artist, mid: mid, name: name)
        }
        if let album, !album.isEmpty {
            let info = item["album"] as? SourceJSON
            let name = (info?["title"] ?? info?["name"] ?? item["albumname"]) as? String ?? "专辑"
            destinations.append(CatalogDestination(kind: .album, mid: album, name: name))
        }
        return CatalogTrack(song: Song(id: mid, title: title, artist: artist, artwork: art, platform: "tx"), destinations: destinations)
    }

    static func search(_ term: String, page: Int) async throws -> [CatalogTrack] {
        let response = try await json("https://c.y.qq.com/soso/fcgi-bin/client_search_cp", query: ["w": term, "format": "json", "p": String(page), "n": "20"])
        let data = response["data"] as? SourceJSON
        guard let songs = (data?["song"] as? SourceJSON)?["list"] as? [SourceJSON] else { throw SourceFailure("QQ 音乐暂未开放此次搜索") }
        return songs.compactMap(qqSong)
    }

    static func playlistID(_ text: String) throws -> String {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        func isID(_ s: String) -> Bool { !s.isEmpty && s.utf8.allSatisfy { (48...57).contains($0) } }
        if isID(value) { return value }
        if let parts = URLComponents(string: value), let host = parts.host?.lowercased(), host == "qq.com" || host.hasSuffix(".qq.com") {
            if let id = parts.queryItems?.first(where: { ["id", "disstid", "playlistid"].contains($0.name.lowercased()) })?.value, isID(id) { return id }
            let id = (parts.path as NSString).lastPathComponent.components(separatedBy: ".").first ?? ""
            if isID(id) { return id }
        }
        throw SourceFailure("请输入数字歌单 ID 或含 ID 的 QQ 音乐歌单链接")
    }

    static func playlist(_ input: String) async throws -> (String, [CatalogTrack]) {
        let id = try playlistID(input)
        let result = try await json("https://c.y.qq.com/v8/fcg-bin/fcg_v8_playlist_cp.fcg", query: ["newsong": "1", "id": id, "format": "json", "inCharset": "GB2312", "outCharset": "utf-8"])
        let cds = ((result["data"] as? SourceJSON)?["cdlist"] ?? result["cdlist"]) as? [SourceJSON]
        guard let cd = cds?.first, let entries = cd["songlist"] as? [SourceJSON] else { throw SourceFailure("无法读取该公开歌单") }
        return (cd["dissname"] as? String ?? "QQ 音乐歌单", entries.compactMap(qqSong))
    }

    static func chart() async throws -> (String, [CatalogTrack]) {
        let rpc: SourceJSON = ["detail": ["module": "musicToplist.ToplistInfoServer", "method": "GetDetail", "param": ["topId": 26, "offset": 0, "num": 50, "period": ""]], "comm": ["ct": 24, "cv": 0]]
        let encoded = try JSONSerialization.data(withJSONObject: rpc)
        let result = try await json("https://u.y.qq.com/cgi-bin/musicu.fcg", query: ["data": String(decoding: encoded, as: UTF8.self)])
        guard let data = (result["detail"] as? SourceJSON)?["data"] as? SourceJSON, let list = data["songInfoList"] as? [SourceJSON] else { throw SourceFailure("无法读取热歌榜") }
        return ((data["data"] as? SourceJSON)?["title"] as? String ?? "热歌榜", list.compactMap(qqSong))
    }

    static func detail(_ destination: CatalogDestination) async throws -> [CatalogTrack] {
        let entries: [SourceJSON]?
        switch destination.kind {
        case .artist:
            let rpc: SourceJSON = ["comm": ["ct": 24, "cv": 0], "singer": ["module": "music.web_singer_info_svr", "method": "get_singer_detail_info", "param": ["singermid": destination.mid, "sort": 5, "sin": 0, "num": 50]]]
            let data = try JSONSerialization.data(withJSONObject: rpc)
            let response = try await json("https://u.y.qq.com/cgi-bin/musicu.fcg", query: ["format": "json", "data": String(decoding: data, as: UTF8.self)])
            entries = ((response["singer"] as? SourceJSON)?["data"] as? SourceJSON)?["songlist"] as? [SourceJSON]
        case .album:
            let response = try await json("https://i.y.qq.com/v8/fcg-bin/fcg_v8_album_info_cp.fcg", query: ["albummid": destination.mid, "format": "json", "platform": "h5", "uin": "0"])
            entries = (response["data"] as? SourceJSON)?["list"] as? [SourceJSON]
        }
        guard let entries else { throw SourceFailure("无法读取歌曲列表") }
        return entries.compactMap(qqSong)
    }

    static func lyrics(_ song: Song) async throws -> String? {
        if let lyrics = song.lyrics, !lyrics.isEmpty { return lyrics }
        guard ["tx", "QQ"].contains(song.platform ?? ""), !song.id.isEmpty else { return nil }
        let response = try await json("https://c.y.qq.com/lyric/fcgi-bin/fcg_query_lyric_new.fcg", query: ["songmid": song.id, "g_tk": "5381", "loginUin": "0", "hostUin": "0", "format": "json", "inCharset": "utf8", "outCharset": "utf-8", "platform": "yqq"], referer: "https://y.qq.com/portal/player.html")
        return decodeLyrics(response)
    }

    @MainActor static func applyLyrics(for song: Song, isCurrent: @MainActor () -> Bool,
                                       apply: @MainActor (String) -> Void) async {
        guard isCurrent(), let text = try? await lyrics(song), !Task.isCancelled, isCurrent() else { return }
        apply(text)
    }

    static func decodeLyrics(_ response: SourceJSON) -> String? {
        guard response["code"] as? Int == 0, let raw = response["lyric"] as? String,
              let bytes = Data(base64Encoded: raw), var text = String(data: bytes, encoding: .utf8), !text.isEmpty else { return nil }
        for (entity, value) in [("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&apos;", "'"), ("&#039;", "'"), ("&nbsp;", " "), ("&amp;", "&")] {
            text = text.replacingOccurrences(of: entity, with: value)
        }
        return text
    }
}

struct CatalogDestination: Hashable {
    enum Kind: Hashable { case artist, album }
    let kind: Kind
    let mid: String
    let name: String
}

struct CatalogTrack: Identifiable {
    let song: Song
    let destinations: [CatalogDestination]
    var id: String { song.id }
}
