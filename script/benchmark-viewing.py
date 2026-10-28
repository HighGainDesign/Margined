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
    short = "# MARGINED-BENCHMARK-SHORT-000\n\nA short document should open quickly. Read this paragraph, follow a [local link](#next), and check **formatted text**.\n\n## Next\n\nA second paragraph completes the example.\n"
    long = "# MARGINED-BENCHMARK-LONG-000\n\n" + "\n\n".join(
        f"## Long section {i}\n\nParagraph {i} follows a detailed local document. "
        "Keep the reading position stable while navigating headings, searching text and reviewing an agent's saved changes. "
        "**Formatted words** and ordinary [links](#long-section-0) remain readable."
        for i in range(500)) + "\n"
    images = "# MARGINED-BENCHMARK-IMAGES-000\n\n" + "\n\n".join(
        f"## Figure {i}\n\n![Local figure {i}](" +
        ("figures/blue.svg" if i % 2 == 0 else "reference/figures/green.svg") + ")"
        for i in range(12)) + "\n"
    annotated = prose.replace("BENCHMARK-PROSE", "BENCHMARK-ANNOTATED") + "\n" + "\n".join(
        discussion_block(i, 4) for i in range(20))
    conversation = prose.replace("BENCHMARK-PROSE", "BENCHMARK-LONG-DISCUSSION") + "\n" + discussion_block(0, 120)
    return {"short": short, "prose": prose, "long": long, "tables": tables,
            "images": images, "math": math, "mermaid": mermaid,
            "annotated": annotated, "long-discussion": conversation}


def discussion_block(index, message_count):
    lines = ["<!-- margined:thread v1", f"id: t-benchmark-{index}", "state: open",
             "target:", "  type: TextQuoteSelector", '  exact: "Section 0"',
             '  prefix: ""', '  suffix: "Read a local Markdown document,"', '  section: "Section 0"', "messages:"]
    for message in range(message_count):
        lines.extend([f"  - id: m-benchmark-{index}-{message}",
                      '    author: "Alex"' if message % 2 == 0 else '    author: "Sam"',
                      '    created: "2026-10-24T12:00:00Z"'])
        if message:
            lines.append(f"    in-reply-to: m-benchmark-{index}-{message - 1}")
        lines.extend(["    body: |", f"      Review message {message} in conversation {index}.",
                      "      Keep saved discussions readable and portable in an ordinary Markdown file."])
    return "\n".join(lines + ["-->", ""])


def fixture_assets(name):
    if name != "images":
        return {}
    return {
        path: ('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 320 180">'
               f'<rect width="320" height="180" rx="16" fill="{color}"/>'
               '<circle cx="160" cy="90" r="48" fill="white"/></svg>').encode()
        for path, color in (("figures/blue.svg", "#286bd6"), ("reference/figures/green.svg", "#23815b"))
    }


def write_fixture(directory, text, assets):
    destinations = []
    for name, data in assets.items():
        relative = Path(name)
        if relative.is_absolute() or ".." in relative.parts or relative == Path("."):
            raise ValueError("fixture asset must stay within the session directory")
        destinations.append((directory / relative, data))
    source = directory / "fixture.md"
    source.write_text(text, encoding="utf-8")
    for destination, data in destinations:
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_bytes(data)
    return source


def capture_provenance(app, source_root):
    """Record run-time source and bundle bytes; build-time source is pinned separately."""
    def manifest(root, names):
        files, links = {}, {}
        for name in sorted(set(names)):
            path = root / name
            if path.is_symlink(): links[name] = os.readlink(path)
            if path.is_file():
                digest = hashlib.sha256()
                with path.open("rb") as stream:
                    for block in iter(lambda: stream.read(1024 * 1024), b""): digest.update(block)
                files[name] = digest.hexdigest()
            elif not path.is_symlink():
                raise ValueError("source or bundle input is not a file: " + name)
        return {"files": files, "symlinks": links}

    def identified(value):
        encoded = json.dumps(value, sort_keys=True, separators=(",", ":")).encode()
        return dict(value, sha256=hashlib.sha256(encoded).hexdigest())

    source_root = source_root.resolve(); app = app.resolve()
    base = subprocess.check_output(["git", "-C", str(source_root), "rev-parse", "HEAD"], text=True).strip()
    names = subprocess.check_output(["git", "-C", str(source_root), "ls-files", "-z", "--cached", "--others", "--exclude-standard"])
    source = manifest(source_root, [name.decode("utf-8") for name in names.split(b"\0") if name])
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    executable = info.get("CFBundleExecutable", "")
    if (not executable or executable != Path(executable).name
            or not (app / "Contents/MacOS" / executable).is_file()):
        raise ValueError("app executable missing")
    bundle = manifest(app, [path.relative_to(app).as_posix() for path in app.rglob("*")
                            if path.is_file() or path.is_symlink()])
    return {"working_source": identified(dict(source, base=base)), "app_bundle": identified(bundle)}


PHASE_KEYS = ("note_parse_ns", "markdown_parse_ns", "projection_ns", "anchor_ns",
              "reading_metadata_ns", "review_tasks_ns", "artwork_ns", "serialization_ns")


