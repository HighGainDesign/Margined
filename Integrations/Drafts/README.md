# Preview in MDView

The action is bundled inside MDView. If Drafts is installed, MDView offers to install it once at startup. You can also open **MDView → Settings… → Install Drafts Action…** at any time. This opens Drafts’ import dialog so you choose where to put the action. Dragging MDView into Applications does not automatically change Drafts.

The bundled action has one macOS URL step, URL-encoded tags, and **Do Nothing** after success. It does not archive, trash, flag, tag, or save the source draft. The export is `Preview in MDView.draftsAction` in this folder.

The simplest Drafts action uses one **URL** step. On macOS:

1. Create an action called **Preview in MDView**.
2. Add a URL step with this template:

   ```text
   mdview://preview?text=[[draft]]&title=[[title]]
   ```

3. Keep **URL encode tags** enabled, **Open in Drafts** disabled, and the step enabled on macOS.
4. Set the action’s iOS visibility off until an iOS MDView app is available.
5. Launch MDView once, then run the action on a draft.

The action sends a snapshot to MDView without writing a file. Run it again after editing. File-backed documents refresh automatically; Drafts snapshots do not. Large drafts may exceed the practical limit of macOS URL handoff; export those as Markdown files and open them instead.

`Preview in MDView.js` is an equivalent Script-step alternative. Use one approach per action.

The iOS development build supports the same snapshot URL. Enable the URL step on
iOS when testing it. Live streaming remains a Mac feature.

Drafts’ [URL step documentation](https://docs.getdrafts.com/docs/actions/steps/advanced) explains URL-encoded template tags.

## Live preview

For previews that follow typing, enable **Marked streaming preview** in **Drafts
Settings → General**. Drafts may require Marked to be installed to expose the
option; Marked can stay closed and no upgrade is needed. Then choose **File →
Live Streaming Preview** in MDView. The welcome window and Settings offer the same
command.

To open the live window from Drafts, create an additional macOS-only URL action
with `mdview://stream`, **Open in Drafts** off, and **Do Nothing** after success.
This starts or resumes one live window rather than creating a new snapshot.
The existing bundled **Preview in MDView** action remains a snapshot action.

The preview follows Drafts’ active editor through its Marked-compatible named
clipboard. **Pause** freezes the preview; **Resume** catches up. Only the named
stream is read, not your ordinary clipboard; MDView never writes to either.
Closing the live window stops reading. No draft is modified and no temporary
Markdown file is created. Live previews do not accumulate saved-change highlights
because the stream can switch between drafts and has no stable draft identifier.
