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
        precondition(item?.id == "abcd" && item?.song.artist == "Singer")
        print("Passed LX and CommonJS resolution, rejected import rollback, persisted selection, QQ IDs and track mapping")
        let encoded = Data("[00:01.00]你 &amp; 我".utf8).base64EncodedString()
        precondition(SourceCatalog.decodeLyrics(["code": 0, "lyric": encoded]) == "[00:01.00]你 & 我")
        var checks = 0
        var embedded = song
        embedded.lyrics = "existing"
        await SourceCatalog.applyLyrics(for: embedded, isCurrent: { checks += 1; return checks == 1 }, apply: { _ in fatalError("stale lyric applied") })
        precondition(checks == 2)
        if let path = ProcessInfo.processInfo.environment["PROVIDER_EXAMPLE"], let base = ProcessInfo.processInfo.environment["PROVIDER_BASE"] {
            let text = try String(contentsOfFile: path, encoding: .utf8).replacingOccurrences(of: "const API_URL = '';", with: "const API_URL = '\(base)';")
            try await restored.importScript(text, name: "example1.js")
            try restored.setQuality(.standard)
            let again = SourceEngine(store: store, preload: preload)
            let output = try await again.resolve(song)
            precondition(output.absoluteString == "https://example.test/mid/320k")
            precondition(again.scripts.last?.exported?["id"] == "example1" && again.scripts.last?.name == "示例音源1")
            print("README example1 passed HTTP -> JSC -> URL with restored 320k and exported metadata")
        }
        if CommandLine.arguments.contains("--live") {
            do { let list = try await SourceCatalog.chart(); print("QQ chart: \(list.1.count)") } catch { print("QQ chart: \(error.localizedDescription)") }
            let known = Song(id: "004IArbh3ytHgR", title: "稻香", artist: "周杰伦", platform: "tx")
            do { print("QQ lyrics characters:", try await SourceCatalog.lyrics(known)?.count ?? 0) } catch { print("QQ lyrics:", error.localizedDescription) }
            for destination in [CatalogDestination(kind: .artist, mid: "0025NhlN2yWrP4", name: "周杰伦"), CatalogDestination(kind: .album, mid: "002Neh8l0uciQZ", name: "十一月的萧邦")] {
                do { print(destination.name, try await SourceCatalog.detail(destination).count) } catch { print(destination.name, error.localizedDescription) }
            }
            do { let songs = try await SourceCatalog.search("Bach", page: 1); print("QQ search: \(songs.count)") } catch { print("QQ search: \(error.localizedDescription)") }
            do { let list = try await SourceCatalog.playlist("7011264345"); print("QQ playlist: \(list.1.count)") } catch { print("QQ playlist: \(error.localizedDescription)") }
        }
    }
}
SWIFT
xcrun clang -fobjc-arc -c Runtime/CyMusicUserApiRuntime.m -o "$work/runtime.o"
xcrun swiftc -import-objc-header Runtime/CyMusicUserApiRuntime.h -framework JavaScriptCore -framework Security "$work/runtime.o" ../App/Song.swift Catalog.swift ProviderSession.swift SourceEngine.swift "$work/Probe.swift" -o "$work/probe"
if [[ " ${*} " == *" --example "* ]]; then
    curl --fail --silent --show-error --max-time 20 'https://raw.githubusercontent.com/gyc-12/CyMusic-ImportMusicApi-Example/643dc33cb38a2eb3f72ac11b171100dd10834603/example1.js' -o "$work/example1.js"
    python3 - "$work" "$@" <<'PY'
import http.server, json, os, subprocess, sys, threading
from pathlib import Path
work = Path(sys.argv[1]).resolve()
class ExampleEndpoint(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path != "/mid/320k":
            self.send_error(404)
            return
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(json.dumps({"url": "https://example.test" + self.path}).encode())
with http.server.HTTPServer(("127.0.0.1", 0), ExampleEndpoint) as server:
    threading.Thread(target=server.serve_forever, daemon=True).start()
    env = dict(os.environ, PROVIDER_EXAMPLE=str(work / "example1.js"), PROVIDER_BASE=f"http://127.0.0.1:{server.server_port}")
    subprocess.run([work / "probe", work, *sys.argv[2:]], env=env, check=True)
PY
else
    "$work/probe" "$work" "$@"
fi
