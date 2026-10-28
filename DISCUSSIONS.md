# Portable discussions

Margined stores comments and replies inside the Markdown file. No account,
sidecar or Margined installation is needed to read or edit them in source.
Ordinary Markdown previews hide the notes; Margined displays them beside the
passage. **Hiding discussions does not remove them from a shared file.**

## Reply in another editor

1. Find the thread’s `messages` list in the file’s source.
2. Append a message with a new, file-unique `id`, your `author` name, a quoted
   RFC 3339 `created` date, and a `body`. Use `in-reply-to` to identify an earlier
   message in that thread. Keep the existing IDs and messages.
3. Save and return the `.md` file. If both copies changed, use **Review Another
   Copy** in Margined to review discussion imports. It does not merge document prose.

Names are labels, not verified identities. Anyone who can edit the file can edit
its source. Keep private information out of comments you intend to share.

## Complete example

Copy the contents of this code block into a new `.md` file. The wrapper must be
outside code fences and blockquotes to become a discussion.

```markdown
# Release notes

Keep the document readable in any editor.

<!-- margined:thread v1
id: t-portability
state: open
target:
  type: TextQuoteSelector
  exact: "Keep the document readable in any editor."
  prefix: "Release notes"
  suffix: ""
messages:
  - id: m-question
    author: "Alex"
    created: "2026-10-24T12:00:00Z"
    body: |
      Can another reviewer reply without installing Margined?
  - id: m-answer
    author: "Sam"
    created: "2026-10-24T12:10:00Z"
    in-reply-to: m-question
    body: |
      Yes. Append a message here and send the Markdown file back.
-->
```

For another reply, append this under the same `messages` list, before `-->`.
Replace the ID, name, date, reply ID and body; preserve the indentation.

```yaml
  - id: m-your-unique-reply
    author: "Your name"
    created: "2026-10-24T12:20:00Z"
    in-reply-to: m-answer
    body: |
      Your reply goes here.
      Indent each body line by six spaces.
```

## Preserve the conversation

- The quoted target records the passage being discussed. Editing it by hand does
  not update attachment history; use **Reattach** in Margined to move a discussion.
- **Resolve** retains messages. It does not approve the prose or mark file changes reviewed.
- **Share Markdown with Discussions** keeps saved notes; unposted drafts are excluded.
  **Export Clean Copy** creates another file with bounded discussion blocks removed.
- Body text may use Markdown. Keep literal `<!--` and `-->` out of YAML block
  bodies; Margined uses escaped quoted scalars when saving those sequences.
- Preserve unfamiliar fields and unsupported blocks. An unavailable discussion is
  not an invitation to delete its source.

The passage selector uses W3C Web Annotation concepts. The HTML-comment/YAML
embedding is Margined’s versioned convention, not a W3C Markdown standard.
