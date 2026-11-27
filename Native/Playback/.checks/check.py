"""Run with python3 Native/Playback/.checks/check.py [--live] on macOS."""
from pathlib import Path
import subprocess
import sys
import tempfile

native = Path(__file__).resolve().parents[2]
with tempfile.TemporaryDirectory() as temp:
    work = Path(temp)
    # Pull the actual parser out of its SwiftUI host for the host-side executable.
    library = (native / 'Library/LibraryScreen.swift').read_text()
    parser = library.split('enum ShelfLyrics {', 1)[1].split('\n}', 1)[0]
    (work / 'Shelf.swift').write_text('import Foundation\nprotocol ChineseUIError: LocalizedError {}\nenum ShelfLyrics {' + parser + '\n}')
    (work / 'Checks.swift').write_text((Path(__file__).with_name('Checks.swiftfixture')).read_text())
    binary = work / 'checks'
    subprocess.run(['swiftc', native / 'App/Song.swift', native / 'Playback/PlaybackMedia.swift',
                    native / 'Playback/LyricVersions.swift', work / 'Shelf.swift', work / 'Checks.swift', '-o', binary], check=True)
    for mode in ['save', 'reload'] + (['live'] if '--live' in sys.argv else []):
        subprocess.run([binary, mode, work / 'choice.json'], check=True)
