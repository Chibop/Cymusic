import Foundation
#if canImport(MusicKit)
import MusicKit
#endif

enum PoolCatalog {
    enum Kind: String, CaseIterable, Identifiable {
        case songs = "歌曲", albums = "专辑", artists = "艺人"
        var id: Self { self }
    }

    struct Context {
        let country: String?
        var origin: String { country.map { "Apple Music · " + $0.uppercased() } ?? "Apple Music" }
    }

    struct Entry: Identifiable {
        let id: String
        let title: String
        let subtitle: String
        let artwork: URL?
        let genre: String?
        let releaseDate: String?
        let trackCount: Int?
        let context: Context

        var metadata: String {
            [genre, releaseDate.map { String($0.prefix(10)) }, trackCount.map { "\($0) 首" }]
                .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        }
    }

    struct Results {
        var songs: [Song] = []
        var albums: [Entry] = []
        var artists: [Entry] = []
        let context: Context
        var origin: String { context.origin }
        var isEmpty: Bool { songs.isEmpty && albums.isEmpty && artists.isEmpty }
    }

    private static func fetch(_ base: String, _ query: [String: String], referer: String? = nil) async throws -> Data {
        try Task.checkCancellation()
        var parts = URLComponents(string: base)!
        parts.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        // Some services interpret a literal plus in a query as a space.
        parts.percentEncodedQuery = parts.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        guard let url = parts.url else { throw URLError(.badURL) }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue(referer, forHTTPHeaderField: "Referer")
        let (data, response) = try await URLSession.shared.data(for: request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw URLError(.badServerResponse) }
        return data
    }

    static func search(_ term: String) async throws -> Results {
        #if canImport(MusicKit)
        if musicKitAvailable {
            do {
                var request = MusicCatalogSearchRequest(term: term, types: [MusicKit.Song.self, MusicKit.Album.self, MusicKit.Artist.self])
                request.limit = 25
                let response = try await request.response()
                let context = Context(country: nil)
                let result = Results(songs: response.songs.map(song), albums: response.albums.map { album($0, context: context) }, artists: response.artists.map {
                    Entry(id: $0.id.rawValue, title: $0.name, subtitle: "艺人", artwork: $0.artwork?.url(width: 300, height: 300), genre: $0.genreNames?.first, releaseDate: nil, trackCount: nil, context: context)
                }, context: context)
                if !result.isEmpty { return result }
            } catch { try Task.checkCancellation() }
        }
        #endif
        var fallback: Results?
        for country in ["cn", "hk"] {
            do {
                async let songs = publicRows("search", query: ["term": term, "entity": "song", "limit": "25"], country: country)
                async let albums = publicRows("search", query: ["term": term, "entity": "album", "limit": "25"], country: country)
                async let artists = publicRows("search", query: ["term": term, "entity": "musicArtist", "limit": "25"], country: country)
                let rows = try await (songs, albums, artists)
                let context = Context(country: country)
                let result = Results(songs: rows.0.compactMap(\.song), albums: rows.1.compactMap { $0.album(context) }, artists: rows.2.compactMap { $0.artist(context) }, context: context)
                // CN may expose artists while hiding their entire song/album catalog.
                if !result.songs.isEmpty || !result.albums.isEmpty { return result }
                if fallback == nil || fallback!.isEmpty { fallback = result }
            } catch { try Task.checkCancellation() }
        }
        guard let fallback else { throw URLError(.cannotLoadFromNetwork) }
        return fallback
    }

    static func tracks(_ entry: Entry) async throws -> Results {
        #if canImport(MusicKit)
        if entry.context.country == nil, musicKitAvailable {
            do {
                let request = MusicCatalogResourceRequest<MusicKit.Album>(matching: \.id, equalTo: MusicItemID(entry.id))
                if let item = try await request.response().items.first {
                    let expanded = try await item.with([.tracks])
                    var songs: [Song] = []
                    var page = expanded.tracks
                    while let current = page {
                        try Task.checkCancellation()
                        songs += current.compactMap { track in
                            guard case .song(let item) = track else { return nil }
                            return song(item)
                        }
                        page = try await current.nextBatch()
                    }
                    if !songs.isEmpty { return Results(songs: songs, context: entry.context) }
                }
            } catch { try Task.checkCancellation() }
        }
        #endif
        return try await lookup(entry, entity: "song")
    }

