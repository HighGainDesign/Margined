# Reviewing an agent’s update

Keep this file open while another app changes it. Margined refreshes the preview and keeps changes highlighted until you mark them reviewed.

## Rollout sequence

| Phase | Owner | Work | Completion condition |
|---|---|---|---|
| Build the platform | Sysop | Stand up the gateway, portal, catalog, and status pages. | Portal works on the private network and existing routes remain stable. |
| Add files | Sysop and user | Trial a read-only document viewer for Markdown, HTML, and PDF. | Tables remain readable and document previews work on the intended devices. |
| Stabilize workflow | Agent | Preserve settings and provide repeatable setup instructions. | Restarting services keeps the workflow working. |
| Publish package | User | Test the signed DMG before publishing. | The icon, outline, and saved-change highlights are approved. |

## Decisions

The release is **ready for testing** and includes [documentation](https://example.com/docs).

## Next steps

- [x] Review the updated preview.
- [ ] Mark changes reviewed when you are finished.

A new note: GitHub publication waits for user approval.
