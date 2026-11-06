# Maintaining this skill

User request: keep the Margined authoring skill current for other agents. Updates are driven by verified product changes and demonstrated authoring failures, not a periodic rewrite or an untested roadmap.

Latest authoring check: beta.4 source `0e31abf`, 2026-11-04. The local Mac
CPU probes passed the real task/source-mapper examples and discussion contract.
The original Build 14 parser/source-mapper fix is revision `bd1d96e`.
Inline-pipeline and multi-block task mapping pass the real renderer/source-mapper
checks on Mac and the focused iOS rendering suite. Retain the Build 13
compatible example and guidance for older readers. Discussion v1
and its baseline `9de60d5` contract remain unchanged.

The maintained source is `skills/margined-markdown/` in the [Margined repository](https://github.com/HighGainDesign/Margined/tree/main/skills/margined-markdown). Update it in Git alongside authoring-relevant product changes. Installed skill folders are consumers; compare local edits before refreshing them from GitHub. Keep the complete skill directory together when distributing it.

Build 17 implementation (2026-11-06) adds the visible choose-one and short-answer conventions. Core/state commits `e57d1fc` and `09c9d84`, UI commit `9dbbabe`; local parser, exact-file-edit and native-editor checks pass. This is an implementation verification, not a public release claim. The new `assets/responses-example.md` is checked with the actual mapper, literal-answer round trip and exact Undo. Preserve the older examples for earlier readers.

## When Margined changes

Check this skill during changes to Markdown options, sanitization, task mapping/writes, discussion format/anchors/exports, image access, math/diagrams, or file limits. Update only affected guidance and examples. Record the source revision/build and verification date. Distinguish an internal fix from one released to the intended reader; keep older-build workarounds where needed.

Use the source checkout for the version/build being documented; record its revision and verification date. Do not mistake an older stable checkout or a future proposal for current behavior. Authoritative paths within that checkout:

| Subject | Source |
|---|---|
| Markdown dialect/options | `Shared/MarkdownRenderer.swift`, `Vendor/Apex/PROVENANCE.md` |
| Allowed HTML/image dimensions | `Shared/HTMLAdapter.swift` |
| Encoding/size limit | `Shared/MarkdownSource.swift` |
| Response grammar/writes | `Shared/MarkdownResponses.swift`, `Tests/MarkdownResponseTests.swift`, `Tests/ResponseStateTests.swift`, `RESPONSES.md` |
| Task provenance | `Shared/MarkdownTasks.swift`, `Tests/MarkdownTaskTests.swift` |
| Thread wrapper/schema | `Shared/Discussions/DiscussionCodec.swift`, `RestrictedYAML.swift` |
| Serialization/escaping | `Shared/Discussions/DiscussionEdits.swift`, `DiscussionYAML.swift` |
| Quoted passage matching | `Shared/Discussions/DiscussionText.swift`, `DiscussionAnchors.swift` |
| Regression examples | `Tests/DiscussionCodecTests.swift`, `Tests/DiscussionAnchorTests.swift` |
| Platform permissions/renderer limits | Current `README.md` plus owning implementation/tests |

## Each release

Before tagging a stable or beta release, check this skill against that release's
formats, behavior and limits; update guidance, compatibility notes and examples
in the same source commit as needed. Record the verified app build/revision/date.
Keep the full skill in the release tag so users can install a fixed snapshot.

The release packager creates a skill ZIP and SHA-256 checksum from the committed
source alongside the DMG. Verify both files are attached to the same GitHub
release. For manual releases, run `bash script/package-skill.sh VERSION TAG` from
the release checkout and upload both skill files as well. Never package a
machine-local installation or silently replace a previous release's snapshot.

## Verification

1. Read the changed contract and its regression tests. Do not turn a proposed feature into authoring guidance before it exists.
2. Recheck the skill's runnable Markdown example with the actual codec and task mapper when available; preserve readable prose, expected tasks, two messages and the reply link. For parser fixes, test the minimal former failure as well as the recommended workaround.
   `assets/review-example.md` remains compatible with Build 13. The separate
   `assets/build14-checklist.md` exercises the Build 14 source and must not be
   used to claim that older installed readers gained the fix. After building Mac
   products without launching the app, set `MARGINED_TASK_PRODUCTS` and run
   `python3 script/tests/test_markdown_tasks.py` to check both examples.
3. Validate skill frontmatter and local links. If the skill-creator validator is installed, run `python3 <skill-creator>/scripts/quick_validate.py <skill-directory>`.
4. If guidance changed substantially, try a realistic authoring task with the skill and inspect the produced `.md`, rather than checking only wording.

Do not launch apps, rebuild/upload a release, publish private documents, change credentials, or reset system registrations merely to maintain this reference. Existing project resource/authorization rules still apply. Never commit the project's ignored developer docs or agent shims as part of a skill update.
