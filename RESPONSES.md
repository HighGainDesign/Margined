# Markdown responses

Margined 2.0 Build 17 and later recognize two optional conventions in ordinary Markdown. Earlier builds still display the document, but their checkboxes are independent and they have no answer editor. Confirm the recipient's build before relying on these controls.

## Choose one

```markdown
**Result (choose one):**

- [ ] Accepted
- [x] Changes required
- [ ] Not tested
```

Use the exact, case-sensitive suffix ` (choose one):` inside a bold literal label. The label must be its own top-level paragraph, immediately followed by a top-level unordered task list with at least two items. Blank lines are allowed. Every item must be a task; nested lists, quotes, intervening blocks and mixed ordinary/task lists do not opt in. Each group is independent, even when labels repeat.

Choosing an option clears the other checks in that group with one file edit and one Undo. Clicking the sole selected option clears the answer. If several options were checked in another editor, Margined shows a conflict and leaves the file alone until you choose an option. Clicking any option in that conflict selects it alone; Undo restores the original markers. Ordinary checklists keep their existing behavior.

Checkbox saving uses the existing per-file consent. Saving a text answer does not turn on automatic checkbox saving.

## Short answer

```markdown
**Device and OS (short answer):** _Not answered_

**Notes (short answer):** The Save button was difficult to reach.
```

Use the exact suffix ` (short answer):` inside a bold literal label, followed by one space and the answer. The entire field must occupy one top-level paragraph on one physical source line. Use the exact `_Not answered_` placeholder for an empty field. Quoted, nested, multiline and code-block lookalikes stay ordinary content.

**Edit answer** opens a focused native editor. Save accepts up to 1,000 characters in one paragraph, trims surrounding whitespace and escapes Markdown punctuation so your replacement remains literal text. Line breaks and non-tab control characters are rejected. Empty Save restores the placeholder. Cancel leaves the file unchanged. Typing Undo belongs to the editor; after saving, file Undo restores the whole prior answer.

An existing answer may contain inline formatting. Saving it unchanged preserves its original source exactly, including formatting and imported answers above the limit. A changed answer is saved as plain text; oversized imported text is never silently truncated.

If the underlying file changes, Margined refuses a stale save and retains your draft for copying. Close the editor and reopen the field in the current file before saving again. Saving preserves unrelated prose, checks, discussions, encoding and line endings.

## Other views and authoring

Quick Look, read-only previews, Read Aloud and printed output retain the readable answers. The answer editor and app-generated conflict warnings are reading-app controls; they are not written into Markdown or included in speech or print.

Keep questions readable in any Markdown editor. There is no hidden form schema or script to install. See the [working authoring example](skills/margined-markdown/assets/responses-example.md) and the [maintained authoring skill](skills/margined-markdown/SKILL.md). Existing Margined [discussions](DISCUSSIONS.md) remain independent of responses.
