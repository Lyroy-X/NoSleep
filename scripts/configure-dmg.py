"""Write portable Finder settings without bookmarks to the build machine's DMG."""
import sys
from pathlib import Path
from ds_store import DSStore
from mac_alias import Alias

root = Path(sys.argv[1])
background = Alias.for_file(str(root / '.background/background.png'))
assert background.volume.disk_image_alias is None
window = {
    'ShowStatusBar': False, 'ShowToolbar': False, 'ShowTabView': False,
    'ShowPathbar': False, 'ShowSidebar': False, 'ContainerShowSidebar': False,
    'WindowBounds': '{{200, 180}, {640, 382}}',
}
icons = {
    'viewOptionsVersion': 1, 'backgroundType': 2,
    'backgroundImageAlias': background.to_bytes(),
    'backgroundColorRed': 1.0, 'backgroundColorGreen': 1.0, 'backgroundColorBlue': 1.0,
    'iconSize': 100.0, 'textSize': 14.0, 'labelOnBottom': True,
    'arrangeBy': 'none', 'gridOffsetX': 0.0, 'gridOffsetY': 0.0,
    'gridSpacing': 100.0, 'showItemInfo': False, 'showIconPreview': True,
}
with DSStore.open(str(root / '.DS_Store'), 'w+') as store:
    store['.']['vSrn'] = ('long', 1)
    store['.']['icvl'] = ('type', b'icnv')
    store['.']['bwsp'] = window
    store['.']['icvp'] = icons
    store['NoSleep.app']['Iloc'] = (155, 170)
    store['Программы']['Iloc'] = (485, 170)
