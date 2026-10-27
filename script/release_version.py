#!/usr/bin/env python3
"""Validate a release tag and classify stable versus prerelease publishing."""
import re
import sys


def metadata(tag, marketing_version):
    match = re.fullmatch(r"v(?P<version>\d+\.\d+(?:\.\d+)?)(?P<suffix>-(?:alpha|beta|rc)\.[1-9]\d*)?", tag)
    if match is None:
        raise ValueError("Use vX.Y[.Z] or vX.Y[.Z]-beta.N release tags.")
    version = match["version"]
    if version != marketing_version:
        raise ValueError("Tag must match MARKETING_VERSION in project.yml.")
    return {"version": version, "notes_version": tag[1:],
            "prerelease": "true" if match["suffix"] or version.startswith("0.") else "false"}


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit("Usage: release_version.py TAG MARKETING_VERSION")
    try:
        values = metadata(sys.argv[1], sys.argv[2])
    except ValueError as error:
        sys.exit(str(error))
    for key, value in values.items():
        print(f"{key}={value}")
