import Foundation

private final class CatalogResponse: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool {
        ["songsearch.kugou.com", "pd.musicapp.migu.cn", "www.kuwo.cn"].contains(request.url?.host)
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        let url = request.url!
        let params = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
        precondition(params.contains { $0.value == "稻香" })
        let json: String
        switch url.path {
        case "/song_search_v2":
            precondition(params.contains(URLQueryItem(name: "platform", value: "WebFilter")))
            json = #"{"status":1,"data":{"lists":[{"FileHash":"8909E1809908CD8E3BF6CF85D98B93F0","HQFileHash":"21AC928E1D68EC3632EF2CAE68718201","SQFileHash":"36AB2C542AF54578EFD376A4E2C57C1F","ID":"32042828","AlbumID":"960399","SongName":"稻香","SingerName":"周杰伦"}]}}"#
        case "/MIGUM2.0/v1.0/content/search_all.do":
            json = #"{"code":"000000","songResultData":{"result":[{"id":"697066","contentId":"600902000006889010","copyrightId":"60054702010","name":"稻香","singers":[{"name":"周杰伦"}]}]}}"#
        case "/search/searchMusicBykeyWord":
            json = #"{"abslist":[{"MUSICRID":"MUSIC_440613","SONGNAME":"稻香","ARTIST":"周杰伦","DURATION":"223"}]}"#
        default: fatalError("Unexpected catalog request \(url)")
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(json.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

@main struct LanyueCatalogProbe {
    @MainActor static func main() async throws {
        let args = CommandLine.arguments, base = args[3]
        if !args.contains("--live") { precondition(URLProtocol.registerClass(CatalogResponse.self)) }
        let engine = SourceEngine(store: URL(fileURLWithPath: args[1]), preload: URL(fileURLWithPath: args[2]), matcher: { _ in fatalError("Unexpected pooled search") })
        precondition(engine.scripts.isEmpty)
        var hits = [Song]()
        for site in LanyueCatalog.allCases {
            let songs = try await site.search(" 稻香 ")
            let hit = songs.first { $0.title == "稻香" && $0.artist.contains("周杰伦") }!
            precondition(hit.platform == site.rawValue && hit.metadataProvider == "lanyue" && hit.searchScriptID == nil)
            hits.append(hit)
            print("\(site.rawValue) \(songs.count) rows · \(hit.title) · \(hit.artist) · \(hit.id)")
        }
        for name in ["A", "B"] {
            let script = """
            lx.on(lx.EVENT_NAMES.request, async ({source, action, info}) => {
                if (action !== 'musicUrl') throw Error('unexpected action');
                const m = info.musicInfo;
                const fields = source === 'kg' ? [m.id, m.hash, m.songmid, m.albumId, m._types['320k'].hash, m._types.flac.hash] :
                    source === 'mg' ? [m.id, m.songmid, m.contentId, m.copyrightId] : [m.songmid, m.musicRid];
                return '\(base)/'+['\(name)',source,info.type,...fields].map(encodeURIComponent).join('/');
            });
            const cap = {type:'music',actions:['musicUrl'],qualitys:['320k','flac']};
            lx.send(lx.EVENT_NAMES.inited,{sources:{kg:cap,mg:cap,kw:cap}});
            """
            try await engine.importScript(script, name: name)
        }
        var expected = [String]()
        for script in engine.scripts {
            let tier = script.name == "A" ? "320k" : "flac"
            for hit in hits {
                let site = hit.platform!, ids = hit.nativeIDs!
                var selected = try await engine.matchCatalogSong(hit, script: script, platform: site)
                do { _ = try await engine.matchCatalogSong(hit, script: script, platform: site == "kg" ? "mg" : "kg"); fatalError("Accepted cross-site route") } catch is SourceFailure {}
                selected.requestedQuality = "128k"
                do { _ = try await engine.resolveMedia(selected); fatalError("Accepted undeclared tier") } catch is SourceFailure {}
                selected.requestedQuality = tier
                let media = try await engine.resolveMedia(selected)
                precondition(media.source == script.name && media.quality == tier && media.match.id == hit.id)
                let fields: [String]
                switch site {
                case "kg": fields = [hit.id, hit.id, ids["songmid"]!, ids["albumId"]!, ids["320hash"]!, ids["sqhash"]!]
                case "mg": fields = [hit.id, hit.id, ids["contentId"]!, ids["copyrightId"]!]
                default: fields = [hit.id, "MUSIC_" + hit.id]
                }
                expected.append("/" + ([script.name, site, tier] + fields).joined(separator: "/"))
            }
        }
        let (data, _) = try await URLSession.shared.data(from: URL(string: base + "/capture")!)
        let trace = try JSONDecoder().decode([String].self, from: data)
        precondition(trace == expected, "Unexpected requests: \(trace)")
        if !args.contains("--live") {
            precondition(trace[0].hasSuffix("/8909E1809908CD8E3BF6CF85D98B93F0/8909E1809908CD8E3BF6CF85D98B93F0/32042828/960399/21AC928E1D68EC3632EF2CAE68718201/36AB2C542AF54578EFD376A4E2C57C1F"))
            precondition(trace[1].hasSuffix("/697066/697066/600902000006889010/60054702010"))
        }
        print(trace.joined(separator: "\n"))
    }
}
