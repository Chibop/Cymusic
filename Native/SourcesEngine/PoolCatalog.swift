import Foundation
#if canImport(MusicKit)
import MusicKit
#endif

enum PoolCatalog {
    struct Results {
        let songs: [Song]
        let origin: String
    }

    private static func fetch(_ base: String, _ query: [String: String], referer: String? = nil) async throws -> Data {
        try Task.checkCancellation()
        var parts = URLComponents(string: base)!
        parts.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        // Some services interpret a literal plus in a query as a space.
        parts.percentEncodedQuery = parts.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        guard let url = parts.url else { throw URLError(.badURL) }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue(referer, forHTTPHeaderField: "Referer")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw URLError(.badServerResponse) }
        return data
    }

    static func search(_ term: String) async throws -> Results {
        #if canImport(MusicKit)
        if Bundle.main.object(forInfoDictionaryKey: "NSAppleMusicUsageDescription") != nil,
           MusicAuthorization.currentStatus == .authorized {
            var request = MusicCatalogSearchRequest(term: term, types: [MusicKit.Song.self])
            request.limit = 25
            if let response = try? await request.response(), !response.songs.isEmpty {
                return Results(songs: response.songs.map {
                    Song(id: $0.id.rawValue, title: $0.title, artist: $0.artistName, artwork: $0.artwork?.url(width: 300, height: 300), platform: "apple", album: $0.albumTitle, duration: $0.duration, isrc: $0.isrc)
                }, origin: "Apple Music")
            }
        }
        #endif
        // The public CN storefront can return an empty song catalog even for known tracks.
        var responded = false
        for country in ["cn", "hk"] {
            if let songs = try? await iTunes(term, country: country) {
                responded = true
                if !songs.isEmpty { return Results(songs: songs, origin: "Apple Music · " + country.uppercased()) }
            }
            try Task.checkCancellation()
        }
        async let qq = try? qq(term)
        async let wy = try? netEase(term)
        let (a, b) = await (qq, wy)
        try Task.checkCancellation()
        guard responded || a != nil || b != nil else { throw URLError(.cannotLoadFromNetwork) }
        return Results(songs: (a ?? []) + (b ?? []), origin: "QQ 音乐 / 网易云音乐")
    }

    static func iTunes(_ term: String, country: String) async throws -> [Song] {
        struct Page: Decodable {
            struct Track: Decodable {
                let trackId: Int64?, trackName: String?, artistName: String?, collectionName: String?
                let artworkUrl100: URL?, trackTimeMillis: Double?, kind: String?
            }
            let results: [Track]
        }
        let data = try await fetch("https://itunes.apple.com/search", ["term": term, "media": "music", "entity": "song", "country": country, "limit": "25"])
        return try JSONDecoder().decode(Page.self, from: data).results.compactMap {
            guard $0.kind == "song", let id = $0.trackId, let title = $0.trackName, let artist = $0.artistName else { return nil }
            return Song(id: String(id), title: title, artist: artist, artwork: $0.artworkUrl100, platform: "apple", album: $0.collectionName, duration: $0.trackTimeMillis.map { $0 / 1000 })
        }
    }

    static func qq(_ term: String) async throws -> [Song] {
        let data = try await fetch("https://c.y.qq.com/soso/fcgi-bin/client_search_cp", ["w": term, "format": "json", "n": "30", "p": "1"], referer: "https://y.qq.com/")
        let root = try JSONSerialization.jsonObject(with: data) as? SourceJSON
        guard let list = ((root?["data"] as? SourceJSON)?["song"] as? SourceJSON)?["list"] as? [SourceJSON] else { throw URLError(.cannotParseResponse) }
        return list.compactMap { row in
            guard var song = SourceCatalog.qqSong(row)?.song else { return nil }
            song.album = row["albumname"] as? String
            song.duration = (row["interval"] as? NSNumber)?.doubleValue
            return song
        }
    }

    static func netEase(_ term: String) async throws -> [Song] {
        let data = try await fetch("https://music.163.com/api/search/get/web", ["s": term, "type": "1", "limit": "30", "offset": "0"], referer: "https://music.163.com/")
        let root = try JSONSerialization.jsonObject(with: data) as? SourceJSON
        guard let result = root?["result"] as? SourceJSON else { throw URLError(.cannotParseResponse) }
        if result["songCount"] as? Int == 0 { return [] }
        guard let rows = result["songs"] as? [SourceJSON] else { throw URLError(.cannotParseResponse) }
        return rows.compactMap { row in
            guard let id = row["id"] as? Int64, id > 0, let title = row["name"] as? String, let artists = row["artists"] as? [SourceJSON] else { return nil }
            let album = row["album"] as? SourceJSON
            return Song(id: String(id), title: title, artist: artists.compactMap { $0["name"] as? String }.joined(separator: " / "), platform: "wy", album: album?["name"] as? String, duration: (row["duration"] as? Double).map { $0 / 1000 })
        }
    }
}
