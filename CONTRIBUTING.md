# Contributing to Margined

Margined is a native Markdown reader with focused checklist and discussion edits.
Keep files portable, reading fast, and writes safe. The 2.0 branch supports Mac,
iPhone and iPad and is in internal beta; see [ROADMAP.md](ROADMAP.md).

## Issues and proposals

Include the OS/device, app version/build, expected and actual behavior, and a
minimal Markdown sample. Identify the surface: app, Quick Look, Files/share or
Drafts. Replace private content before sharing it. Discuss substantial features
before opening a large pull request.

## Build and test

Use Xcode 26+, its command-line tools and XcodeGen 2.44+. Deployment targets are
macOS 14 and iOS 17. `project.yml` is authoritative; the generated Xcode project
is ignored. Dependencies are pinned. Start the Mac development app with:

```sh
./script/build_and_run.sh
```

The script supports `--verify`, `--debug`, `--logs` and `--telemetry`. Products go
to `/tmp/Margined-build-<uid>` to avoid Dropbox metadata signing failures; override
with `MARGINED_BUILD_DIR`. It leaves the installed app untouched. It uses an
existing Apple signing identity when available, otherwise ad-hoc signing;
`MARGINED_SIGNING_IDENTITY` overrides the choice. Finder Quick Look needs separate
verification with a properly signed installed bundle.

Generate and test the Mac target:

```sh
xcodegen generate
xcodebuild -project Margined.xcodeproj -scheme Margined \
  -destination 'platform=macOS' -derivedDataPath /tmp/Margined-tests \
  CODE_SIGN_IDENTITY=- test
```

For iPhone/iPad, select an available Simulator and run the `MarginediOS` scheme:

```sh
xcodebuild -project Margined.xcodeproj -scheme MarginediOS \
  -destination 'platform=iOS Simulator,id=SIMULATOR_UDID' \
  -derivedDataPath /tmp/Margined-ios-tests CODE_SIGNING_ALLOWED=NO test
```

Replace `SIMULATOR_UDID` with your device’s identifier. Real-device builds require
your own team and profiles. Simulator checks do not replace real File Provider,
background audio or share-sheet acceptance. [Viewing benchmarks](Benchmarks/README.md)
use a separate optimized build and strict visible-frame checks.

## Code boundaries

- `App/`: Mac documents, reader UI, settings, speech and file refresh.
- `iOS/`: native Files lifecycle, reader/navigation, image grants and audio controls.
- `QuickLook/`: shared preview-provider entry point; `iOSQuickLook/` supplies iOS metadata.
- `Shared/`: rendering, discussions, safe file formats, styles and preferences; keep platform dependencies isolated.
- `Tests/` and `iOSTests/`: platform, renderer, lifecycle and native integration checks.
- `Integrations/Drafts/`: Mac action resource and URL integration.
- `script/`: validation, local builds and packaging.

## Rendering and localization

`Vendor/Apex` pins Apex 1.1.34 and cmark-gfm/libyaml sources. Build overlays and
table fixes are documented in [provenance](Vendor/Apex/PROVENANCE.md). Verify with
`python3 script/verify-vendor.py`; retain original licenses and document patches.
Never change hashes merely to conceal a parser change.

Ordinary builds need no Node. To regenerate bundled KaTeX/Mermaid resources, run
`npm ci --ignore-scripts` and `npm run build` in `Rendering/`. Preserve its lockfile,
KaTeX override, Safari 17 target and license notices; rerun rendering/security checks.

`SWIFT_EMIT_LOC_STRINGS=YES` is enabled. After building, sync the String Catalog
with `python3 script/sync-localizations.py /path/to/DerivedData`, rebuild, and run
`python3 script/test-localizations.py /path/to/DerivedData` after `build-for-testing`.
Run `python3 script/validate-localizations.py` before rebuilding. Keep plural forms,
accessibility text and native menus localized across all seven interface languages.
Document language is separate from interface language; keep product names and URL
schemes unchanged.

## Safety and review

Keep pull requests focused: explain the problem, resulting behavior and checks.
Add regression coverage for parsing, permissions, file writes and lifecycle changes.
Use non-private samples for layout captures. Changes to shared rendering require
checks in both apps, Quick Look and print where affected.

Preserve first-click checklist consent, exact task-marker writes, discussion
conflict checks, source identity, encodings/line endings and Undo ownership.
Discussion format changes must preserve unknown fields and unsupported blocks;
see [DISCUSSIONS.md](DISCUSSIONS.md). Ordinary previews must keep notes hidden.
Do not enable document scripts or silently fetch remote images.

The Mac DMG uses normal OS file access. Mac TestFlight uses the AppStore
configurations and sandbox entitlements; iOS also requires folder grants for
sibling images. Keep those variants distinct. Signing with another team requires
matching bundle IDs, App Groups, entitlements, profiles and shared-preference
identifiers. Ad-hoc tests use isolated preferences, not the signed app’s container.
Never grant broad access to other apps’ data to bypass signing setup.

Do not commit credentials, profiles, build products, personal settings or local
agent notes. Close and remove temporary app bundles and eject installers after QA;
macOS can otherwise list extra copies in Open With and Extensions.

## Mac distribution

`script/release.sh` builds universal binaries, signs the app and extension,
notarizes/staples the app, creates the DMG with an Applications link, then
notarizes/staples the DMG. The script does not publish to GitHub.

```sh
python3 -m venv /tmp/margined-dmg-env
/tmp/margined-dmg-env/bin/pip install ds_store==1.3.2
MARGINED_DMG_PYTHON=/tmp/margined-dmg-env/bin/python ./script/release.sh
```

Set your `MARGINED_SIGNING_IDENTITY`, `MARGINED_TEAM_ID` and Keychain
`MARGINED_NOTARY_PROFILE` (default `Notarize`). Alternatively use
`MARGINED_NOTARY_API_KEY_PATH`, `MARGINED_NOTARY_API_KEY_ID` and
`MARGINED_NOTARY_ISSUER_ID`; keep the key outside the repository.
`--build-only` keeps the signed app; `--skip-notarize` makes a local signed DMG.
Normal packaging preserves an app ZIP and removes temporary registered bundles.

The GitHub release workflow accepts matching `vX.Y.Z` tags from the default branch.
Tests run before loading encrypted release-environment credentials; signing and
notarization are verified before publishing the DMG and checksum. Contributors
need no release credentials. Internal TestFlight delivery is separate from public
GitHub or App Store publication.

Contributions use the repository’s MIT license. Retain third-party notices.
