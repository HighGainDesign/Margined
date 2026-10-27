#!/usr/bin/env python3
"""Measure an installed private benchmark app on an explicitly owned iOS Simulator.

The caller owns simulator creation, build provenance and device retirement. This
command never boots, erases, deletes or installs on an existing device.
"""
import argparse
import ctypes
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import signal
import subprocess
import time
import uuid

_spec = importlib.util.spec_from_file_location("benchmark_viewing", Path(__file__).with_name("benchmark-viewing.py"))
canonical = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(canonical)


def validate_target(device, identifier):
    device = str(uuid.UUID(device)).upper()
    if not re.fullmatch(r"design\.highgain\.margined\.benchmark\.[A-Za-z0-9][A-Za-z0-9.-]*", identifier):
        raise ValueError("use a private design.highgain.margined.benchmark.* app, never the production app")
    return device


def discussion_counts(fixture):
    return {"annotated": (20, 80, 20), "long-discussion": (1, 120, 1)}.get(fixture, (0, 0, 0))


def accept_result(payload, kind, count, pid, expected, start_ns, observed_ns):
    rows = canonical.read_result(payload, kind, count)
    if (payload.get("platform") != "iOS Simulator" or payload.get("presentation") != "collapsed"
            or payload.get("expected_discussions") != dict(zip(("thread_count", "message_count", "attached_count"), expected))):
        raise ValueError("wrong native platform, presentation or fixture census")
    if any(row["pid"] != pid or not start_ns <= row["request_ns"] <= row["frame_ns"] <= observed_ns for row in rows):
        raise ValueError("result has a different process or falls outside the host clock interval")
    if kind == "cold" and (count != 1 or rows[0]["request_ns"] != start_ns):
        raise ValueError("cold timing must start at the actual external launch request")
    return rows


def run(command, timeout=30, env=None):
    completed = subprocess.run(command, stdin=subprocess.DEVNULL, capture_output=True,
                               text=True, timeout=timeout, env=env)
    if completed.returncode:
        raise RuntimeError(f"{command!r}: {completed.returncode}\n{completed.stdout[-1500:]}\n{completed.stderr[-1500:]}")
    return completed.stdout


def executable_path(pid):
    library = ctypes.CDLL("/usr/lib/libproc.dylib")
    library.proc_pidpath.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]
    library.proc_pidpath.restype = ctypes.c_int
    buffer = ctypes.create_string_buffer(4096)
    if library.proc_pidpath(pid, buffer, len(buffer)) <= 0:
        return None
    return os.fsdecode(buffer.value)


def identity(pid):
    executable = executable_path(pid)
    if executable is None:
        return None
    process = subprocess.run(["/bin/ps", "-ww", "-p", str(pid), "-o", "lstart="],
                             capture_output=True, text=True, timeout=5)
    stamp = process.stdout.strip()
    if process.returncode or not stamp or executable_path(pid) != executable:
        return None
    return {"pid": pid, "started": stamp, "executable": executable}


def matching_processes(executable):
    pids = run(["/bin/ps", "-axo", "pid="]).split()
    return [int(pid) for pid in pids if executable_path(int(pid)) == str(executable)]


def stop_owned(device, identifier, owned):
    pid = owned["pid"]
    if identity(pid) != owned:
        return
    try:
        run(["xcrun", "simctl", "terminate", device, identifier], timeout=20)
    except (RuntimeError, subprocess.TimeoutExpired):
        if identity(pid) == owned:
            os.kill(pid, signal.SIGTERM)
    deadline = time.monotonic() + 8
    while identity(pid) == owned and time.monotonic() < deadline:
        time.sleep(.05)
    if identity(pid) == owned:
        os.kill(pid, signal.SIGKILL)
        deadline = time.monotonic() + 5
        while identity(pid) == owned and time.monotonic() < deadline:
            time.sleep(.05)
    if identity(pid) == owned:
        raise RuntimeError("owned benchmark process did not terminate")


