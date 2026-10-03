"""Write Finder installation metadata to an already mounted HFS+ image."""
from pathlib import Path
import sys
from ds_store import DSStore
from mac_alias import Alias
volume = Path(sys.argv[1])
background = volume / '.background' / 'Installer.tiff'
with DSStore.open(str(volume / '.DS_Store'), 'w+') as store:
    store['.']['bwsp'] = {
        'ShowStatusBar': False, 'ShowTabView': False, 'ShowToolbar': False,
        'ShowPathbar': False, 'ShowSidebar': False, 'ContainerShowSidebar': False,
        'SidebarWidth': 0, 'WindowBounds': '{{180, 120}, {760, 500}}',
        'PreviewPaneVisibility': False,
    }
    store['.']['icvp'] = {
        'viewOptionsVersion': 1, 'backgroundType': 2,
        'backgroundImageAlias': Alias.for_file(str(background)).to_bytes(),
        'iconSize': 104.0, 'textSize': 13.0, 'gridSpacing': 100.0,
        'gridOffsetX': 0.0, 'gridOffsetY': 0.0, 'arrangeBy': 'none',
        'showIconPreview': True, 'showItemInfo': False, 'labelOnBottom': True,
        'backgroundColorRed': 0.045, 'backgroundColorGreen': 0.045,
        'backgroundColorBlue': 0.045,
    }
    store['.']['vSrn'] = ('long', 1)
    store['.']['vstl'] = ('type', b'icnv')
    store['Clasp Studio.app']['Iloc'] = (210, 264)
    store['Applications']['Iloc'] = (550, 264)
print('Configured installer background, icon positions and Finder window.')
