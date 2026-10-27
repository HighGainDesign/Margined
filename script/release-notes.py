#!/usr/bin/env python3
"""Print the brief CHANGELOG entry for an exact release version."""
from pathlib import Path
import re
import sys

if len(sys.argv) != 2 or not re.fullmatch(r'\d+\.\d+(?:\.\d+)?(?:-(?:alpha|beta|rc)\.[1-9]\d*)?', sys.argv[1]):
    sys.exit('Usage: release-notes.py X.Y[.Z][-beta.N]')
version = sys.argv[1]
changelog = (Path(__file__).resolve().parent.parent / 'CHANGELOG.md').read_text()
heading = re.search(r'^## ' + re.escape(version) + r'(?:[ \t]+[^\n]*)?$', changelog, re.M)
if heading is None:
    sys.exit(f'No changelog entry for {version}')
body = changelog[heading.end():].split('\n## ', 1)[0].strip()
if not body:
    sys.exit(f'Empty changelog entry for {version}')
print(body)
