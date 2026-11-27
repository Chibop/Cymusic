#if SCOPED_SEARCH_PROBE
import Foundation

// Compile as a macOS command-line probe alongside the engine and its ObjC bridge.
// Arguments: fresh provider-store path, preload JS path, request-capture server URL.
@main struct ScopedSearchProbe {
    @MainActor static func main() async throws {
        let args = CommandLine.arguments
        let engine = SourceEngine(store: URL(fileURLWithPath: args[1]), preload: URL(fileURLWithPath: args[2]),
                                  matcher: { _ in fatalError("Unexpected catalog matcher") })
        let base = args[3]
        func source(_ name: String) -> String {
            """
            lx.on(lx.EVENT_NAMES.request, async ({source,action,info}) => {
              const key = action === 'search' ? info.keyword : info.musicInfo.id;
              if (action === 'search' && (info.title || info.artist)) throw Error('expected free text');
              await new Promise((resolve,reject) => lx.request('\(base)/\(name)/'+source+'/'+action+'/'+encodeURIComponent(key),{},
                (err,res) => err ? reject(err) : resolve(res)));
              if (action === 'musicUrl') return '\(base)/audio';
              return [{id:'00042',title:'不同的曲名',artist:'歌手',album:'唱片',duration:123,isrc:'AA1234567890'}];
            });
            lx.send(lx.EVENT_NAMES.inited,{sources:{tx:{type:'music',actions:['search','musicUrl'],qualitys:['128k']},
              wy:{type:'music',actions:['musicUrl'],qualitys:['128k']},mg:{type:'music',actions:['search'],qualitys:[]},kg:{type:'music',actions:['search'],qualitys:[]}}});
            """
        }
        try await engine.importScript(source("unused"), name: "Other")
        try await engine.importScript(source("selected"), name: "Selected")
        try await engine.importScript("module.exports.getMusicUrl=async()=> '\(base)/resolver';", name: "Resolver")
        let script = engine.scripts[1], resolver = engine.scripts[2]
        let searchable = try await engine.declaredSearchPlatforms(for: script)
        let downloadable = try await engine.declaredDownloadPlatforms(for: script)
        let unsupported = try await engine.declaredSearchPlatforms(for: resolver)
        precondition(searchable == ["kg", "mg", "tx"] && downloadable == ["tx", "wy"] && unsupported.isEmpty)
        let invalid: [(SourceScript, Set<String>)] = [(script, []), (script, ["wy", "tx"]), (resolver, ["tx"])]
        for (item, platforms) in invalid {
            do { _ = try await engine.scopedSearch("forbidden", script: item, platforms: platforms); fatalError("Expected scope rejection") }
            catch is SourceFailure { }
        }
        let result = try await engine.scopedSearch("蓝 色", script: script, platforms: ["mg", "tx"])
        precondition(result.failures.isEmpty && result.songs.map(\.platform) == ["mg", "tx"])
        precondition(result.songs.allSatisfy { $0.searchScriptID == script.id && $0.id == "00042" && $0.title == "不同的曲名" && $0.album == "唱片" && $0.duration == 123 && $0.isrc == "AA1234567890" })
        do { _ = try await engine.resolve(result.songs[0]); fatalError("Unexpected playback on search-only route") }
        catch is SourceFailure { }
        let played = try await engine.resolve(result.songs[1]); precondition(played.absoluteString == base + "/audio")
        _ = try await engine.downloadMedia(result.songs[1]) { url in precondition(url == played); return url }
        let (log, _) = try await URLSession.shared.data(from: URL(string: base + "/capture")!)
        let captured = try JSONDecoder().decode([String].self, from: log)
        precondition(captured == ["/selected/mg/search/蓝 色", "/selected/tx/search/蓝 色", "/selected/tx/musicUrl/00042", "/audio", "/selected/tx/musicUrl/00042"], "Unexpected requests: \(captured)")
        print("Scoped search verified. Captured requests: \(captured)")
    }
}
#endif
