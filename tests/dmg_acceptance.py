"""Check the final, read-only DMG after a fresh mount, not its staging folder."""
import plistlib
import subprocess
import sys
from pathlib import Path

project = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(project / 'build/packaging-python'))
from ds_store import DSStore
from mac_alias import Alias

image = Path(sys.argv[1]).resolve()
subprocess.run(['hdiutil', 'verify', '-quiet', str(image)], check=True)
mounted = plistlib.loads(subprocess.check_output(
    ['hdiutil', 'attach', '-readonly', '-nobrowse', '-plist', str(image)]))
root = Path(next(item['mount-point'] for item in mounted['system-entities'] if 'mount-point' in item))
try:
    visible = {item.name for item in root.iterdir() if not item.name.startswith('.')}
    assert visible == {'NoSleep.app', 'Программы'}, visible
    assert (root / 'Программы').is_symlink()
    assert (root / 'Программы').readlink() == Path('/Applications')
    print('PASS: only the app and the Applications link are visible; no instruction file', flush=True)
    with DSStore.open(str(root / '.DS_Store'), 'r') as store:
        assert store['NoSleep.app']['Iloc'] == (155, 170)
        assert store['Программы']['Iloc'] == (485, 170)
        options = store['.']['icvp']
        assert options['backgroundType'] == 2 and options['arrangeBy'] == 'none'
        alias = Alias.from_bytes(options['backgroundImageAlias'])
        assert alias.volume.disk_image_alias is None
        assert alias.target.posix_path == '/.background/background.png'
    print('PASS: icon positions and a portable background link are saved in the image', flush=True)
    subprocess.run(['swift', '-module-cache-path', str(project / 'build/module-cache'),
                    str(project / 'tests/dmg_background_acceptance.swift'),
                    str(root / '.background/background.png')], check=True)
    # The Finder background-picture AppleEvent getter returns missing value on this
    # read-only image in macOS 27. Check stored data, pixels and the real window instead.
    script = '''
    on run argv
        tell application "Finder"
            set targetDisk to disk (item 1 of argv)
            open targetDisk
            delay 1
            set w to container window of targetDisk
            if current view of w is not icon view then error "Wrong view"
            if toolbar visible of w then error "Toolbar should be hidden"
            if sidebar width of w is not 0 then error "Sidebar should be hidden"
            if position of item "NoSleep.app" of targetDisk is not {155, 170} then error "App moved"
            if position of item "Программы" of targetDisk is not {485, 170} then error "Destination moved"
            if icon size of icon view options of w is not 100 then error "Wrong icon size"
            close w
            return "PASS: Finder opens the saved two-icon layout"
        end tell
    end run
    '''
    subprocess.run(['osascript', '-e', script, root.name], check=True)
    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(root / 'NoSleep.app')], check=True)
    print('PASS: app signature remains valid', flush=True)
finally:
    subprocess.run(['hdiutil', 'detach', str(root)], check=True)
