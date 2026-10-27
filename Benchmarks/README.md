# Viewing benchmarks

Development harness; no published speed claim yet. Build an instrumented optimized
Mac app (normal release builds do not enable this entry point):

```sh
xcodegen generate
xcodebuild -project Margined.xcodeproj -scheme Margined -configuration Release \
  -derivedDataPath /tmp/Margined-benchmarks CODE_SIGN_IDENTITY=- \
  OTHER_SWIFT_FLAGS='$(inherited) -D MARGINED_BENCHMARK' build
python3 script/benchmark-viewing.py \
  --app /tmp/Margined-benchmarks/Build/Products/Release/Margined.app \
  --output dist/benchmarks/first-run --samples 20
```

Leave the screen unlocked and app windows unobstructed. Release all native
computer-control sessions before timing; an active automation lease can prevent
macOS from activating the measured app. Run without other builds or native QA,
with the same source pin retained from the optimized build. The launcher records
source and app-file hashes, symlink targets, Git revision and host load before and
after measurement; changed source or app contents invalidate the run. The source
manifest identifies the working tree at run time, so retain the build-time pin to
prove it matches the binary. Write reports under ignored `dist/` or outside the
checkout. Do not relax the active-window guard. Reports retain synthetic
fixtures, source hashes, raw samples, measured viewport/scale, machine/OS/app
versions and median/p95. Missing math or diagram artwork invalidates a sample. Cold
means a fresh app process, with OS caches retained; warm opens reuse a process.
Refresh includes the actual file watcher. All diagrams finish before the renderer
publishes its output; their cost is included in render-ready time.

Frame time ends after correct DOM, two animation frames and a WebKit snapshot in
a window reported visible in the active app. This check allows partial occlusion;
keep windows unobstructed for native acceptance. Timing includes verification
overhead: an upper bound to a
verified rendered frame, not exact display scan-out. Failed or incomplete cohorts
are never summarized as successful.

The fixed corpus includes short and long prose, tables, local images in two
directories, math, Mermaid, matching prose with 20 discussions, and a 120-message
conversation. Local assets and their hashes are retained with each cohort.
The native fixture contract verifies 20 attached threads/80 messages and one
attached 120-message conversation. Run expanded cohorts separately:

```sh
python3 script/benchmark-viewing.py --app /path/to/Margined.app \
  --output /tmp/margined-expanded --samples 20 \
  --fixtures annotated long-discussion --presentation expanded
```

Expanded samples require stable native card frames, passage geometry and the
selected history's actual message DOM, fonts and snapshot. Their boundary is
`verified-discussion-frame-v1`; collapsed samples use `verified-frame-v1`.
Reports retain elapsed wall time for note parsing, Markdown parsing, projection,
anchors, reading metadata, review/tasks, artwork and serialization. Layout wait
includes history preparation and readiness verification. Artwork can await another
actor. These values are upper bounds with observation overhead.

Check a new optimized observer against its regression contract before timing:

```sh
python3 script/check-viewing-observer.py --app /path/to/Margined.app \
  --source-root . --output /tmp/margined-observer-check
```

Retain native results before claiming expanded-view performance. Invalid phase
ordering, missing histories and unexpected discussion counts reject the run.

## Acceptance targets

For ordinary local prose, tables, images and annotated documents, use complete
20-sample cohorts and these p95 gates:

| Operation | Target |
| --- | --- |
| Fresh process/open (OS caches retained) | <1 s |
| Subsequent document/open | <200 ms |
| File save to verified refreshed frame | <500 ms |

About 50 ms warm opening is a stretch target. Large files, math/Mermaid, expanded
conversations, mobile and system Quick Look need separately labeled cohorts;
a fast parser or HTML reply is not a visible-document result. Final 2.0 viewing
acceptance remains incomplete until actual runs satisfy the agreed scope.

## iPhone and iPad Simulator

Validate the launchers with `python3 -m unittest discover -s script/tests -p 'test_benchmark*.py'` (also run by CI).

The mobile observer uses the same fixtures, frame predicate and result validator.
Build a private copy so testing cannot open or stop the installed production app:

```sh
git worktree add --detach /tmp/Margined-mobile-source HEAD
cd /tmp/Margined-mobile-source
python3 - <<'PYTHON'
from pathlib import Path
p = Path("project.yml")
p.write_text(p.read_text().replace(
    "PRODUCT_BUNDLE_IDENTIFIER: design.highgain.margined",
    "PRODUCT_BUNDLE_IDENTIFIER: design.highgain.margined.benchmark.local"))
PYTHON
xcodegen generate
xcodebuild -project Margined.xcodeproj -scheme MarginediOS -configuration Release \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/Margined-mobile-benchmarks CODE_SIGN_IDENTITY=- \
  OTHER_SWIFT_FLAGS='$(inherited) -D MARGINED_BENCHMARK' build
```

Retain the build-time source manifest and optimized app hashes. Use `simctl list
runtimes` and `simctl list devicetypes` to select an available runtime and profile,
then create and boot a **new disposable** simulator. Install the private
`Build/Products/Release-iphonesimulator/MarginediOS.app` on that UUID. Leave the
screen unlocked, release native computer-control sessions, and avoid other builds
or simulator work during measurement. Run from the same private source copy:

```sh
python3 script/benchmark-mobile.py --device YOUR_NEW_SIMULATOR_UUID \
  --identifier design.highgain.margined.benchmark.local \
  --fixture prose --kind cold --samples 20 --output dist/benchmarks/mobile-cold
```

Repeat with `--kind warm` and `--kind refresh`, each with a new output directory;
select other corpus entries with `--fixture`. The command requires an explicit
UUID and private bundle ID, refuses an already-running app, and stops only its
owned app process. It neither installs nor deletes simulators. Archive results,
then shut down and delete only the simulator you created.

Cold uses an external Mach clock before `simctl launch`; warm retains a process;
refresh waits for the real file presenter after atomic saves. Raw requests,
results, phases, PNGs, actual simulator-screen spot checks and source/app hashes
are retained. Clock/PID/census/geometry failures reject results. Inspect the saved
screens before accepting a run. Simulator dispatch and verification overhead are
included; these numbers do not establish physical-device latency. No mobile
numeric release gate is defined.

System Quick Look needs a separate native host and actual provider dispatch.
Internal HTML packaging timings cannot stand in for system preview display.

The CPU-only table regression can run without an unlocked desktop after building
optimized products:

```sh
python3 script/tests/test_apex_tables.py
```

Set `MARGINED_BENCHMARK_PRODUCTS` if the Release products are elsewhere. Its
2-second conversion guard catches pathological table processing; it is not a
viewing-speed target or a substitute for native frame benchmarks.
