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

Leave the screen unlocked and app windows unobstructed. Reports retain synthetic
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

System Quick Look and iOS timings require separate native runs. Internal HTML
packaging timings cannot stand in for system preview display.
