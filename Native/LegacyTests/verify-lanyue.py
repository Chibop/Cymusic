"""Exercise the shipped Lanyue search and exact selected resolver path."""
import json
import subprocess
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from tempfile import TemporaryDirectory
from threading import Thread

root = Path(__file__).resolve().parents[1] / 'SourcesEngine'
seen = []


class AudioCapture(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == '/capture':
            body, mime = json.dumps(seen).encode(), 'application/json'
        else:
            seen.append(self.path)
            body, mime = b'ID3' + bytes(125), 'audio/mpeg'
        self.send_response(200)
        self.send_header('Content-Type', mime)
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)


with TemporaryDirectory() as tmp, ThreadingHTTPServer(('127.0.0.1', 0), AudioCapture) as server:
    Thread(target=server.serve_forever, daemon=True).start()
    obj, exe = Path(tmp) / 'runtime.o', Path(tmp) / 'probe'
    subprocess.run(['xcrun', 'clang', '-fobjc-arc', '-c', 'Runtime/CyMusicUserApiRuntime.m', '-o', obj], cwd=root, check=True)
    subprocess.run(['xcrun', 'swiftc', '-import-objc-header', 'Runtime/CyMusicUserApiRuntime.h', '-framework', 'JavaScriptCore', '-framework', 'Security', obj,
                    '../App/LanguageSettings.swift', '../App/Song.swift', 'Catalog.swift', 'PoolCatalog.swift', 'PoolMatcher.swift', 'ProviderSession.swift',
                    'SourceEngine.swift', 'ScopedSearch.swift', '../LegacyTests/LanyueCatalogProbe.swift', '-o', exe], cwd=root, check=True)
    for mode in ([[], ['--live']] if '--live' in sys.argv else [[]]):
        seen.clear()
        store = Path(tmp) / ('live.json' if mode else 'fixture.json')
        subprocess.run([exe, store, root / 'Runtime/user-api-preload.js', f'http://127.0.0.1:{server.server_port}', *mode], check=True, timeout=90)
    server.shutdown()
