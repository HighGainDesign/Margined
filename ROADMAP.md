# Margined roadmap

Margined is a fast Markdown reader with focused editing and review. Documents
stay ordinary text files that people and agents can use in their own tools.

## 2.0

| Pillar | Release requirements |
| --- | --- |
| **iOS and iPadOS** | Native Files access, opening and sharing Markdown, reading, checklists, change review and Read Aloud. Add share-sheet access. Implement a custom Quick Look extension where supported and verify that Files invokes it for Markdown. |
| **File-based collaboration** | Passage-attached discussions, multiple threads on the same text, named replies and open/resolved status. The document and conversation live in one `.md` file, editable with Margined or another text editor. |
| **Fast viewing** | Reproducible cold-open, warm-open, refresh and Quick Look benchmarks. Record request-to-visible-document and completed diagrams separately, with hardware, fixtures, median and p95. Fix measured bottlenecks against agreed targets. |

### Collaboration design review

**The collaboration design and mockups require user review and approval before
implementation.** Review Mac/iPad margin layouts and the compact iPhone flow,
then settle the portable file convention and ordinary-editor round trip.

The design must cover:

- Several independent discussions on one passage, with author, date and replies.
- Discussion, explicit approval and acknowledgement of a saved change as distinct
  actions. Resolving a thread preserves its history.
- Stable anchors when text moves; a visible recovery path when a passage changes,
  disappears or matches ambiguously. Never silently attach a different passage.
- Existing document metadata, duplicate quotations, overlapping selections,
  Unicode, tables and multi-paragraph comments.
- Human/agent edits to the same file, stale-write protection and reconciliation
  when copies diverge. Passing a file around must work without a hosted service.
- Keyboard, VoiceOver and touch use; accessible thread navigation and notes in
  read-only previews. A clean-copy export should intentionally omit discussions.

Evaluate these as complementary building blocks, not interchangeable formats:

| Candidate | What it provides | What still needs design |
| --- | --- | --- |
| [CriticMarkup](https://github.com/CriticMarkup/CriticMarkup-toolkit) | Plain-text editorial marks and comments; parser support already exists in Apex. | Stable thread/message IDs, authors, reply relationships and overlapping discussions. It does not require adopting all of MultiMarkdown. |
| [W3C Web Annotation](https://www.w3.org/TR/annotation-model/) | Annotation relationships and quote/context selectors for anchoring. | A readable serialization inside a single Markdown file and conflict behavior. |
| [Mist](https://github.com/inanimate-tech/mist/blob/main/docs/markdown-and-criticmarkup.md) | A precedent for CriticMarkup plus single-file thread metadata. | Ordinary-editor usability, durable IDs and fit with the shared native reader. |
| [HackMD](https://hackmd.io/) | Useful reference for commenting and reply interactions. | Its hosted collaboration model must not become a requirement for local files. |

The file convention remains undecided. Full MultiMarkdown compatibility is a
separate decision; assess its useful features and compatibility without replacing
Apex or claiming blanket support.

### Performance acceptance

Measure optimized builds with a fixed corpus: short prose, long documents,
tables, local images, math/Mermaid and annotated files. Separate cold process and
renderer startup from subsequent document opens. Keep comparison fixtures and
hardware constant, report tail latency and check that comments do not slow basic
viewing. The competing 47 ms claim is a warm subsequent-open reference, not an
established cold-launch target or a measured Margined result.

### Delivery

The iOS reader MVP exists locally; share/Quick Look integration, collaboration and
performance acceptance remain 2.0 work. Prepare Mac and iOS test builds and verify
real File Providers, background audio, accessibility and file handoff. A roadmap
entry or Simulator build alone is not release acceptance.

## Released foundation

The previous MDView releases provide Mac reading, Finder Quick Look, Drafts/live
streaming, file refresh, individual change review, checklist saves with Undo,
Read Aloud, seven interface languages, printing, GitHub alerts and offline math
and Mermaid. The approved icon and these capabilities carry into Margined.