def launch_private(device, identifier, executable, directory, attempt):
    # An empty initial census plus an exclusive caller-owned simulator allows
    # reconciliation if simctl starts the app but loses its response.
    if matching_processes(executable):
        raise ValueError("private app is already running; finish that session first")
    command = ["xcrun", "simctl", "launch", "--stdout=" + str(directory / "process.stdout"),
               "--stderr=" + str(directory / "process.stderr"), device, identifier]
    environment = dict(os.environ, SIMCTL_CHILD_MARGINED_BENCHMARK_REQUEST=str(directory / "request.json"),
                       SIMCTL_CHILD_MARGINED_TEST_PREFERENCES="1")
    start = canonical.monotonic_ns()
    attempt.update(hostLaunchStartNS=start, status="launching", command=command)
    environment["SIMCTL_CHILD_MARGINED_BENCHMARK_START_NS"] = str(start)
    try:
        response = run(command, env=environment)
        attempt.update(launchResponse=response, hostLaunchReturnNS=canonical.monotonic_ns())
        match = re.fullmatch(re.escape(identifier) + r": (\d+)\s*", response)
        if not match:
            raise ValueError("unexpected simctl launch response: " + response)
        pid = int(match[1])
        attempt["pid"] = pid
        candidate = identity(pid)
        if candidate is None or candidate["executable"] != str(executable):
            raise ValueError("launch PID does not identify the installed private executable")
        attempt.update(identity=candidate, status="launched")
        return candidate
    except BaseException as error:
        if "hostLaunchReturnNS" not in attempt:
            attempt["hostLaunchReturnNS"] = canonical.monotonic_ns()
        attempt["launchError"] = type(error).__name__ + ": " + str(error)
        attempt["status"] = "error"
        candidates = [identity(pid) for pid in matching_processes(executable)]
        candidates = [candidate for candidate in candidates
                      if candidate is not None and candidate["executable"] == str(executable)]
        attempt["reconciledIdentities"] = candidates
        for candidate in candidates:
            stop_owned(device, identifier, candidate)
        attempt["ownedProcessJoined"] = True
        raise


def file_map(root):
    files, links = {}, {}
    for path in sorted(root.rglob("*")):
        name = path.relative_to(root).as_posix()
        if path.is_symlink():
            links[name] = os.readlink(path)
        elif path.is_file():
            files[name] = hashlib.sha256(path.read_bytes()).hexdigest()
    return {"files": files, "symlinks": links}


def source_pin(root):
    names = subprocess.check_output(["git", "-C", str(root), "ls-files", "-z", "--cached", "--others", "--exclude-standard"])
    files = {}
    for raw in names.split(b"\0"):
        if raw:
            name = os.fsdecode(raw)
            files[name] = hashlib.sha256((root / name).read_bytes()).hexdigest()
    return {"base": run(["git", "-C", str(root), "rev-parse", "HEAD"]).strip(), "files": files}


