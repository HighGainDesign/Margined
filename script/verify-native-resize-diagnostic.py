#!/usr/bin/env python3
"""Require native outcome and capture evidence for each emulated-feedback case."""
import argparse
import json
import math
import re
from pathlib import Path

TARGET = "testResizePreservesPassageAfterEmulatedStaleDOMFeedback"
MARKER = "NATIVE-RESIZE-OWNER "


def verify(log: str) -> dict:
    cases = []
    current = None
    for line in log.splitlines():
        if TARGET in line and "Test Case " in line and " started." in line:
            current = {"passed": False, "captures": 0, "processID": None}
            cases.append(current)
        process = re.search(r"EMULATED-NATIVE-FEEDBACK-PROCESS (\d+)", line)
        if current is not None and process:
            if current["processID"] not in (None, int(process[1])):
                raise ValueError("Ambiguous process identity within one replay case")
            current["processID"] = int(process[1])
        if current is not None and MARKER in line:
            report = json.loads(line.split(MARKER, 1)[1])
            capture = report.get("capture", {})
            native_y, dom_y = capture.get("nativeY"), capture.get("domY")
            finite = all(isinstance(v, (float, int)) and not isinstance(v, bool) and math.isfinite(v)
                         for v in (native_y, dom_y, capture.get("virtualTop")))
            if (report.get("nativeSetterAccepted") is True and capture.get("markedReadingPassage") is True
                    and finite and abs(native_y - dom_y) > 100
                    and current["processID"] is not None and report.get("processID") == current["processID"]):
                current["captures"] += 1
        if TARGET in line and "Test Case " in line and (" passed (" in line or " failed (" in line):
            if current is not None:
                current["passed"] = " passed (" in line
            current = None
    if not cases:
        raise ValueError("No emulated-feedback behavior case executed")
    if len(cases) != 2:
        raise ValueError(f"Expected 2 emulated-feedback behavior cases, observed {len(cases)}")
    for index, case in enumerate(cases, 1):
        if not case["passed"]:
            raise ValueError(f"Emulated-feedback behavior case {index} did not pass")
        if not case["captures"]:
            raise ValueError(f"Case {index} lacks an accepted native P35 capture during DOM/native divergence")
    if len({c["processID"] for c in cases}) != 2:
        raise ValueError("Replay cases did not run in distinct processes")
    return {"replayCases": len(cases), "acceptedDivergentCaptures": [c["captures"] for c in cases],
            "processIDs": [c["processID"] for c in cases]}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("log", type=Path)
    args = parser.parse_args()
    print(json.dumps(verify(args.log.read_text()), sort_keys=True))
