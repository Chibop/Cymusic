"""Exercise script tabs in a dedicated booted simulator with CyMusic already installed."""
import json
from pathlib import Path
import subprocess
import sys

simulator = sys.argv[1]
root = Path(__file__).resolve().parents[1]
container = subprocess.check_output([
    'xcrun', 'simctl', 'get_app_container', simulator, 'com.music.player.gyc', 'data'
], text=True).strip()
store = Path(container, 'Library/Application Support/Cymusic/providers.json')
scripts = []
for name, sites in [('a', ['kg', 'kw']), ('b', ['mg'])]:
    routes = {site: ['search', 'musicUrl'] for site in sites}
    capabilities = {site: {'type': 'music', 'actions': actions, 'qualitys': ['128k', '320k']}
                    for site, actions in routes.items()}
    source = """lx.on(lx.EVENT_NAMES.request, async ({source,action}) => {
      if (action === 'musicUrl') throw Error('Destination QA unavailable');
      return [{id:source+'-qa',title:'Hello',artist:'Adele',album:'Hello - Single',duration:295.5}];
    });lx.send(lx.EVENT_NAMES.inited,{sources:""" + json.dumps(capabilities) + '});'
    scripts.append(dict(id='destination-qa-'+name, name='Destination QA '+name.upper(),
                        routes=routes, text=source))
store.parent.mkdir(parents=True, exist_ok=True)
with store.open('x') as f:
    json.dump({'scripts': scripts}, f)
try:
    subprocess.run(['xcodebuild', '-quiet', '-project', 'CyMusicNative.xcodeproj', '-scheme', 'CyMusic',
                    '-destination', 'id='+simulator, '-parallel-testing-enabled', 'NO',
                    '-only-testing:CyMusicUITests/CatalogSearchTests/testScriptTabsQueryEverySiteAndExposeTierActions',
                    'test'], cwd=root, check=True)
finally:
    current = subprocess.check_output(['xcrun', 'simctl', 'get_app_container', simulator, 'com.music.player.gyc', 'data'], text=True).strip()
    store = Path(current, 'Library/Application Support/Cymusic/providers.json')
    if store.exists() and json.loads(store.read_text()) == {'scripts': scripts}:
        store.unlink()