def collect(args):
    device = validate_target(args.device, args.identifier)
    if not 1 <= args.samples <= 100:
        raise ValueError("samples must be between 1 and 100")
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    source_root = Path(__file__).resolve().parents[1]
    pin = source_pin(source_root)
    bundle = Path(run(["xcrun", "simctl", "get_app_container", device, args.identifier, "app"]).strip()).resolve()
    data = Path(run(["xcrun", "simctl", "get_app_container", device, args.identifier, "data"]).strip()).resolve()
    info = plistlib.loads((bundle / "Info.plist").read_bytes())
    name = info.get("CFBundleExecutable", "")
    if (info.get("CFBundleIdentifier") != args.identifier or not name or name != Path(name).name
            or device not in str(bundle) or device not in str(data)):
        raise ValueError("installed private app/container does not match the explicit device")
    executable = (bundle / name).resolve()
    if not executable.is_file() or not executable.is_relative_to(bundle):
        raise ValueError("invalid app executable")
    if matching_processes(executable):
        raise ValueError("private app is already running; finish that session first")
    bundle_pin = file_map(bundle)
    root = data / "Library/Caches" / ("MarginedBenchmark-" + str(uuid.uuid4()))
    root.mkdir()
    text = canonical.fixtures()[args.fixture]
    assets = canonical.fixture_assets(args.fixture)
    expected = discussion_counts(args.fixture)
    report = {"schema": 1, "status": "incomplete", "platform": "iOS Simulator",
              "device": device, "identifier": args.identifier, "fixture": args.fixture, "kind": args.kind,
              "workingSource": pin, "appBundle": bundle_pin, "ownedSessionRoot": str(root),
              "bytes": len(text.encode()), "fixtureSHA256": hashlib.sha256(text.encode()).hexdigest(),
              "assetSHA256": {name: hashlib.sha256(value).hexdigest() for name, value in assets.items()},
              "boundary": "verified-frame-v1", "hostLoadBefore": list(os.getloadavg()),
              "boundaryDescription": "Host Mach clock before simctl launch through active UIKit window, current DOM/fonts/artwork, two animation frames and WK snapshot. Includes verification and dispatch overhead; not scan-out or physical-device speed.",
              "sessions": [], "samples": []}
    owned = None
    try:
        for number in range(args.samples if args.kind == "cold" else 1):
            directory = root / f"session-{number:03}"
            directory.mkdir()
            canonical.write_fixture(directory, text, assets)
            request = {"version": 1, "kind": args.kind, "sourceFile": "fixture.md",
                       "expectedMarker": text.splitlines()[0][2:],
                       "sampleCount": 1 if args.kind == "cold" else args.samples,
                       "expectedMath": 24 if args.fixture == "math" else 0,
                       "expectedDiagrams": 3 if args.fixture == "mermaid" else 0,
                       "presentation": "collapsed", "expectedThreads": expected[0],
                       "expectedMessages": expected[1], "expectedAttached": expected[2]}
            manifest = directory / "request.json"
            manifest.write_text(json.dumps(request) + "\n")
            attempt = {"number": number, "request": request}
            report["sessions"].append(attempt)
            owned = launch_private(device, args.identifier, executable, directory, attempt)
            pid = owned["pid"]
            start = attempt["hostLaunchStartNS"]
            deadline = time.monotonic() + 30 * request["sampleCount"] + 30
            result = directory / "result.json"
            while time.monotonic() < deadline:
                if identity(pid) != owned:
                    raise RuntimeError("benchmark app exited before a complete result")
                if result.exists():
                    try:
                        payload = json.loads(result.read_text())
                        break
                    except json.JSONDecodeError:
                        pass
                time.sleep(.01)
            else:
                raise TimeoutError("native session exceeded its original deadline")
            observed = canonical.monotonic_ns()
            attempt.update(hostResultObservedNS=observed, payload=payload)
            rows = accept_result(payload, args.kind, request["sampleCount"], pid, expected, start, observed)
            if not all((directory / f"frame-{row['index']}.png").is_file() for row in rows):
                raise ValueError("native frame evidence is missing")
            if number in (0, args.samples - 1):
                run(["xcrun", "simctl", "io", device, "screenshot", str(directory / "actual-simulator-screen.png")])
            stop_owned(device, args.identifier, owned)
            owned = None
            attempt.update(ownedProcessJoined=True, status="complete")
            base = len(report["samples"])
            report["samples"].extend(dict(row, index=base + i) for i, row in enumerate(rows))
        if source_pin(source_root) != pin or file_map(bundle) != bundle_pin:
            raise ValueError("source or installed app changed during measurement")
        report["summary"] = canonical.summarize(report["samples"], args.samples, args.kind)
        report["status"] = "ok"
    except BaseException as error:
        report["error"] = type(error).__name__ + ": " + str(error)
        if report["sessions"] and report["sessions"][-1].get("status") != "complete":
            report["sessions"][-1]["error"] = report["error"]
        raise
    finally:
        try:
            if owned is not None:
                stop_owned(device, args.identifier, owned)
                report["sessions"][-1]["ownedProcessJoined"] = True
        finally:
            for directory in root.iterdir():
                if directory.is_dir():
                    shutil.copytree(directory, output / directory.name)
            report["hostLoadAfter"] = list(os.getloadavg())
            report["retainedFiles"] = file_map(output)
            (output / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps({"status": report["status"], "samples": len(report["samples"]), "summary": report.get("summary")}))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--device", required=True, help="Explicit disposable Simulator UUID; never 'booted'")
    parser.add_argument("--identifier", required=True, help="Installed private design.highgain.margined.benchmark.* bundle ID")
    parser.add_argument("--output", type=Path, required=True, help="New directory; existing reports are never overwritten")
    parser.add_argument("--fixture", choices=list(canonical.fixtures()), required=True)
    parser.add_argument("--kind", choices=["cold", "warm", "refresh"], required=True)
    parser.add_argument("--samples", type=int, default=20, choices=range(1, 101), metavar="1..100")
    args = parser.parse_args()
    validate_target(args.device, args.identifier)
    collect(args)


if __name__ == "__main__":
    main()
