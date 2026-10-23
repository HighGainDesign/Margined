#!/usr/bin/env python3
"""Write Finder installation layout without UI automation or AppleScript."""
from pathlib import Path
import sys
from ds_store import DSStore

folder = Path(sys.argv[1])
with DSStore.open(str(folder / '.DS_Store'), 'w+') as store:
    store['Margined.app']['Iloc'] = (160, 170)
    store['Applications']['Iloc'] = (420, 170)
    store['.']['bwsp'] = {
        'ShowStatusBar': False, 'ShowToolbar': False, 'ShowTabView': False,
        'ShowPathbar': False, 'ShowSidebar': False,
        'WindowBounds': '{{160, 160}, {580, 360}}', 'SidebarWidth': 0,
    }
    store['.']['icvp'] = {
        'viewOptionsVersion': 1, 'backgroundType': 1,
        'backgroundColorRed': 0.95, 'backgroundColorGreen': 0.97, 'backgroundColorBlue': 1.0,
        'iconSize': 96.0, 'textSize': 14.0, 'arrangeBy': 'none',
        'gridSpacing': 100.0, 'gridOffsetX': 0.0, 'gridOffsetY': 0.0,
        'labelOnBottom': True, 'showIconPreview': True, 'showItemInfo': False,
    }
    store['.']['vstl'] = ('type', 'icnv')
    store['.']['vSrn'] = ('long', 1)
