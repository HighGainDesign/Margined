#!/usr/bin/env python3
"""Launch an instrumented optimized Margined app; retain strict raw timing evidence."""
import argparse
import ctypes
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import plistlib
import statistics
import subprocess
import sys


def fixtures():
    prose = "# MARGINED-BENCHMARK-PROSE-000\n\n" + "\n\n".join(
        f"## Section {i}\n\nRead a local Markdown document, follow links and review changes. "
        "The reading position stays where the reader left it. **Bold** and *italic* text remain readable."
        for i in range(30)) + "\n"
    tables = "# MARGINED-BENCHMARK-TABLES-000\n\n| Task | Owner | Status | Notes |\n| --- | --- | --- | --- |\n" + "".join(
        f"| Task {i} | Reader | Ready | Verify a rendered table with ordinary wrapping content. |\n"
        for i in range(240))
    math = "# MARGINED-BENCHMARK-MATH-000\n\n" + "\n\n".join(
        f"Equation {i}: $x_{{{i}}}^2 + y^2 = z^2$.\n\n$$\\sum_{{k=1}}^{{{i+2}}} k = \\frac{{n(n+1)}}{{2}}$$"
        for i in range(12)) + "\n"
    mermaid = "# MARGINED-BENCHMARK-MERMAID-000\n\n" + "\n\n".join(
        f"## Flow {i}\n\n```mermaid\nflowchart LR\nA[Read {i}]-->B[Review {i}]-->C[Reply {i}]\n```"
        for i in range(3)) + "\n"
    return {"prose": prose, "tables": tables, "math": math, "mermaid": mermaid}


def summarize(rows, expected_count, kind):
    if type(expected_count) is not int or not 1 <= expected_count <= 100 or kind not in ("cold", "warm", "refresh"):
        raise ValueError("invalid cohort request")
    if (len(rows) != expected_count or any(type(r.get("index")) is not int for r in rows)
            or [r.get("index") for r in rows] != list(range(expected_count))):
        raise ValueError("incomplete or duplicate sample cohort")
    render, frame, pids = [], [], []
    for row in rows:
        values = [row.get(k) for k in ("pid", "request_ns", "render_ready_ns", "frame_ns")]
        if any(type(value) is not int or value <= 0 for value in values):
            raise ValueError("invalid sample timestamps or process identity")
        pid, start, ready, end = values
        if not start <= ready <= end:
            raise ValueError("nonmonotonic sample stages")
        pids.append(pid)
        render.append((ready-start)/1_000_000)
        frame.append((end-start)/1_000_000)
    if len(set(pids)) != (expected_count if kind == "cold" else 1):
        raise ValueError("cold/warm process reuse contract violated")
    def stats(values):
        return {"median": statistics.median(values), "p95": sorted(values)[math.ceil(len(values)*.95)-1]}
    return {"samples": len(rows), "render_ms": stats(render), "frame_ms": stats(frame)}


def read_result(payload, kind, count):
    if (payload.get("schema") != 1 or payload.get("status") != "ok" or payload.get("kind") != kind
            or payload.get("configuration") != "Release" or payload.get("boundary") != "verified-frame-v1"):
        raise ValueError("child did not produce a valid optimized verified-frame result: " + str(payload.get("error", "invalid metadata")))
    rows = payload.get("samples", [])
    summarize(rows, count, "warm" if kind == "cold" else kind)
    return rows


def monotonic_ns():
    # DispatchTime.uptimeNanoseconds in the app uses the same host mach clock.
    class Timebase(ctypes.Structure):
        _fields_ = [("numer", ctypes.c_uint32), ("denom", ctypes.c_uint32)]
    library = ctypes.CDLL("/usr/lib/libSystem.B.dylib")
    library.mach_absolute_time.restype = ctypes.c_uint64
    library.mach_timebase_info.argtypes = [ctypes.POINTER(Timebase)]
    timebase = Timebase()
    if library.mach_timebase_info(ctypes.byref(timebase)) != 0 or not timebase.denom:
        raise RuntimeError("host monotonic clock unavailable")
    return library.mach_absolute_time() * timebase.numer // timebase.denom