    static func releases(_ entry: Entry) async throws -> Results {
        #if canImport(MusicKit)
        if entry.context.country == nil, musicKitAvailable {
            do {
                let request = MusicCatalogResourceRequest<MusicKit.Artist>(matching: \.id, equalTo: MusicItemID(entry.id))
                if let item = try await request.response().items.first {
                    let expanded = try await item.with([.albums])
                    var albums: [Entry] = []
                    var page = expanded.albums
                    while let current = page {
                        try Task.checkCancellation()
                        albums += current.map { album($0, context: entry.context) }
                        page = try await current.nextBatch()
                    }
                    if !albums.isEmpty { return Results(albums: albums, context: entry.context) }
                }
            } catch { try Task.checkCancellation() }
        }
        #endif
        return try await lookup(entry, entity: "album")
    }

    private static func lookup(_ entry: Entry, entity: String) async throws -> Results {
        var countries = [entry.context.country].compactMap { $0 }
        countries += ["cn", "hk"].filter { !countries.contains($0) }
        var fallback: Results?
        for country in countries {
            do {
                let rows = try await publicRows("lookup", query: ["id": entry.id, "entity": entity, "limit": "200"], country: country)
                let context = Context(country: country)
                var seen = Set<String>()
                let albums = rows.compactMap { $0.album(context) }.filter { seen.insert($0.id).inserted }
                let songs = rows.filter { $0.collectionId.map(String.init) == entry.id }.sorted {
                    ($0.discNumber ?? 0, $0.trackNumber ?? 0) < ($1.discNumber ?? 0, $1.trackNumber ?? 0)
                }.compactMap(\.song)
                let result = Results(songs: entity == "song" ? songs : [], albums: entity == "album" ? albums : [], context: context)
                if !result.isEmpty { return result }
                fallback = result
            } catch { try Task.checkCancellation() }
        }
        guard let fallback else { throw URLError(.cannotLoadFromNetwork) }
        return fallback
    }

    private struct PublicRow: Decodable {
        let wrapperType: String?, kind: String?, collectionType: String?
        let trackId: Int64?, collectionId: Int64?, artistId: Int64?
        let trackName: String?, artistName: String?, collectionName: String?
        let artworkUrl100: URL?, trackTimeMillis: Double?, primaryGenreName: String?, releaseDate: String?
        let trackCount: Int?, trackNumber: Int?, discNumber: Int?

        var song: Song? {
            guard kind == "song", let id = trackId, let title = trackName, let artist = artistName else { return nil }
            return Song(id: String(id), title: title, artist: artist, artwork: artworkUrl100, platform: "apple", album: collectionName, duration: trackTimeMillis.map { $0 / 1000 })
        }

        func album(_ context: Context) -> Entry? {
            guard wrapperType == "collection", collectionType == "Album", let id = collectionId, let title = collectionName else { return nil }
            return Entry(id: String(id), title: title, subtitle: artistName ?? "", artwork: artworkUrl100, genre: primaryGenreName, releaseDate: releaseDate, trackCount: trackCount, context: context)
        }

        func artist(_ context: Context) -> Entry? {
            guard wrapperType == "artist", let id = artistId, let title = artistName else { return nil }
            return Entry(id: String(id), title: title, subtitle: "艺人", artwork: nil, genre: primaryGenreName, releaseDate: nil, trackCount: nil, context: context)
        }
    }

    private static func publicRows(_ endpoint: String, query: [String: String], country: String) async throws -> [PublicRow] {
        struct Page: Decodable { let results: [PublicRow] }
        var query = query
        query["country"] = country
        query["media"] = "music"
        return try JSONDecoder().decode(Page.self, from: await fetch("https://itunes.apple.com/" + endpoint, query)).results
    }

    static func iTunes(_ term: String, country: String) async throws -> [Song] {
        try await publicRows("search", query: ["term": term, "entity": "song", "limit": "25"], country: country).compactMap(\.song)
    }

    #if canImport(MusicKit)
    private static var musicKitAvailable: Bool {
        Bundle.main.object(forInfoDictionaryKey: "NSAppleMusicUsageDescription") != nil && MusicAuthorization.currentStatus == .authorized
    }

    private static func song(_ item: MusicKit.Song) -> Song {
        Song(id: item.id.rawValue, title: item.title, artist: item.artistName, artwork: item.artwork?.url(width: 300, height: 300), platform: "apple", album: item.albumTitle, duration: item.duration, isrc: item.isrc)
    }

    private static func album(_ item: MusicKit.Album, context: Context) -> Entry {
        Entry(id: item.id.rawValue, title: item.title, subtitle: item.artistName, artwork: item.artwork?.url(width: 300, height: 300), genre: item.genreNames.first, releaseDate: item.releaseDate.map { ISO8601DateFormatter().string(from: $0) }, trackCount: item.trackCount, context: context)
    }
    #endif

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
