# Apex build source snapshot

Apex1.1.34, https://github.com/ApexMarkdown/apex, revision
`aaf4346ad5daeab483b7b81fb266dc47b7021d73`.
cmark-gfm https://github.com/github/cmark-gfm at
`3e43811579320be78b86ea79a9d520efa7698264`; libyaml https://github.com/yaml/libyaml
at`840b65c40675e2d06bf40405ad3f12dec7f35923`.

The upstream revision and licenses are pinned. Margined-owned integration overlays
and the local performance patch are documented below.
SOURCE-HASHES.json records their SHA256 values. Flattened submodules need no fetch.
A repo-relative local package avoids Xcode27's rejection of a remote product with
transitive unsafe warning flags. No parser upgrade is included.
Preserve licenses: Apex/libyaml MIT; cmark BSD-2-Clause plus component notices.

## Margined iOS build overlay

`Package@swift-6.0.swift` preserves the upstream manifest settings and adds only an
iOS-specific forced include, `PackageSupport/iOSProcessStubs.h`. Optional process
helpers (shell commands, plugins, external highlighters) fail with ENOTSUP on iOS.
The upstream build configuration is unchanged on macOS. All 206 source hashes,
including the documented patch below, are checked by script/verify-vendor.py.

## Table performance patch

`src/extensions/table_html_postprocess.c` skips previous-row rowspan searches when
the current table has no collected rowspan attributes. Removed-row marker positions are computed once per table, and visible columns
are collected once per row. The existing 100-row marker-search and 50-column
mapping boundaries are preserved. The rowspan path itself is unchanged; captions,
column spans, alignment, footers and row headers are retained.
CPU-only regressions: `python3 script/tests/test_apex_tables.py` after an optimized
build (see Benchmarks/README.md).

Original upstream SHA256: `c0cc4d948487809a8ec2ea36f3611b8bf7a5667f4c7b6ca3bbbaefed4a8ec9d3`.
Current patched SHA256 is recorded in SOURCE-HASHES.json. The remaining 205
upstream files, including Package.swift, are byte-identical to the pinned revision.

The postprocessor also preserves literal span-like text and formatted code by
requiring a complete cell marker, and no longer removes a real footer row because
the preceding AST row is a separator. Regression controls cover both content-loss
cases, true spans, escaped markers, row headers, captions and alignment.
