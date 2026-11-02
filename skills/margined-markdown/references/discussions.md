# Portable discussions: `margined:thread v1`

Verified against `Shared/Discussions/DiscussionCodec.swift` at Margined source `9de60d5` (2.0 Build 13). This is Margined's YAML-in-HTML-comment format. It uses the W3C-style TextQuoteSelector concept; it is not W3C JSON-LD, CriticMarkup, or HackMD syntax.

## File shape

Keep the document's ordinary Markdown readable on its own. Append one top-level block per thread at the end of the file, separated from prose/other blocks by a blank line:

```text
<!-- margined:thread v1
YAML payload
-->
```

Both wrapper lines must stand alone at column 1, exactly as shown. Do not indent or place a real thread inside a fence, list, blockquote, YAML frontmatter, or another HTML comment. Ordinary Markdown previews hide the blocks; text editors show editable YAML. Hidden means visually omitted, not encrypted or removed from a shared file.

Use [the complete example](../assets/review-example.md) for the actual payload. It contains one passage, one open thread, two authors, and one linked reply.

## Required fields

| Location | Fields |
|---|---|
| Thread | `id`, `state` (`open` or `resolved`), `target`, nonempty `messages` sequence |
| Target | `type: TextQuoteSelector`, nonempty `exact`, `prefix`, `suffix`; optional `section` |
| Each message | `id`, nonblank `author`, `created`, `body`; optional `in-reply-to` |
| Resolved thread | Also `resolved-by` (nonblank author) and `resolved` (quoted timestamp) |

- Generate new UUIDs for new thread/message IDs. Allowed ID characters are ASCII letters, digits, `.`, `_`, `:`, `-`; 1–128 UTF-8 bytes. Thread IDs must be unique across threads; message IDs must be unique across the entire document. Reusing the same quoted passage for another independent thread is fine; reusing IDs is not.
- Quote timestamps as RFC 3339 strings with timezone, such as `"2026-10-31T18:00:00Z"`. Use the actual creation time for new messages. Preserve existing authors and times; do not invent another person's approval or identity. Author labels are not verified identities.
- A reply's `in-reply-to` must identify an **earlier message in the same thread**. Append replies in order. Multiple authors/replies share that thread's one `messages` array.
- A message body is a YAML string. Use a double-quoted, JSON-compatible string for predictable escaping, or `body: |-` with correctly indented content for multiline Markdown. Literal `\n` inside a block scalar is not a newline.
- Use plain mappings/sequences/scalars. No YAML anchors, aliases, merge keys, directives, custom tags, or duplicate keys. Do not serialize language-specific objects.

## Passage anchors

`exact` is the **rendered passage text**, not Markdown syntax, HTML, file byte offsets, or a heading slug. For `**Review the scope**`, use `Review the scope`. Margined normalizes Unicode to NFC and collapses whitespace for matching.

`prefix` and `suffix` are the immediate surrounding rendered text used to disambiguate repeated passages; both fields are required but may be empty strings for a unique passage. For a new thread, choose a distinctive, contiguous quote and copy real context. Prefer a short selection within one paragraph. Do not invent context or assume `section` alone identifies a passage.

If the quoted passage changes, preserve the old selector and let Margined show that it needs attention. Deliberate reattachment replaces `target` and appends the old target to `attachment-history` with `author` and quoted `created`. Preserve existing history and unknown fields. Do not silently retarget someone else's discussion to make a match look successful.

## Protect the HTML wrapper

YAML quoting alone does not protect an enclosing HTML comment. A value containing literal `<!--`, `-->`, or `--!>` can break the wrapper. For that value, use a **double-quoted YAML scalar** and encode `<` as `\u003c` and `>` as `\u003e`, along with normal quote/backslash/newline escapes. For example:

```yaml
body: "Keep the literal \u003c!-- note --\u003e in this example."
```

Do not put raw comment delimiters inside a block-scalar body. This also applies to selector text, author names and unknown string fields.

## Updating an existing file

Read the current file first. Add the requested reply or state change without rewriting other messages, IDs, timestamps, selectors, unknown fields, or ordinary comments. Preserve file encoding/newline conventions when modifying it. An agent may add its own reply under its stated name; a request to inspect a document is not permission to resolve a conversation or assert another author's agreement.

For resolution, set `state: resolved` and add `resolved-by` plus `resolved`. For reopening, set `state: open` and remove those two resolution fields; preserve all messages/history. Leave malformed or future-version blocks intact and report the problem instead of repairing or dropping them speculatively.

Verify with the actual Margined codec when available: zero diagnostics, expected thread/message counts and reply relationships. Otherwise report that the format was checked against this reference, not that it was tested in the app. A generic YAML parser cannot certify Margined anchors, global ID uniqueness, or checkbox mapping.
