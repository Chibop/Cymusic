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
        let base = ProcessInfo.processInfo.environment["MEDIA_BASE"]!
        let song = Song(id: "mid", title: "Test", artist: "Artist", platform: "tx")
        let engine = SourceEngine(store: store, preload: preload, matcher: { _ in [song] })
        try await verifyExact(store.deletingLastPathComponent(), base, preload)
        if CommandLine.arguments.contains("--exact") { return }
        if CommandLine.arguments.contains("--profile") {
            // Store/import is setup, not part of tap-to-validated-URL latency.
            let incompatible = "const end=Date.now()+150; while(Date.now()<end){}; lx.send(lx.EVENT_NAMES.inited,{sources:{kg:{actions:['musicUrl'],qualitys:['128k']}}});"
            try await engine.importScript(incompatible, name: "Incompatible")
            try await engine.importScript("module.exports.getMusicUrl=async()=> '\(base)/offline/profile'", name: "Unavailable")
            try await engine.importScript("module.exports.getMusicUrl=async()=> '\(base)/profile-audio'", name: "Good")
            let foreign = Song(id: "external", title: song.title, artist: song.artist, platform: "apple")
            for trial in 1...5 {
                var lookups = 0
                let subject = SourceEngine(store: store, preload: preload, matcher: { _ in
                    lookups += 1; try await Task.sleep(nanoseconds: 120_000_000); return [song]
                })
                for phase in ["cold", "warm"] {
                    let before = lookups, start = ProcessInfo.processInfo.systemUptime
                    let result = try await subject.resolveMedia(foreign)
                    precondition(result.match.id == song.id && result.source == "Good")
                    print("profile trial=\(trial) phase=\(phase) ms=\(Int((ProcessInfo.processInfo.systemUptime-start)*1000)) lookups=\(lookups-before)")
                }
            }
            return
        }
        let lx = """
        lx.on(lx.EVENT_NAMES.request, async ({info}) => '\(base)/offline/'+info.type);
        lx.send(lx.EVENT_NAMES.inited,{sources:{tx:{type:'music',actions:['musicUrl'],qualitys:['flac','320k','128k']}}});
        """
        let common = "module.exports.getMusicUrl = async (name,artist,mid,q) => '\(base)/media/'+mid+'/'+q;"
        try await engine.importScript(lx, name: "Offline")
        try await engine.importScript(common, name: "Working")
        try engine.setQuality(.lossless)
        do { try await engine.importScript("throw Error('invalid')", name: "Rejected"); fatalError() } catch { }
        precondition(engine.scripts.count == 2)
        let restored = SourceEngine(store: store, preload: preload, matcher: { _ in [song] })
        let foreign = Song(id: "apple-id", title: song.title, artist: song.artist, platform: "apple")
        let result = try await restored.resolveMedia(foreign)
        precondition(result.url.absoluteString == base + "/media/mid/128k" && result.match.id == "mid" && result.source == "Working" && result.quality == "128k")
        let download = try await restored.downloadMedia(foreign) { url in
            let (data, raw) = try await URLSession.shared.data(from: url)
            guard (raw as? HTTPURLResponse)?.statusCode == 200, data == Data("ID3fixture".utf8) else { throw URLError(.cannotDecodeContentData) }
            let dest = store.deletingLastPathComponent().appendingPathComponent("download")
            try data.write(to: dest); return dest
        }
        precondition(download.url.isFileURL && download.match.id == "mid" && download.quality == "128k")
        // Hints must not change full-transfer fallback, including a preferred
        // provider that passes playback validation but fails the real save.
        var attempted: [String] = []
        let recovered = try await restored.downloadMedia(foreign) { url in
            attempted.append(url.path)
            guard url.path == "/offline/flac" else { throw URLError(.cannotDecodeContentData) }
            return download.url
        }
        precondition(attempted == ["/media/mid/flac", "/media/mid/320k", "/media/mid/128k", "/offline/flac"] && recovered.source == "Offline")
        var variant = foreign; variant.album = "Live"
        let identity = SourceEngine(store: store, preload: preload, matcher: { input in input.album == nil ? [song] : [] })
        _ = try await identity.resolveMedia(foreign)
        do { _ = try await identity.resolveMedia(variant); fatalError("reused studio match for live") } catch {}
        let hanging = SourceEngine(store: store.appendingPathExtension("hang"), preload: preload, matcher: { _ in [] })
        try await hanging.importScript("module.exports.getMusicUrl=()=>new Promise(()=>{})", name: "Never responds")
        func elapsed(_ start: TimeInterval) -> Double { ProcessInfo.processInfo.systemUptime - start }
        let wait = ProcessInfo.processInfo.systemUptime
        do { _ = try await hanging.resolve(song); fatalError("accepted hung request") } catch {}
        precondition((4...8).contains(elapsed(wait)))
        for target in [song, Song(id: "slow", title: "Slow", artist: "", url: URL(string: base+"/drip"))] {
            let task = Task { try await hanging.resolve(target) }
            try await Task.sleep(nanoseconds: 250_000_000)
            let stop = ProcessInfo.processInfo.systemUptime; task.cancel()
            do { _ = try await task.value; fatalError("cancelled play succeeded") } catch is CancellationError {}
            precondition(elapsed(stop) < 1.5)
        }
        let direct = SourceEngine(store: store.appendingPathExtension("direct"), preload: preload)
        let start = ProcessInfo.processInfo.systemUptime
        do { _ = try await direct.resolve(Song(id: "slow", title: "Slow", artist: "", url: URL(string: base+"/drip"))); fatalError("accepted unbounded probe") } catch {}
        precondition((3...7).contains(elapsed(start)))
        print("Hung request, trickling media deadline, cancellation, version identity and transfer fallback passed")
        let searcher = """
        lx.on(lx.EVENT_NAMES.request, async ({info,action}) => {if(action !== 'search') throw Error('unexpected'); return [{id:'kg-id',title:info.title,artist:info.artist}];});
        lx.send(lx.EVENT_NAMES.inited,{sources:{kg:{type:'music',actions:['search']}}});
        """
        let kg = """
        lx.on(lx.EVENT_NAMES.request, async ({info,action}) => {if(action !== 'musicUrl') throw Error('unexpected'); return '\(base)/media/'+info.musicInfo.hash+'/'+info.type;});
        lx.send(lx.EVENT_NAMES.inited,{sources:{kg:{type:'music',actions:['musicUrl'],qualitys:['128k']}}});
        """
        try await restored.importScript(searcher, name: "Search only")
        try await restored.importScript(kg, name: "KG resolver")
        let searched = try await restored.resolveMedia(foreign)
        precondition(searched.match.id == "kg-id" && searched.match.platform == "kg" && searched.source == "KG resolver")
        let native = try await restored.resolve(searched.match)
        precondition(native == searched.url)
        let slow = SourceEngine(store: store.appendingPathExtension("slow"), preload: preload)
        let spin = "const until=Date.now()+1200; while(Date.now()<until){};"
        try await slow.importScript(spin + common, name: "Slow initialization")
        let slowID = slow.scripts[0].id
        slow.testAll(); slow.testAll()
        let begin = ProcessInfo.processInfo.systemUptime
        var ticks = 0, maxGap = 0.0, previous = begin
        while slow.statuses[slowID] == "测试中…" {
            try await Task.sleep(nanoseconds: 20_000_000)
            let now = ProcessInfo.processInfo.systemUptime
            maxGap = max(maxGap, now-previous); previous = now; ticks += 1
            precondition(now-begin < 8)
        }
        precondition(slow.statuses[slowID] == "正常" && ticks >= 10 && maxGap < 0.25, "status=\(String(describing: slow.statuses[slowID])) ticks=\(ticks) gap=\(maxGap)")
        print("Pool, search, non-tx, transfer, provenance and responsiveness passed: \(ticks) main-actor ticks; max gap \(maxGap)s")
        let id = try SourceCatalog.playlistID("https://y.qq.com/n/ryqq/playlist/123456")
        precondition(id == "123456")
        let item = SourceCatalog.qqSong(["mid":"abcd", "title":"Title", "singer":[["name":"Singer"]]])
        precondition(item?.id == "abcd" && item?.song.artist == "Singer")
        print("Passed LX and CommonJS resolution, rejected import rollback, restored pool, QQ IDs and track mapping")
        let encoded = Data("[00:01.00]你 &amp; 我".utf8).base64EncodedString()
        precondition(SourceCatalog.decodeLyrics(["code": 0, "lyric": encoded]) == "[00:01.00]你 & 我")
        var checks = 0
        var embedded = song
        embedded.lyrics = "existing"
        await SourceCatalog.applyLyrics(for: embedded, isCurrent: { checks += 1; return checks == 1 }, apply: { _ in fatalError("stale lyric applied") })
        precondition(checks == 2)
        if let path = ProcessInfo.processInfo.environment["PROVIDER_EXAMPLE"], let api = ProcessInfo.processInfo.environment["PROVIDER_BASE"] {
            let text = try String(contentsOfFile: path, encoding: .utf8).replacingOccurrences(of: "const API_URL = '';", with: "const API_URL = '\(api)';")
            try await restored.importScript(text, name: "example1.js")
            try restored.setQuality(.standard)
            for item in restored.scripts where item.exported?["id"] != "example1" { try restored.remove(item) }
            let again = SourceEngine(store: store, preload: preload)
            let output = try await again.resolve(song)
            precondition(output.absoluteString == base + "/example-audio")
            precondition(again.scripts.last?.exported?["id"] == "example1" && again.scripts.last?.name == "示例音源1")
            print("README example1 passed HTTP -> JSC -> URL with restored 320k and exported metadata")
        }
        try await verifyBulk(store.deletingLastPathComponent(), base, preload)
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
cp BulkQueueProbe.swiftfixture "$work/BulkQueueProbe.swift"
xcrun swiftc -import-objc-header Runtime/CyMusicUserApiRuntime.h -framework JavaScriptCore -framework Security "$work/runtime.o" ../App/LanguageSettings.swift ../App/Song.swift Catalog.swift PoolCatalog.swift PoolMatcher.swift ProviderSession.swift SourceEngine.swift ../Discovery/DownloadCenter.swift ../Playback/PlaybackMedia.swift "$work/BulkQueueProbe.swift" "$work/Probe.swift" -o "$work/probe"
if [[ $# -gt 0 && " ${*} " == *" --example "* ]]; then
    curl --fail --silent --show-error --max-time 20 'https://raw.githubusercontent.com/gyc-12/CyMusic-ImportMusicApi-Example/643dc33cb38a2eb3f72ac11b171100dd10834603/example1.js' -o "$work/example1.js"
fi
python3 - "$work" "$@" <<'PY'
import io, wave, http.server, json, os, subprocess, sys, threading, time
from pathlib import Path
work = Path(sys.argv[1]).resolve()
seen = []; times = []
buf = io.BytesIO()
with wave.open(buf, 'wb') as wav:
    wav.setparams((1, 2, 8000, 0, 'NONE', '')); wav.writeframes(bytes(16000))

route_wav = io.BytesIO()
with wave.open(route_wav, 'wb') as wav:
    wav.setparams((1, 2, 44100, 0, 'NONE', '')); wav.writeframes(bytes(512 * 1024))

class Endpoint(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args): pass
    def do_GET(self):
        seen.append(self.path); times.append(time.monotonic())
        base = f"http://127.0.0.1:{self.server.server_port}"
        if self.path.startswith('/exact/'):
            _, _, label, site, track, tier = self.path.split('/')
            if tier == '320k': self.send_error(503); return
            marker = {('A','128k'):1, ('A','flac24bit'):2, ('B','128k'):3}[(label,tier)]
            body = buf.getvalue()[:-1] + bytes([marker])
            self.send_response(200); self.send_header('Content-Type','audio/wav'); self.send_header('Content-Length', str(len(body))); self.end_headers(); self.wfile.write(body); return
        if self.path.startswith('/routes/selected/kw/musicUrl/'):
            body = route_wav.getvalue(); self.send_response(200); self.send_header('Content-Type','audio/wav')
            self.send_header('Content-Length',str(len(body))); self.end_headers()
            if self.path.endswith('/flac'):
                self.wfile.write(body[:1024]); return
            for i in range(0,len(body),16384):
                self.wfile.write(body[i:i+16384]); self.wfile.flush(); time.sleep(.08)
            return
        if self.path == '/drip':
            self.send_response(200); self.send_header('Content-Type','audio/mpeg'); self.end_headers()
            try:
                for _ in range(80):
                    self.wfile.write(b'a'); self.wfile.flush(); time.sleep(0.2)
            except (BrokenPipeError, ConnectionResetError): pass
            return
        if self.path == '/bulk/noheader':
            self.send_error(429); return
        if self.path == '/bulk/metadata' or (self.path == '/bulk/flac24bit' and seen.count(self.path) == 1):
            self.send_response(429); self.send_header('Retry-After','7200' if self.path.endswith('metadata') else '3'); self.end_headers(); return
        if self.path == '/bulk/flac24bit':
            self.send_error(503); return
        if self.path == '/bulk/flac':
            body, mime = buf.getvalue(), 'audio/wav'
        elif self.path == '/mid/320k':
            body, mime = json.dumps({'url':base+'/example-audio'}).encode(), 'application/json'
        elif self.path.startswith('/offline/'):
            if self.path == '/offline/profile': time.sleep(0.12)
            self.send_error(503); return
        elif self.path.endswith('/flac'):
            body, mime = b'{"error":"unavailable"}', 'application/json'
        elif self.path.endswith('/320k'):
            body, mime = b'', 'audio/mpeg'
        else: body, mime = b'ID3fixture', 'audio/mpeg'
        self.send_response(200); self.send_header('Content-Type',mime); self.end_headers(); self.wfile.write(body)
with http.server.ThreadingHTTPServer(('127.0.0.1',0),Endpoint) as server:
    threading.Thread(target=server.serve_forever,daemon=True).start()
    env = dict(os.environ, MEDIA_BASE=f'http://127.0.0.1:{server.server_port}')
    if '--example' in sys.argv: env.update(PROVIDER_EXAMPLE=str(work/'example1.js'), PROVIDER_BASE=env['MEDIA_BASE'])
    subprocess.run([work/'probe', work, *sys.argv[2:]], env=env, check=True, timeout=180)
    exact = [p for p in seen if p.startswith('/exact/')]
    track = exact[0].split('/')[4]
    assert exact == [f'/exact/{script}/kg/{track}/{tier}' for script,tier in [('A','128k'),('A','flac24bit'),('A','128k'),('A','flac24bit'),('B','128k'),('A','320k'),('A','320k')]], exact
    print('Verified exact requests:', exact)
    if '--exact' in sys.argv: sys.exit(0)
    if '--profile' in sys.argv:
        print('profile HTTP requests:', {p:seen.count(p) for p in sorted(set(seen))}); sys.exit(0)
    expected = ['/offline/flac','/offline/320k','/offline/128k','/media/mid/flac','/media/mid/320k','/media/mid/128k']
    assert [p for p in seen if not p.startswith('/exact/')][:9] == expected + expected[3:], seen
    assert [p for p in seen if p.startswith('/routes/')] == ['/routes/selected/kw/search','/routes/selected/kw/musicUrl/flac','/routes/selected/kw/musicUrl/128k'], seen
    bulk = [(p, t) for p,t in zip(seen,times) if p.startswith('/bulk/')]
    assert [p for p,t in bulk] == ['/bulk/flac24bit','/bulk/flac24bit','/bulk/flac','/bulk/flac24bit','/bulk/flac','/bulk/metadata','/bulk/metadata'] + ['/bulk/noheader'] * 3, bulk
    assert bulk[-1][1] - bulk[-2][1] >= 4 and bulk[-2][1] - bulk[-3][1] >= 2, bulk
    assert bulk[1][1] - bulk[0][1] >= 3 and all(b[1]-a[1] >= .60 for a,b in zip(bulk[1:4],bulk[2:5])), bulk
    print('HTTP server verified retry order, pacing, Retry-After deadline and no rotation on 429.')
PY
