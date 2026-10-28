# System Quick Look benchmarks

This developer harness measures actual OS dispatch of the private preview provider.
It checks the owned window, rendered marker, two local images and provider events.
Blank/raw-text controls and the authored discussion appendix must pass first.
Warm runs render an unmeasured baseline before collecting samples.

Use a private source copy, an unlocked desktop, existing screen-capture permission
and an exclusive native testing slot. The tool never requests capture permission.
Store reports outside the checkout or in an ignored directory such as `dist/`.
It registers only its private test type, unregisters its exact paths and retires
its copied runtime from local temporary storage. Normal `.md` associations must remain unchanged. Failed runs
retain evidence and exit with an error. Do not run Python with `-O`.

## Build the private host

```sh
git worktree add --detach /tmp/Margined-ql-source HEAD
cd /tmp/Margined-ql-source
python3 - <<'PY'
from pathlib import Path
import shutil
p = Path('project.yml')
s = p.read_text()
for old, new in [
    ('PRODUCT_BUNDLE_IDENTIFIER: design.highgain.margined', 'PRODUCT_BUNDLE_IDENTIFIER: design.highgain.margined.benchmark.ql14'),
    ('net.daringfireball.markdown', 'design.highgain.margined.benchmark.ql14.document'),
    ('[md, markdown, mdown, mkd, mkdn]', '[marginedqlbench14]'),
    ('text/markdown', 'text/x-margined-ql-bench14'),
    ('[margined]', '[margined-ql-bench14]'),
]:
    assert old in s, old
    s = s.replace(old, new)
p.write_text(s)
shutil.copyfile('Benchmarks/QuickLook/PreviewProvider.swift', 'QuickLook/PreviewProvider.swift')
PY
xcodegen generate
xcodebuild -project Margined.xcodeproj -scheme Margined -configuration Release \
  -destination 'platform=macOS' -derivedDataPath /tmp/Margined-ql-build \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=YES CODE_SIGN_IDENTITY=- \
  OTHER_SWIFT_FLAGS='$(inherited) -D MARGINED_BENCHMARK' build
python3 - <<'PY'
from pathlib import Path
import plistlib, shutil
product = Path('/tmp/Margined-ql-build/Build/Products/Release/Margined.app')
host = Path('/tmp/Margined-ql-host/ScopeHost.app/Contents')
(host / 'MacOS').mkdir(parents=True)
info = plistlib.loads((product / 'Contents/Info.plist').read_bytes())
info.update(CFBundleExecutable='ScopeHost', CFBundleName='Margined QL benchmark', CFBundleDisplayName='Margined QL benchmark')
for key in ('CFBundleURLTypes', 'CFBundleIconName', 'CFBundleIconFile'):
    info.pop(key, None)
(host / 'Info.plist').write_bytes(plistlib.dumps(info))
shutil.copytree(product / 'Contents/PlugIns', host / 'PlugIns')
PY
swiftc -swift-version 6 -O -parse-as-library Benchmarks/QuickLook/Host.swift \
  -framework AppKit -framework QuickLookUI \
  -o /tmp/Margined-ql-host/ScopeHost.app/Contents/MacOS/ScopeHost
swiftc -swift-version 6 -O -parse-as-library Benchmarks/QuickLook/Recognize.swift \
  -framework Vision -framework ImageIO -o /tmp/Margined-ql-host/recognize
codesign --force --sign - /tmp/Margined-ql-host/ScopeHost.app
codesign --verify --deep --strict /tmp/Margined-ql-host/ScopeHost.app
```

Retain the build-time source manifest and product hashes. The private provider
uses a fixed light appearance and the production renderer/reply/attachment path;
it does not read shared user preferences. No Apple signing key is needed.

## Measure

```sh
python3 script/benchmark-quicklook.py \
  --host /tmp/Margined-ql-host/ScopeHost.app \
  --recognize /tmp/Margined-ql-host/recognize \
  --kind cold --samples 20 --output /tmp/Margined-ql-cold-results
```

Repeat with `--kind warm` and a new output directory. Retain reports, raw samples,
provider logs, screenshots, fixture hashes and source/product manifests. Inspect
the saved images before accepting results. Archive the private build and remove
only the temporary products/worktree you created when finished.

Timing starts before assigning the preview item and ends after capture, OCR and
pixel verification. Host construction/activation precedes the clock. These are
upper bounds with substantial observation overhead, not exact first paint or
parser speed. Private-UTI dispatch does not establish Finder's default Markdown
association. No Quick Look numeric release gate is defined.