def phase_durations(row):
    phases = row.get("render_phases")
    total, layout = row.get("renderer_total_ns"), row.get("layout_ready_ns")
    if (not isinstance(phases, dict) or set(phases) != set(PHASE_KEYS)
            or any(type(value) is not int or value < 0 for value in phases.values())
            or type(total) is not int or total < sum(phases.values())
            or total > row["render_ready_ns"] - row["request_ns"]
            or type(layout) is not int or not row["render_ready_ns"] <= layout <= row["frame_ns"]):
        raise ValueError("missing or impossible renderer/layout phase measurements")
    return dict(phases, renderer_ns=total, layout_wait_ns=layout-row["render_ready_ns"])


def summarize(rows, expected_count, kind):
    if type(expected_count) is not int or not 1 <= expected_count <= 100 or kind not in ("cold", "warm", "refresh"):
        raise ValueError("invalid cohort request")
    if (len(rows) != expected_count or any(type(r.get("index")) is not int for r in rows)
            or [r.get("index") for r in rows] != list(range(expected_count))):
        raise ValueError("incomplete or duplicate sample cohort")
    render, frame, pids, geometries = [], [], [], []
    for row in rows:
        geometry = row.get("geometry", {})
        geometry_keys = ("windowWidth", "windowHeight", "viewportWidth", "viewportHeight", "backingScale", "imageWidth", "imageHeight")
        dimensions = [geometry.get(key) for key in geometry_keys]
        if any(type(value) not in (int, float) or not math.isfinite(value) or value <= 0 for value in dimensions):
            raise ValueError("missing or invalid measured window/viewport geometry")
        geometries.append(dimensions)
        values = [row.get(k) for k in ("pid", "request_ns", "render_ready_ns", "frame_ns")]
        if any(type(value) is not int or value <= 0 for value in values):
            raise ValueError("invalid sample timestamps or process identity")
        pid, start, ready, end = values
        if not start <= ready <= end:
            raise ValueError("nonmonotonic sample stages")
        pids.append(pid)
        render.append((ready-start)/1_000_000)
        frame.append((end-start)/1_000_000)
    if any(value != geometries[0] for value in geometries):
        raise ValueError("viewport geometry changed within the cohort")
    if len(set(pids)) != (expected_count if kind == "cold" else 1):
        raise ValueError("cold/warm process reuse contract violated")
    def stats(values):
        return {"median": statistics.median(values), "p95": sorted(values)[math.ceil(len(values)*.95)-1]}
    result = {"samples": len(rows), "render_ms": stats(render), "frame_ms": stats(frame), "geometry": rows[0]["geometry"]}
    if any("render_phases" in row for row in rows):
        durations = [phase_durations(row) for row in rows]
        result["phases_ms"] = {key.removesuffix("_ns"): stats([d[key]/1_000_000 for d in durations]) for key in PHASE_KEYS}
        result["renderer_ms"] = stats([d["renderer_ns"]/1_000_000 for d in durations])
        result["layout_wait_ms"] = stats([d["layout_wait_ns"]/1_000_000 for d in durations])
    return result


def read_result(payload, kind, count):
    presentation = payload.get("presentation", "collapsed")
    boundary = "verified-discussion-frame-v1" if presentation == "expanded" else "verified-frame-v1"
    if (payload.get("schema") != 1 or payload.get("status") != "ok" or payload.get("kind") != kind
            or payload.get("configuration") != "Release" or payload.get("boundary") != boundary
            or presentation not in ("collapsed", "expanded")):
        raise ValueError("child did not produce a valid optimized verified-frame result: " + str(payload.get("error", "invalid metadata")))
    rows = payload.get("samples", [])
    summarize(rows, count, "warm" if kind == "cold" else kind)
    # Preserve the original collapsed baseline format; the new producer declares
    # presentation and must supply complete phase and discussion evidence.
    if "presentation" not in payload:
        return rows
    keys = ("thread_count", "message_count", "attached_count")
    expected = payload.get("expected_discussions")
    if (not isinstance(expected, dict) or set(expected) != set(keys)
            or any(type(value) is not int or value < 0 for value in expected.values())
            or expected["attached_count"] > expected["thread_count"]):
        raise ValueError("missing or invalid discussion expectation")
    for row in rows:
        phase_durations(row)
        layout = row.get("discussion_layout")
        if (not isinstance(layout, dict) or any(type(layout.get(key)) is not int or layout.get(key) != expected[key] for key in keys)):
            raise ValueError("discussion census differs from expectation")
        if presentation == "expanded":
            geometry, history = row["geometry"], layout.get("history_geometry", {})
            if (expected["thread_count"] == 0 or layout.get("laid_out_cards") != expected["thread_count"]
                    or type(layout.get("laid_out_cards")) is not int
                    or not isinstance(layout.get("history_thread"), str) or not layout["history_thread"]
                    or type(layout.get("history_messages")) is not int or not 1 <= layout["history_messages"] <= expected["message_count"]
                    or geometry["viewportWidth"] > geometry["windowWidth"] - 300
                    or not isinstance(history, dict)
                    or any(type(history.get(key)) not in (int, float) or not math.isfinite(history.get(key)) or history.get(key) <= 0
                           for key in ("windowWidth", "windowHeight", "viewportWidth", "viewportHeight", "backingScale"))
                    or history["windowWidth"] != geometry["windowWidth"] or history["backingScale"] != geometry["backingScale"]):
                raise ValueError("incomplete native discussion sidebar/history")
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


