#!/usr/bin/env python3
"""Run command/error lookups in a fresh test-host process for each UI language.

First build-for-testing with the Margined scheme and the same derived-data path.
"""
import argparse
import copy
from pathlib import Path
import plistlib
import subprocess
import sys

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('derived_data', type=Path)
args = parser.parse_args()
products = args.derived_data.resolve() / 'Build/Products'
files = list(products.glob('Margined_macosx*.xctestrun'))
if len(files) != 1:
    parser.error('Expected one Margined macOS xctestrun; run build-for-testing first.')
original = plistlib.loads(files[0].read_bytes())
logs = args.derived_data.resolve() / 'localization-qa'
logs.mkdir(exist_ok=True)
for language in ('en', 'es', 'zh-Hans', 'zh-Hant', 'ja', 'fr', 'de'):
    data = copy.deepcopy(original)
    target = data['MarginedTests']
    target['CommandLineArguments'] = ['-AppleLanguages', f'({language})', '-AppleLocale', language]
    target['TestLanguage'] = language
    path = products / f'Margined-locale-{language}.xctestrun'
    path.write_bytes(plistlib.dumps(data))
    log = logs / f'{language}.log'
    try:
        with log.open('w') as output:
            result = subprocess.run(['xcodebuild', 'test-without-building', '-xctestrun', str(path),
                '-destination', 'platform=macOS', '-derivedDataPath', str(args.derived_data.resolve()),
                '-only-testing:MarginedTests/LocalizationTests/testActiveProcessLocalizesCommandsAndErrors'],
                stdout=output, stderr=subprocess.STDOUT)
        if result.returncode:
            print('\n'.join(log.read_text().splitlines()[-35:]), file=sys.stderr)
            sys.exit(f'Failed {language}; see {log}')
        print(f'PASS {language}: localized commands and errors', flush=True)
    finally:
        path.unlink(missing_ok=True)
