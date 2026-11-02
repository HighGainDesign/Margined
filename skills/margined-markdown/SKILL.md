---
name: margined-markdown
description: Use when creating or updating Markdown intended for Margined, including checkable testing documents, agent handoffs, passage discussions, replies, images, math, and Mermaid.
---

# Margined Markdown

Produce ordinary, portable `.md` files. Margined renders Markdown with Apex and stores optional discussions inside the same file. No account, sidecar, or special filename is required.

Verified against Margined 2.0 internal Build 13, source `9de60d5`, on 2026-10-31. Discussions are a 2.0 feature; do not assume stable 1.7.1 supports them.

## Authoring contract

- Save UTF-8 Markdown to the requested location; return a usable file link. When the user wants to test or review, give them an actual file, not just a checklist in chat.
- Use descriptive headings, ordinary links, fenced code, GFM tables with an explicit header separator, and `- [ ]` / `- [x]` tasks. Make each task independently checkable with an observable expected result.
- Keep each task's content to one paragraph. Nested fenced commands currently prevent safe checkbox mapping too; put longer examples in top-level fenced blocks outside the list and refer to them from a task.
- Keep prose outside code blocks. Four-space/tab indentation can turn prose into code; `**bold**` inside code is literal. Use fences for commands and backticks for short code.
- Preserve existing checkmarks, discussion blocks, IDs, messages, unknown fields, and unrelated prose when updating an existing document. Re-read the latest file before writing so user ticks and comments are not overwritten by a stale draft. Prefer small edits over rewriting the whole document.

## Current checklist workaround

Adjacent checklist items containing inline-code pipes can disable every checkbox in affected builds. **Blank lines alone do not fix this.** Separate such items with an ordinary HTML comment:

```markdown
- [ ] Verify `echo a | cat` prints a.

<!-- separate pipeline examples -->

- [ ] Verify `echo b | cat` prints b.
```

This is an Apex parser defect, not invalid Markdown or a Dropbox permission issue: [Margined #22](https://github.com/HighGainDesign/Margined/issues/22), [Apex #37](https://github.com/ApexMarkdown/apex/issues/37). Keep the workaround until the target reader is confirmed fixed. Do not weaken checkbox source mapping.

## Images and richer content

| Content | Authoring guidance |
|---|---|
| Local images | Use relative paths and meaningful alt text. Keep the document and assets under one portable project folder; multiple subdirectories are fine. For explicit sizing use `<img src="images/demo.png" alt="Description" width="320">`. |
| Folder access | iOS and sandboxed Mac TestFlight require a user-selected containing folder. Subfolders are included; multiple grants are supported. The Mac DMG uses normal macOS file access. Remote-image consent does not grant local-folder access. |
| Remote images | HTTPS images need the current document's opt-in; Quick Look stays offline. Prefer local assets for offline reading and privacy. |
| Math | Use `$x^2$` inline or standalone `$$` lines around display TeX. Bundled KaTeX has limits; provide readable surrounding prose. |
| Diagrams | Use a fenced `mermaid` block. Keep diagrams self-contained; no remote scripts or renderer plugins. |
| HTML | A sanitized subset supports image dimensions, formatting and `<details><summary>…</summary>…</details>`. Scripts, active embeds, arbitrary CSS, plugins and file includes are unavailable. Full GitHub parity is not promised. |

Documents are limited to 8 MB; math to 200 expressions/16 KB each; Mermaid to 20 diagrams/20 KB each. Avoid giant tables or images when a readable smaller representation suffices.

## Discussions and feedback

When creating, replying to, resolving, or moving a discussion, read [references/discussions.md](references/discussions.md). Use its exact `margined:thread v1` format. An ordinary HTML comment hides text but **does not create a Margined discussion**. The [example document](assets/review-example.md) is a seed; generate fresh IDs and timestamps for new threads.

Checkbox ticks save task state to the file. Change-review acknowledgments are not a portable approval record; use tasks or discussion replies when an agent must see the decision.

## Maintenance

When a Margined change affects authoring, update this skill in the same work session. Read [references/maintenance.md](references/maintenance.md) for authoritative source files and verification. Record verified behavior separately from proposed features; preserve compatibility guidance for readers still on older builds.
