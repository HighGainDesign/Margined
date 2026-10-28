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

Mac and iPhone/iPad builds are in internal TestFlight. Quick Look dispatch and
local-image gaps, collaboration acceptance and performance acceptance remain open.
Verify real File Providers, background audio, accessibility and file handoff
before release.

## Future enhancements

- Syntax-highlighted JSON, YAML, TOML and other text files; evaluate HTML separately.

## Released foundation

The previous MDView releases provide Mac reading, Finder Quick Look, Drafts/live
streaming, file refresh, individual change review, checklist saves with Undo,
Read Aloud, seven interface languages, printing, GitHub alerts and offline math
and Mermaid. The approved icon and these capabilities carry into Margined.
