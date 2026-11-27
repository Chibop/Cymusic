"""Seed/verify NavigationTests/testCacheDeletionFromMenuAndAlbumSurvivesRelaunch.
Install the test build on a fresh dedicated simulator, then run this script with
seed UDID, run the named test with -parallel-testing-enabled NO, then verify UDID.
"""
import hashlib
import json
import os
import subprocess
import sys
import uuid
import wave
from pathlib import Path

mode, device = sys.argv[1:]
bundle = os.environ.get('CACHE_FIXTURE_BUNDLE', 'com.music.player.gyc')
sim = ['xcrun', 'simctl']
root = Path(subprocess.check_output(sim + ['get_app_container', device, bundle, 'data'], text=True).strip())
support = root / 'Library/Application Support'
index = support / 'CymusicLibrary/library.json'
folder = 'PlaybackCache/' + hashlib.sha256(b'fixture\0cache-a').hexdigest()
relative = folder + '/audio.wav'
audio = support / relative
original = root / 'Documents/Manual Originals/source.wav'
ids = ['cache-a', 'cache-b', 'cache-original']

if mode == 'seed':
    assert not index.exists(), 'Refusing to overwrite an existing library; use a fresh simulator'
    subprocess.run(sim + ['spawn', device, 'defaults', 'write', bundle, 'CyMusic.downloadedAudioReset.v1.6.completed', '-bool', 'YES'], check=True)
    for path in [audio, original]:
        path.parent.mkdir(parents=True, exist_ok=True)
        with wave.open(str(path), 'wb') as out:
            out.setparams((1, 2, 8000, 0, 'NONE', 'not compressed'))
            out.writeframes(b'\0\0' * 8000)
        path.with_suffix('.lrc').write_text('[00:00.00]fixture')
    songs = [dict(id=i, title='Cache Fixture '+t, artist='Fixture', album='Cache Fixture Album', platform='fixture') for i, t in zip(ids, ['A', 'B', 'Original'])]
    index.parent.mkdir(parents=True, exist_ok=True)
    index.write_text(json.dumps(dict(version=1, legacyMMKVImported=True, songs=songs, documentsPaths={ids[2]: 'Manual Originals/source.wav'}, supportPaths=dict.fromkeys(ids[:2], relative), cachedArt=dict.fromkeys(ids[:2], 'Covers/fixture.jpg'), favoriteIDs=ids[:2], playlists=[dict(id=str(uuid.uuid4()), name='Fixture', songIDs=ids[:2])])))
elif mode == 'verify':
    store = json.loads(index.read_text())
    assert set(store['removedCacheIDs']) == set(ids[:2])
    assert store['favoriteIDs'] == ids[:2] and store['playlists'][0]['songIDs'] == ids[:2]
    assert {s['id'] for s in store['songs']} == set(ids)
    for key in ['supportPaths', 'cachedArt', 'media']:
        assert not set(store.get(key, {})).intersection(ids[:2]), key
    assert not audio.exists() and not audio.with_suffix('.lrc').exists()
    assert original.stat().st_size > 16000 and original.with_suffix('.lrc').read_text() == '[00:00.00]fixture'
    print('PASS: shared audio + lyrics removed after last owner; manual source and remote memberships retained after reopen')
else:
    raise ValueError('expected seed or verify')
