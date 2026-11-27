import Foundation

// Build alongside the same engine sources as verify-scoped-search.py, replacing
// ScopedSearchProbe.swift with this file. Arguments: store path, preload JS path.
private final class CatalogFixture: URLProtocol {
    static let lock = NSLock()
    private static var requests: [String] = []
    static var trace: [String] { lock.withLock { requests } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        let url = request.url!
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems ?? []
        let host = url.host!
        Self.lock.withLock { Self.requests.append(host) }
        let json: String
        switch host {
        case "c.y.qq.com":
            precondition(query.contains(URLQueryItem(name: "w", value: "Song Artist")))
            json = #"{"data":{"song":{"list":[{"songmid":"qq-mid","songname":"Song","singer":[{"name":"Artist"}],"interval":123}]}}}"#
        case "music.163.com":
            precondition(query.contains(URLQueryItem(name: "s", value: "Song Artist")))
            json = #"{"result":{"songs":[{"id":456,"name":"Song","artists":[{"name":"Artist"}],"duration":123000}]}}"#
        case "songsearch.kugou.com":
            json = #"{"status":1,"data":{"lists":[{"FileHash":"B5FB24746AF437BE697BFDBC7BA997E7","ID":"410","AlbumID":"976460","SongName":"Song","SingerName":"Artist","Duration":123}]}}"#
        case "search.kuwo.cn":
            json = #"{"abslist":[{"MUSICRID":"MUSIC_440613","SONGNAME":"Song","ARTIST":"Artist","DURATION":"123"}]}"#
        case "c.musicapp.migu.cn":
            json = #"{"code":"000000","songResultData":{"result":[{"id":"697066","contentId":"600902000006889010","copyrightId":"60054702010","name":"Song","singers":[{"name":"Artist"}],"albums":[{"name":"Studio"}]}]}}"#
        default: fatalError("Unexpected network call: \(url)")
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(json.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

@main struct ScopedCatalogMatchFixture {
    @MainActor static func main() async throws {
        precondition(URLProtocol.registerClass(CatalogFixture.self))
        defer { URLProtocol.unregisterClass(CatalogFixture.self) }
        let engine = SourceEngine(store: URL(fileURLWithPath: CommandLine.arguments[1]), preload: URL(fileURLWithPath: CommandLine.arguments[2]), matcher: { _ in fatalError("Unexpected pooled lookup") })
        let source = """
        lx.on(lx.EVENT_NAMES.request, async ({source,action,info}) => {
          if (source !== 'kg' || action !== 'search' || Object.keys(info).sort().join(',') !== 'artist,keyword,title') throw Error('unexpected route or metadata');
          const row = {id:'kg-id',title:info.title,artist:info.artist,album:'Studio',duration:123};
          switch (info.title) {
          case 'Live only': return [{...row,album:'Studio (Live)'}];
          case 'Ambiguous': return [row,{...row,id:'other-id'}];
          case 'Apple ID': return [{...row,id:'apple-id'}];
          default: return [row];
          }
        });
        lx.send(lx.EVENT_NAMES.inited,{sources:{
          tx:{type:'music',actions:['musicUrl'],qualitys:['128k']},wy:{type:'music',actions:['musicUrl'],qualitys:['320k']},
          kg:{type:'music',actions:['search','musicUrl'],qualitys:['128k','flac24bit']},
          mg:{type:'music',actions:['musicUrl'],qualitys:['128k']},kw:{type:'music',actions:['search']}}});
        """
        try await engine.importScript(source.replacingOccurrences(of: "kg-id", with: "wrong-script"), name: "Other")
        try await engine.importScript(source, name: "Selected")
        let selected = engine.scripts[1]
        let seed = Song(id: "apple-id", title: "Song", artist: "Artist", platform: "apple", album: "Studio", duration: 123)
        for (site, id, levels) in [("tx", "qq-mid", ["128k"]), ("wy", "456", ["320k"]), ("kg", "kg-id", ["flac24bit", "128k"]), ("mg", "697066", ["128k"])] {
            let matched = try await engine.matchCatalogSong(seed, script: selected, platform: site)
            precondition(matched.id == id && matched.platform == site && matched.searchScriptID == selected.id)
            if site == "mg" { precondition(matched.nativeIDs?["contentId"] == "600902000006889010" && matched.nativeIDs?["copyrightId"] == "60054702010") }
            let actual = try await engine.availableLevels(for: matched, script: selected)
            precondition(actual == levels)
            do { _ = try await engine.availableLevels(for: matched, script: engine.scripts[0]); fatalError("Accepted wrong script") }
            catch is SourceFailure {}
        }
        for (site, title) in [("kw", "Song"), ("kg", "Live only"), ("kg", "Ambiguous"), ("kg", "Apple ID")] {
            var input = seed
            input.title = title
            do { _ = try await engine.matchCatalogSong(input, script: selected, platform: site); fatalError("Accepted \(site) / \(title)") }
            catch is SourceFailure {}
        }
        precondition(CatalogFixture.trace == ["c.y.qq.com", "music.163.com", "c.musicapp.migu.cn"])
        let resolver = """
        lx.on(lx.EVENT_NAMES.request, async ({source,action,info}) => {
          const m = info.musicInfo;
          if (action !== 'musicUrl' || info.type !== '128k') throw Error('wrong action');
          if (source === 'mg' && (m.contentId !== '600902000006889010' || m.copyrightId !== '60054702010' || m.id !== '697066')) throw Error('wrong MG IDs');
          if (source === 'kw' && (m.songmid !== '440613' || m.musicRid !== 'MUSIC_440613')) throw Error('wrong KW IDs');
          if (source === 'kg' && (m.hash !== 'B5FB24746AF437BE697BFDBC7BA997E7' || m.albumId !== '976460')) throw Error('wrong KG IDs');
          return 'https://example.invalid/'+source;
        });
        const cap = {type:'music',actions:['musicUrl'],qualitys:['128k']};
        lx.send(lx.EVENT_NAMES.inited,{sources:{kw:cap,kg:cap,mg:cap,local:cap}});
        """
        try await engine.importScript(resolver, name: "Resolver only")
        let pinned = engine.scripts.last!
        for site in ["kw", "kg", "mg"] {
            var song = try await engine.matchCatalogSong(seed, script: pinned, platform: site)
            song.requestedQuality = "128k"
            _ = try await engine.downloadMedia(song) { url in
                precondition(url.absoluteString == "https://example.invalid/" + site)
                return url
            }
        }
        do { _ = try await engine.matchCatalogSong(seed, script: pinned, platform: "local"); fatalError("Unsupported route") }
        catch let error as SourceFailure { precondition(error.errorDescription?.contains("不支持") == true) }
        print("Scoped catalog matching and declared quality levels passed")
    }
}
