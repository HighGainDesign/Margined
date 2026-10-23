#!/usr/bin/env python3
"""Sync the shared catalog from a completed Xcode build's compiler output."""
import argparse
import json
from pathlib import Path
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("derived_data", type=Path)
parser.add_argument("--configuration", default="Debug")
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent
intermediates = args.derived_data / "Build/Intermediates.noindex/Margined.build" / args.configuration
files = []
for target in ("Margined", "MarginedQuickLook"):
    for path in (intermediates / (target + ".build") / "Objects-normal").glob("*/*.stringsdata"):
        data = json.loads(path.read_bytes())
        source = Path(data.get("source", ""))
        # Ignore generated metadata and files removed since an earlier build.
        if source.is_file() and source.resolve().is_relative_to(root):
            files.append(path)
if not files:
    parser.error("No compiler stringsdata found. Build Margined with SWIFT_EMIT_LOC_STRINGS=YES first.")
catalog = root / "Shared/Resources/Localizable.xcstrings"
subprocess.run(["xcrun", "xcstringstool", "sync", str(catalog), "--stringsdata", *map(str, sorted(files))], check=True)
print(f"Synced {len(json.loads(catalog.read_bytes())['strings'])} catalog keys from {len(files)} compiler outputs.")
