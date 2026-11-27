"""Run from anywhere on macOS: python3 Native/Discovery/.fixtures/check.py"""
import http.server
from pathlib import Path
import shutil
import subprocess
import tempfile
import threading
import wave

native = Path(__file__).resolve().parents[2]
with tempfile.TemporaryDirectory() as tmp:
    root = Path(tmp)
    src = root / 'Sources'
    src.mkdir()
    for path in ['App/LanguageSettings.swift', 'App/Song.swift', 'Discovery/DownloadCenter.swift', 'Discovery/DiscoveryCache.swift',
                 'Playback/PlaybackMedia.swift', 'Library/Library.swift', 'Library/LegacyMigration.swift',
                 *['SourcesEngine/' + f + '.swift' for f in ['Catalog', 'PoolCatalog', 'PoolMatcher', 'ProviderSession', 'SourceEngine']]]:
        shutil.copy(native / path, src)
    (root / 'MMKV').symlink_to(native / 'Vendor/MMKV')
    shutil.copy(Path(__file__).with_name('Probe.swiftfixture'), src / 'Probe.swift')
    shutil.copy(native / 'LegacyTests/Harness.swiftmanifest', root / 'Package.swift')
    runtime = native / 'SourcesEngine/Runtime'
    subprocess.run(['xcrun', 'clang', '-fobjc-arc', '-c', runtime/'CyMusicUserApiRuntime.m', '-o', root/'runtime.o'], check=True)
    with wave.open(str(root/'audio.wav'), 'wb') as wav:
        wav.setparams((1, 2, 22050, 0, 'NONE', 'not compressed'))
        wav.writeframes(b'\0\0' * 22050)
    requests = []
    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            requests.append(self.path)
            if self.path != '/audio.wav':
                self.send_error(404)
                return
            self.send_response(200)
            self.send_header('Content-Type', 'audio/wav')
            self.end_headers()
            self.wfile.write((root/'audio.wav').read_bytes())
    with http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler) as server:
        threading.Thread(target=server.serve_forever, daemon=True).start()
        subprocess.run(['swift', 'run', '--package-path', root, '-Xswiftc', '-import-objc-header', '-Xswiftc', runtime/'CyMusicUserApiRuntime.h', '-Xlinker', root/'runtime.o', '-Xlinker', '-framework', '-Xlinker', 'JavaScriptCore', '-Xlinker', '-framework', '-Xlinker', 'Security', 'Probe', root, runtime/'user-api-preload.js', f'http://127.0.0.1:{server.server_port}'], check=True, timeout=240)
        assert requests == ['/audio.wav', '/bad.wav', '/audio.wav'], requests
        print('Server verified only two successful transfers (including recovery after deletion) and one failure.')
