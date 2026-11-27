"""Seed a disposable simulator after installing CyMusic. Usage: python3 playlist-sheet.py UDID"""
from pathlib import Path
import subprocess
import sys
import tempfile

container = subprocess.check_output(['xcrun', 'simctl', 'get_app_container', sys.argv[1], 'com.music.player.gyc', 'data'], text=True).strip()
folder = Path(container) / 'Documents/importedLocalMusic/Playlist QA'
folder.mkdir(parents=True, exist_ok=True)
with tempfile.TemporaryDirectory() as tmp:
    for n, color in enumerate(['red', 'red', 'lime', 'blue', 'yellow'], 1):
        image = Path(tmp) / f'{color}.jpg'
        subprocess.run(['ffmpeg', '-loglevel', 'error', '-y', '-f', 'lavfi', '-i', f'color={color}:s=64x64', '-frames:v', '1', str(image)], check=True)
        title = f'QA Track {n}'
        artist = 'QA Ensemble' if n < 5 else 'QA Solo'
        subprocess.run(['ffmpeg', '-loglevel', 'error', '-y', '-f', 'lavfi', '-i', 'sine=duration=1', '-i', str(image), '-map', '0:a', '-map', '1:v', '-c:v', 'copy', '-b:a', '128k', '-disposition:v', 'attached_pic', '-metadata', f'title={title}', '-metadata', f'artist={artist}', '-metadata', 'album=QA Collection', str(folder / f'{title}.mp3')], check=True)
