#!/usr/bin/env python3
"""Inject one scoped WebKit startup fault on a dedicated, freshly booted iOS simulator.

This local regression probe never targets desktop WebKit or an existing web
process. It runs the real rich-discussion rendering test once and preserves
its log/result. No source or build is uploaded.
"""
import argparse
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time
import uuid


def process_table():
    rows = {}
    output = subprocess.check_output(["ps", "-axo", "pid,ppid,comm"], text=True)
    for line in output.splitlines()[1:]:
        fields = line.strip().split(None, 2)
        if len(fields) == 3:
            rows[int(fields[0])] = (int(fields[1]), fields[2])
    return rows


def simulator_web_processes(rows, manager):
    owned = set()
    for pid, (parent, executable) in rows.items():
        if not executable.endswith("/com.apple.WebKit.WebContent"):
            continue
        if ".simruntime/Contents/Resources/RuntimeRoot/" not in executable:
            continue
        visited = set()
        ancestor = parent
        while ancestor in rows and ancestor not in visited and ancestor != manager:
            visited.add(ancestor)
            ancestor = rows[ancestor][0]
        if ancestor == manager:
            owned.add(pid)
    return owned


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--simulator", required=True, help="Dedicated freshly booted simulator UUID")
    parser.add_argument("--xctestrun", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True, help="New output directory")
    parser.add_argument("--expect", choices=["pass", "failure"], required=True)
    parser.add_argument("--fault", choices=["pause", "terminate"], default="pause")
    parser.add_argument("--delay", type=float, default=8, help="Pause seconds (greater than 6, at most 15)")
    args = parser.parse_args()
    if sys.platform != "darwin" or not args.xctestrun.is_file():
        parser.error("Run on macOS with existing build-for-testing products")
    uuid.UUID(args.simulator)
    if not 6 < args.delay <= 15:
        parser.error("Use a pause greater than the product's six-second cap and at most 15 seconds")
    manager = int(subprocess.check_output(
        ["xcrun", "simctl", "spawn", args.simulator, "launchctl", "managerpid"], text=True).strip())
    rows = process_table()
    if manager <= 1 or manager not in rows or Path(rows[manager][1]).name != "launchd_sim":
        parser.error("Could not verify the dedicated simulator's launchd process")
    baseline = simulator_web_processes(rows, manager)
    args.output.mkdir(parents=True, exist_ok=False)
    report = {"device": args.simulator, "managerPID": manager, "fault": args.fault,
              "delaySeconds": args.delay, "baselineWebPIDs": sorted(baseline), "expected": args.expect}
    command = ["xcodebuild", "test-without-building", "-xctestrun", str(args.xctestrun),
               "-destination", "platform=iOS Simulator,id=" + args.simulator,
               "-parallel-testing-enabled", "NO",
               "-only-testing:MarginediOSTests/DiscussionRenderingTests/testConversationRendersRichBodiesWithTheDocumentsReadOnlyResourcePolicy",
               "-resultBundlePath", str(args.output / "result.xcresult")]
    target = None
    process = None
    try:
        with (args.output / "tests.log").open("x") as log:
            process = subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT)
            deadline = time.monotonic() + 180
            while process.poll() is None and time.monotonic() < deadline:
                new = simulator_web_processes(process_table(), manager) - baseline
                if new:
                    target = min(new)
                    current = process_table()
                    if target not in simulator_web_processes(current, manager):
                        continue
                    report.update(targetPID=target, targetExecutable=current[target][1])
                    os.kill(target, signal.SIGSTOP if args.fault == "pause" else signal.SIGTERM)
                    report["faultInjected"] = True
                    if args.fault == "pause":
                        try:
                            time.sleep(args.delay)
                        finally:
                            if target in simulator_web_processes(process_table(), manager):
                                os.kill(target, signal.SIGCONT)
                                report["resumed"] = True
                            else:
                                report["processExitedBeforeResume"] = True
                    break
                time.sleep(0.1)
            report["exitCode"] = process.wait(timeout=120)
    finally:
        if target and args.fault == "pause" and not report.get("resumed"):
            if target in simulator_web_processes(process_table(), manager):
                os.kill(target, signal.SIGCONT)
                report["resumed"] = True
        if process is not None and process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
        (args.output / "fault.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report), flush=True)
    if not report.get("faultInjected"):
        raise RuntimeError("No scoped startup fault was injected; no reproduction was proved")
    succeeded = report["exitCode"] == 0
    if succeeded != (args.expect == "pass"):
        raise RuntimeError("Unexpected XCTest result; inspect tests.log and result.xcresult")


if __name__ == "__main__":
    main()
