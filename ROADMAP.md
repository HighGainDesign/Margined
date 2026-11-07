# Margined roadmap

Margined is a fast Markdown reader with focused editing and review. Documents
stay ordinary text files that people and agents can use in their own tools.

## 2.0

| Pillar | Release requirements |
| --- | --- |
| **iOS and iPadOS** | Native Files access, opening and sharing Markdown, reading, checklists, change review and Read Aloud. Share-sheet access; iPhone Duo inner/outer displays and live resizing that preserves reading position and unfinished replies. Quick Look where Files supports Markdown extensions. |
| **File-based collaboration** | Passage-attached discussions, multiple threads on the same text, named replies and open/resolved status. The document and conversation live in one `.md` file, editable with Margined or another text editor. |
| **Fast viewing** | Reproducible cold-open, warm-open, refresh and Quick Look benchmarks. Record request-to-visible-document and completed diagrams separately, with hardware, fixtures, median and p95. Fix measured bottlenecks against agreed targets. |

### Collaboration design

The approved design uses a margin on wider screens and a dedicated thread screen
on compact layouts. Named messages, dates, replies and resolution history live in
bounded HTML comments containing readable YAML. Quote and context selectors anchor
them to the prose; ambiguous or missing passages need explicit reattachment.

See [the file format](DISCUSSIONS.md). Other text editors can edit the same file;
ordinary Markdown previews hide the notes. No account, cloud service or sidecar is
required. Native accessibility, safe writes, divergent-copy reconciliation and
cross-editor round trips remain release acceptance checks.

### Performance acceptance

Measure optimized builds with a fixed corpus: short prose, long documents,
tables, local images, math/Mermaid and annotated files. Separate cold process and
renderer startup from subsequent document opens. Keep comparison fixtures and
hardware constant, report tail latency and check that comments do not slow basic
viewing. The competing 47 ms claim is a warm subsequent-open reference, not an
established cold-launch target or a measured Margined result.

### Delivery

The Mac beta is available on GitHub and public TestFlight. iPhone/iPad beta
availability and public TestFlight distribution are recorded in the
[delivery tracker](https://github.com/HighGainDesign/Margined/issues/24).
Native Files browsing and the replayable practice tour
are implemented. Manual acceptance testing continues, including File Providers,
background audio, accessibility and file handoff. iOS 27 Quick Look dispatch
remains limited; use Open With or Share.

The current [2.0 delivery tracker](https://github.com/HighGainDesign/Margined/issues/24)
targets these next steps; build numbers may move if additional fixes are needed:

- **Build 14:** correct checklists containing inline pipelines and nested
  commands, and suggest the current document's folder for iOS image access.
  Combined Build 11–14 manual testing continues. Broader menu/navigation changes
  remain pending feedback and acceptance.
- **Build 15:** Mac public TestFlight beta with the Quick Look entitlement repair.
  Combined Build 11–14 manual acceptance remains open.
- **Build 16:** delivered iOS reading-position restoration during resizing and
  unfinished-reply browsing, with matching Mac/iOS TestFlight and GitHub builds.
  Combined manual acceptance remains open.
- **Build 17:** delivered compact choose-one checkboxes and focused text responses,
  readable Markdown conventions, safe saves/Undo and the matching authoring skill.
  Public Mac TestFlight, iPhone/iPad TestFlight and
  [GitHub beta.5](https://github.com/HighGainDesign/Margined/releases/tag/v2.0-beta.5)
  now match **2.0 (17)** from the same product source; testers were notified.
  Combined manual acceptance remains open.
- **Build 18:** planned release candidate after remaining manual acceptance,
  accessibility/performance, documentation and distribution checks. The hosted
  iOS diagram-startup CI blocker is resolved in
  [PR #30](https://github.com/HighGainDesign/Margined/pull/30): trusted WebKit
  readiness now precedes functional assertions, with full local iOS and hosted
  pre-/post-merge validation passing. Track evidence and remaining acceptance in
  the [delivery tracker](https://github.com/HighGainDesign/Margined/issues/24).

Keep the maintained Markdown authoring skill aligned with each release's actual
formats and limits; package its committed ZIP/checksum with that release. Internal
implementation, human acceptance and public availability are separate gates.

## Future enhancements

- Syntax-highlighted JSON, YAML, TOML and other text files; evaluate HTML separately.
- Fenced-code highlighting, editing posted comments, Find/outline refinements,
  diagram navigation and clipboard/CLI input follow 2.0.

## Released foundation

The previous MDView releases provide Mac reading, Finder Quick Look, Drafts/live
streaming, file refresh, individual change review, checklist saves with Undo,
Read Aloud, seven interface languages, printing, GitHub alerts and offline math
and Mermaid. The approved icon and these capabilities carry into Margined.