def run_session(executable, directory, text, kind, count, expected_math=0, expected_diagrams=0, assets=None, presentation="collapsed", expected_discussions=(0, 0, 0, 0)):
    directory.mkdir()
    source = write_fixture(directory, text, assets or {})
    request = {"version": 1, "kind": kind, "sourceFile": source.name,
               "expectedMarker": text.splitlines()[0][2:], "sampleCount": count,
               "expectedMath": expected_math, "expectedDiagrams": expected_diagrams,
               "presentation": presentation, "expectedThreads": expected_discussions[0],
               "expectedMessages": expected_discussions[1], "expectedAttached": expected_discussions[2]}
    manifest = directory / "request.json"
    manifest.write_text(json.dumps(request), encoding="utf-8")
    environment = dict(os.environ, MARGINED_BENCHMARK_REQUEST=str(manifest), MARGINED_TEST_PREFERENCES="1")
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
    expected = dict(zip(("thread_count", "message_count", "attached_count"), expected_discussions[:3]))
    if payload.get("presentation") != presentation or payload.get("expected_discussions") != expected:
        raise ValueError("native result does not match the requested presentation/census")
    if presentation == "expanded" and any(row["discussion_layout"]["history_messages"] != expected_discussions[3] for row in payload["samples"]):
        raise ValueError("selected native history differs from fixture expectation")
    return payload


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True, help="New report directory; never overwrites an existing run")
    parser.add_argument("--samples", type=int, default=20, choices=range(1, 101), metavar="1..100")
    parser.add_argument("--cases", nargs="+", default=["cold", "warm", "refresh"], choices=["cold", "warm", "refresh"])
    parser.add_argument("--fixtures", nargs="+", default=list(fixtures()), choices=list(fixtures()))
    parser.add_argument("--presentation", choices=["collapsed", "expanded"], default="collapsed")
    args = parser.parse_args()
    if args.presentation == "expanded" and any(name not in ("annotated", "long-discussion") for name in args.fixtures):
        parser.error("expanded presentation requires annotated or long-discussion fixtures")
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
    report = {"schema": 1, "status": "incomplete",
              "boundary": "verified-discussion-frame-v1" if args.presentation == "expanded" else "verified-frame-v1",
              "presentation": args.presentation,
              "boundary_description": "Request to correct DOM, two animation frames and verified WebKit snapshot in a visible window of the active app; includes verification overhead. Not scan-out timing.",
              "hardware": {"machine": platform.machine(), "model": subprocess.check_output(["sysctl", "-n", "hw.model"], text=True).strip(), "os": platform.mac_ver()[0]},
              "app": {key: info.get(key) for key in ("CFBundleIdentifier", "CFBundleShortVersionString", "CFBundleVersion")},
              "host_load": {"before": list(os.getloadavg())},
              "cohorts": []}
    source_root = Path(__file__).resolve().parents[1]
    try:
        report["provenance"] = capture_provenance(app, source_root)
        for name in dict.fromkeys(args.fixtures):
            text = fixtures()[name]
            for kind in dict.fromkeys(args.cases):
                rows, children = [], []
                for session in range(args.samples if kind == "cold" else 1):
                    child = run_session(executable, output / f"{name}-{kind}-{session:03}", text, kind,
                                        1 if kind == "cold" else args.samples,
                                        expected_math=24 if name == "math" else 0, expected_diagrams=3 if name == "mermaid" else 0,
                                        assets=fixture_assets(name), presentation=args.presentation,
                                        expected_discussions={"annotated": (20, 80, 20, 4), "long-discussion": (1, 120, 1, 120)}.get(name, (0, 0, 0, 0)))
                    children.append(child)
                    for row in child["samples"]:
                        rows.append(dict(row, index=len(rows)))
                cohort = {"fixture": name, "kind": kind, "bytes": len(text.encode()),
                          "sha256": hashlib.sha256(text.encode()).hexdigest(), "samples": rows,
                          "asset_sha256": {path: hashlib.sha256(data).hexdigest() for path, data in fixture_assets(name).items()},
                          "summary": summarize(rows, args.samples, kind), "sessions": children}
                report["cohorts"].append(cohort)
                print(name, kind, json.dumps(cohort["summary"]), flush=True)
        if capture_provenance(app, source_root) != report["provenance"]:
            raise ValueError("Source or app bundle changed during measurement; this run is incomplete.")
        report["status"] = "ok"
    except (OSError, RuntimeError, ValueError, subprocess.SubprocessError) as error:
        report["error"] = str(error)
        print(str(error), file=sys.stderr)
    finally:
        report["host_load"]["after"] = list(os.getloadavg())
        (output / "report.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    return 0 if report["status"] == "ok" else 1


if __name__ == "__main__":
    sys.exit(main())
