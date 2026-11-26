#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
work=$(mktemp -d .probe-XXXXXX)
trap 'rm -rf "$work"' EXIT
cat > "$work/Probe.swift" <<'SWIFT'
import Foundation
@main struct Probe {
    @MainActor static func main() async throws {
        let store = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("providers.json")
        let preload = URL(fileURLWithPath: "Runtime/user-api-preload.js")
        let engine = SourceEngine(store: store, preload: preload)
        let song = Song(id: "mid", title: "Test", artist: "Artist", platform: "tx")
        let expected = "https://example.com/mid/128k"
        let lx = """
        /** @name Fixture */
        lx.on(lx.EVENT_NAMES.request, async ({info}) => 'https://example.com/'+info.musicInfo.songmid+'/'+info.type);
        lx.send(lx.EVENT_NAMES.inited,{sources:{tx:{type:'music',actions:['musicUrl'],qualitys:['128k']}}});
        """
        let common = "module.exports.getMusicUrl = async (name,artist,mid,q) => 'https://example.com/'+mid+'/'+q;"
        for script in [lx, common] {
            try await engine.importScript(script, name: "Test")
            let url = try await engine.resolve(song)
            precondition(url.absoluteString == expected)
        }
        do { try await engine.importScript("throw Error('invalid')", name: "Rejected"); fatalError() } catch { }
        precondition(engine.scripts.count == 2)
        let restored = SourceEngine(store: store, preload: preload)
        let url = try await restored.resolve(song)
        precondition(url.absoluteString == expected)
        let id = try SourceCatalog.playlistID("https://y.qq.com/n/ryqq/playlist/123456")
        precondition(id == "123456")
        let item = SourceCatalog.qqSong(["mid":"abcd", "title":"Title", "singer":[["name":"Singer"]]])
        precondition(item?.id == "abcd" && item?.artist == "Singer")
        print("Passed LX and CommonJS resolution, rejected import rollback, persisted selection, QQ IDs and track mapping")
        if CommandLine.arguments.contains("--live") {
            do { let list = try await SourceCatalog.chart(); print("QQ chart: \(list.1.count)") } catch { print("QQ chart: \(error.localizedDescription)") }
            do { let songs = try await SourceCatalog.previews("Bach"); print("Apple previews: \(songs.count)") } catch { print("Apple previews: \(error.localizedDescription)") }
            do { let songs = try await SourceCatalog.search("Bach", page: 1); print("QQ search: \(songs.count)") } catch { print("QQ search: \(error.localizedDescription)") }
            do { let list = try await SourceCatalog.playlist("7011264345"); print("QQ playlist: \(list.1.count)") } catch { print("QQ playlist: \(error.localizedDescription)") }
        }
    }
}
SWIFT
xcrun clang -fobjc-arc -c Runtime/CyMusicUserApiRuntime.m -o "$work/runtime.o"
xcrun swiftc -import-objc-header Runtime/CyMusicUserApiRuntime.h -framework JavaScriptCore -framework Security "$work/runtime.o" ../App/Song.swift Catalog.swift ProviderSession.swift SourceEngine.swift "$work/Probe.swift" -o "$work/probe"
"$work/probe" "$work" "$@"
