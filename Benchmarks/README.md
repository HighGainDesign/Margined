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
and record source/binary hashes and host load alongside each report. Do not
relax the active-window guard to obtain a result. Reports retain synthetic
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
Annotated cohorts currently measure reading with discussions collapsed; expanded
inspectors, native note/anchor validation and separate parse/layout timings still
need acceptance before publishing results.

System Quick Look and iOS timings require separate native runs. Internal HTML
packaging timings cannot stand in for system preview display.

The CPU-only table regression can run without an unlocked desktop after building
optimized products:

```sh
python3 script/tests/test_apex_tables.py
```

Set `MARGINED_BENCHMARK_PRODUCTS` if the Release products are elsewhere. Its
2-second conversion guard catches pathological table processing; it is not a
viewing-speed target or a substitute for native frame benchmarks.
