# Contributing to Margined

Margined is a small Markdown viewer, read-only by default. Explicit checklist saves
are the exception and change only task markers. Changes should make reading faster
or clearer while keeping the app simple. Version 1.x supports macOS; version 2.0
is planned for macOS and iOS. See [ROADMAP.md](ROADMAP.md).

## Issues and proposals

For a bug, include your macOS version, Margined version, expected behavior, actual
behavior, and a small Markdown example. Explain whether the problem occurs in
the app, Finder Quick Look, or the Drafts action. Replace private content with a
minimal example before sharing it.

Discuss substantial features before opening a large pull request. Specialized
Markdown extensions, arbitrary text editing, and export workflows are outside the initial
release scope.

## Local development

Use Xcode 26 or later, its command-line tools, and XcodeGen 2.44 or later. The app
supports macOS 14 and later. See the README for build and test commands.

`project.yml` is the authoritative project definition; the generated
`Margined.xcodeproj` is ignored. Dependency versions are pinned there. Tests run
with isolated preferences so an ad-hoc test host does not request access to the
signed app's shared settings container.

For signed builds with your own Apple team, replace `DEVELOPMENT_TEAM` in
`project.yml` and the team prefix in both application-group entitlement entries
and `Shared/ReaderPreferences.swift`. Keep the app and Quick Look extension in
the same group and sign both with the same team. App Group access is verified
separately in a signed Finder preview. Never grant broad access to other apps'
data to make an ad-hoc build work.

The main code boundaries are:

- `App/`: document lifecycle, SwiftUI reader, settings, and file refresh.
- `QuickLook/`: Finder's data-based preview provider.
- `Shared/`: parser, HTML adaptation, styles, and shared preferences. Keep this
  layer free of AppKit so it can serve a future iOS reader.
- `Tests/`: renderer, change review, preferences, WebKit, and window checks.
- `Integrations/Drafts/`: action resource and URL integration.
- `script/`: local build and release packaging.

## Rendering dependencies

`Vendor/Apex` contains unchanged build sources for Apex1.1.34 and its pinned
cmark-gfm/libyaml submodules. Verify them with `python3 script/verify-vendor.py`.
Keep the revision/hash inventory and original licenses when updating the snapshot;
do not edit generated source hashes to hide a parser change.

The app bundles the committed KaTeX/Mermaid resources. Users and ordinary Xcode
builds do not need Node. To regenerate them, run `npm ci --ignore-scripts` and
`npm run build` inside `Rendering/`, using its lockfile. Keep the KaTeX override,
Safari17 target and generated license notices; rerun rendering/security tests.

## Localization

Build with `SWIFT_EMIT_LOC_STRINGS=YES` (enabled in `project.yml`), then run
`python3 script/sync-localizations.py /path/to/DerivedData` to sync the shared
String Catalog. Rebuild to compile catalog changes. Run `python3 script/test-localizations.py /path/to/DerivedData`
after `build-for-testing` to check each language in a fresh process. Keep count messages pluralized
and localize native menus, errors and accessibility text as well as SwiftUI labels.
Run `python3 script/validate-localizations.py` before rebuilding. English, Spanish,
Simplified/Traditional Chinese, Japanese, French and German are included;
native-speaker corrections are welcome. Keep product names and URL schemes unchanged.
Document language is separate, detected on-device or selected per window.

## Pull requests

Keep each pull request focused. Explain the user-visible problem, the resulting
behavior, and how you checked it. Add a regression test when a change affects
parsing, permissions, preferences, or document lifecycle. For layout changes,
include a screenshot made with a non-private sample document.

Run the relevant tests and check Finder Quick Look when shared rendering or
extension behavior changes. Verify light/dark appearance, tables, links, and
automatic refresh when they are affected. Preserve read-only defaults, the
consent-gated task-marker exception, bounded image reads, and inert HTML/scripts.
The directly distributed main app uses normal macOS filesystem permissions; the
Quick Look extension stays sandboxed, with a read-only path exception for local
image attachments. Explain this exception when submitting for App Store review.

Do not commit signing certificates, private keys, provisioning profiles, build
products, personal settings, or local agent notes. After testing, close and
remove temporary app bundles and eject old installers; macOS can discover those
copies in Open With and Extensions.

## Releases

Maintainers use `script/release.sh` to build universal binaries, sign the app and
extension, notarize both the app and DMG, and staple their tickets. The GitHub
release workflow runs on a matching `vX.Y.Z` tag from the default branch. Its
release environment is restricted to approved version tags; Apple credentials
are encrypted environment secrets. Every tagged release runs tests before
loading credentials, validates signatures and notarization, and publishes the
DMG with its checksum. Versions below 1.0 are marked as previews. Contributions
do not need access to release credentials.

Local packaging defaults to the Keychain profile selected by
`MARGINED_NOTARY_PROFILE` (default: `Notarize`). Alternatively, supply an existing
App Store Connect API key file through `MARGINED_NOTARY_API_KEY_PATH`, with
`MARGINED_NOTARY_API_KEY_ID` and `MARGINED_NOTARY_ISSUER_ID`. Keep private key files
outside the repository. This option uses the key directly without creating a
new Keychain profile.

By submitting a contribution, you agree to license it under the repository's
MIT license. Retain third-party license notices when changing dependencies.

### iOS

After `xcodegen generate`, build or test the `MarginediOS` scheme on an iPhone or
iPad Simulator. Device builds need your own signing configuration. Keep shared
rendering behavior consistent with macOS; test Files lifecycle and audio on a real
device before shipping.
