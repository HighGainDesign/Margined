# Apex build source snapshot

Apex1.1.34, https://github.com/ApexMarkdown/apex, revision
`aaf4346ad5daeab483b7b81fb266dc47b7021d73`.
cmark-gfm https://github.com/github/cmark-gfm at
`3e43811579320be78b86ea79a9d520efa7698264`; libyaml https://github.com/yaml/libyaml
at`840b65c40675e2d06bf40405ad3f12dec7f35923`.

Pinned build sources and licenses are unchanged, including Package.swift.
MDView-owned integration overlays are documented below.
SOURCE-HASHES.json records their SHA256 values. Flattened submodules need no fetch.
A repo-relative local package avoids Xcode27's rejection of a remote product with
transitive unsafe warning flags. No parser upgrade or behavior patch is included.
Preserve licenses: Apex/libyaml MIT; cmark BSD-2-Clause plus component notices.

## MDView iOS build overlay

`Package@swift-6.0.swift` preserves the upstream manifest settings and adds only an
iOS-specific forced include, `PackageSupport/iOSProcessStubs.h`. Optional process
helpers (shell commands, plugins, external highlighters) fail with ENOTSUP on iOS.
The 206 pinned upstream files, including Package.swift, remain byte-identical and
are checked by script/verify-vendor.py. macOS compilation is unchanged.
