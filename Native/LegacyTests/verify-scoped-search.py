"""Compile the actual native engine and assert the exact HTTP request trace."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from tempfile import TemporaryDirectory
from threading import Thread
from subprocess import run
from urllib.parse import unquote
import json

root = Path(__file__).resolve().parents[1] / 'SourcesEngine'
seen = []
class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == '/capture':
            data = json.dumps(seen).encode()
        else:
            seen.append(unquote(self.path))
            data = b'ID3' + bytes(125) if self.path == '/audio' else b'{}'
        self.send_response(200)
        self.send_header('Content-Type', 'audio/mpeg' if self.path == '/audio' else 'application/json')
        self.send_header('Content-Length', str(len(data)))
        self.end_headers(); self.wfile.write(data)

with TemporaryDirectory() as tmp, ThreadingHTTPServer(('127.0.0.1', 0), Handler) as srv:
    Thread(target=srv.serve_forever, daemon=True).start()
    obj = tmp + '/runtime.o'; exe = tmp + '/probe'
    run(['xcrun','clang','-fobjc-arc','-c','Runtime/CyMusicUserApiRuntime.m','-o',obj], cwd=root, check=True)
    run(['xcrun','swiftc','-D','SCOPED_SEARCH_PROBE','-import-objc-header','Runtime/CyMusicUserApiRuntime.h','-framework','JavaScriptCore','-framework','Security',obj,'../App/LanguageSettings.swift','../App/Song.swift','Catalog.swift','PoolCatalog.swift','PoolMatcher.swift','ProviderSession.swift','SourceEngine.swift','ScopedSearch.swift','ScopedSearchProbe.swift','-o',exe], cwd=root, check=True)
    run([exe,tmp+'/store.json',str(root/'Runtime/user-api-preload.js'),f'http://127.0.0.1:{srv.server_port}'],check=True,timeout=45)
    srv.shutdown()