def run_session(executable, directory, text, kind, count):
    directory.mkdir()
    source = directory / "fixture.md"
    source.write_text(text, encoding="utf-8")
    request = {"version": 1, "kind": kind, "sourceFile": source.name,
               "expectedMarker": text.splitlines()[0][2:], "sampleCount": count}
    manifest = directory / "request.json"
    manifest.write_text(json.dumps(request), encoding="utf-8")
    environment = dict(os.environ, MARGINED_BENCHMARK_REQUEST=str(manifest))
    with (directory / "process.log").open("wb") as log:
        environment["MARGINED_BENCHMARK_START_NS"] = str(monotonic_ns())
        process = subprocess.Popen([str(executable)], env=environment, stdout=log, stderr=log)
        try:
            exit_code = process.wait(timeout=30*count+30)
        except subprocess.TimeoutExpired:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill(); process.wait()
            raise RuntimeError("benchmark timed out; check visibility/unlocked screen and MARGINED_BENCHMARK build")
    result = directory / "result.json"
    if not result.is_file():
        raise RuntimeError(f"benchmark process exited {exit_code} without result; see {directory / 'process.log'}")
    payload = json.loads(result.read_text(encoding="utf-8"))
    if exit_code != 0:
        raise RuntimeError("benchmark failed: " + str(payload.get("error", exit_code)))
    read_result(payload, kind, count)
    return payload


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True, help="New report directory; never overwrites an existing run")
    parser.add_argument("--samples", type=int, default=20, choices=range(1, 101), metavar="1..100")
    parser.add_argument("--cases", nargs="+", default=["cold", "warm", "refresh"], choices=["cold", "warm", "refresh"])
    parser.add_argument("--fixtures", nargs="+", default=list(fixtures()), choices=list(fixtures()))
    args = parser.parse_args()
    if sys.platform != "darwin":
        parser.error("this launcher measures the native Mac app")
    app = args.app.resolve()
    try:
        info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
        executable = app / "Contents/MacOS" / info["CFBundleExecutable"]
        if not executable.is_file():
            raise ValueError("app executable missing")
    except (OSError, KeyError, ValueError) as error:
        parser.error(str(error))
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    report = {"schema": 1, "status": "incomplete", "boundary": "verified-frame-v1",
              "boundary_description": "Request to correct DOM, two animation frames and verified WebKit snapshot in an unoccluded window; includes verification overhead. Not scan-out timing.",
              "hardware": {"machine": platform.machine(), "model": subprocess.check_output(["sysctl", "-n", "hw.model"], text=True).strip(), "os": platform.mac_ver()[0]},
              "app": {key: info.get(key) for key in ("CFBundleIdentifier", "CFBundleShortVersionString", "CFBundleVersion")},
              "cohorts": []}
    try:
        for name in dict.fromkeys(args.fixtures):
            text = fixtures()[name]
            for kind in dict.fromkeys(args.cases):
                rows, children = [], []
                for session in range(args.samples if kind == "cold" else 1):
                    child = run_session(executable, output / f"{name}-{kind}-{session:03}", text, kind,
                                        1 if kind == "cold" else args.samples)
                    children.append(child)
                    for row in child["samples"]:
                        rows.append(dict(row, index=len(rows)))
                cohort = {"fixture": name, "kind": kind, "bytes": len(text.encode()),
                          "sha256": hashlib.sha256(text.encode()).hexdigest(), "samples": rows,
                          "summary": summarize(rows, args.samples, kind), "sessions": children}
                report["cohorts"].append(cohort)
                print(name, kind, json.dumps(cohort["summary"]), flush=True)
        report["status"] = "ok"
    except (OSError, RuntimeError, ValueError, subprocess.SubprocessError) as error:
        report["error"] = str(error)
        print(str(error), file=sys.stderr)
    finally:
        (output / "report.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    return 0 if report["status"] == "ok" else 1


if __name__ == "__main__":
    sys.exit(main())
