#!/usr/bin/env python3
"""Require native outcome and capture evidence for each emulated-feedback case."""
import argparse
import json
import math
from pathlib import Path

TARGET = "testResizePreservesPassageAfterEmulatedStaleDOMFeedback"
MARKER = "NATIVE-RESIZE-OWNER "


def verify(log: str) -> dict:
    cases = []
    current = None
    for line in log.splitlines():
        if TARGET in line and "Test Case " in line and " started." in line:
            current = {"passed": False, "captures": 0}
            cases.append(current)
        if current is not None and MARKER in line:
            report = json.loads(line.split(MARKER, 1)[1])
            capture = report.get("capture", {})
            native_y, dom_y = capture.get("nativeY"), capture.get("domY")
            finite = all(isinstance(v, (float, int)) and not isinstance(v, bool) and math.isfinite(v)
                         for v in (native_y, dom_y, capture.get("virtualTop")))
            if (report.get("nativeSetterAccepted") is True and capture.get("markedReadingPassage") is True
                    and finite and abs(native_y - dom_y) > 100):
                current["captures"] += 1
        if TARGET in line and "Test Case " in line and (" passed (" in line or " failed (" in line):
            if current is not None:
                current["passed"] = " passed (" in line
            current = None
    if not cases:
        raise ValueError("No emulated-feedback behavior case executed")
    for index, case in enumerate(cases, 1):
        if not case["passed"]:
            raise ValueError(f"Emulated-feedback behavior case {index} did not pass")
        if not case["captures"]:
            raise ValueError(f"Case {index} lacks an accepted native P35 capture during DOM/native divergence")
    return {"replayCases": len(cases), "acceptedDivergentCaptures": [c["captures"] for c in cases]}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("log", type=Path)
    args = parser.parse_args()
    print(json.dumps(verify(args.log.read_text()), sort_keys=True))
