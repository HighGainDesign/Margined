# Margined

A native Markdown reader for Mac, iPhone and iPad, with live updates, change
review, checklists, Read Aloud and portable passage discussions. Documents stay
ordinary `.md` files that people and agents can use in their own tools.

**2.0 is an early Mac beta.** [Download the beta](https://github.com/HighGainDesign/Margined/releases/tag/v2.0-beta.2)
to try passage discussions alongside the established reading, Quick Look, live
streaming and change-review features. Discussions remain experimental; compact layouts still need refinement.
Build 12 is available for testing; hands-on acceptance testing is incomplete. iPhone/iPad TestFlight testing remains invitation-only.
Join the [public Mac TestFlight beta](https://testflight.apple.com/join/CDxY24jy).

## Install and open

For the stable Mac version, download the DMG from the [latest release](https://github.com/HighGainDesign/Margined/releases/latest),
drag Margined to **Applications**, then eject the installer. Quit the app before
replacing it with an update. Requires macOS 14+; the iPhone/iPad app requires iOS 17+.

On Mac, use **File → Open** or Finder’s **Open With → Margined**. On iPhone/iPad,
browse Recents and Files, or use Files **Open With** or **Share → Margined**.
The reader’s **×** returns to the browser, which also offers Settings and
**Take a Tour**. The replayable tour covers Quick Look, live streaming on Mac,
change review, discussions, checklists and image folders using disposable files.

- Tables, task lists, links, footnotes, GitHub alerts, math and Mermaid.
- Outline navigation, find, zoom, full/comfortable width and System/Light/Dark appearance.
- Automatic refresh, including editors that replace files atomically.
- Saved-change review, optional checklist saves and discussions stored in the file.
- On-device Read Aloud; Drafts snapshots and live streaming on Mac.
- English, Spanish, Simplified/Traditional Chinese, Japanese, French and German.

## See it in action

### Read and navigate

Open files from your editor or coding agent. Reading controls stay in the toolbar;
update status and word count stay in the footer. Use the outline sidebar or
**Outline** dropdown to jump to a heading.

![Markdown document with a table and checklist](Assets/Media/viewer.jpg)

![Outline sidebar](Assets/Media/outline-sidebar.jpg)

### See what changed

Saved files refresh while preserving your reading position. **Review Changes**
shows highlighted edits, previous text and deletions beside the document. Use
**Mark This Reviewed** or **Mark All Reviewed** to acknowledge changes without
modifying the file. **Pause Updates** holds the current version; Resume catches up.

![Highlighted changes beside the review sidebar](Assets/Media/change-review.jpg)

### Live streaming

Keep Margined beside Drafts to see headings, lists and tables update as you type.
**Pause** holds the preview; **Resume** catches up. No export or temporary file.

![Drafts typing and Pause/Resume in Margined](Assets/Media/live-streaming.gif)

[Watch the 25-second demo](Assets/Media/live-streaming.mp4). These Mac workflow
captures use the app’s previous MDView name. See [streaming setup](#drafts-and-live-streaming).

## Discuss a passage

Select text and add a discussion. Give replies an author name, resolve or reopen
threads, and explicitly reattach a passage when its text moves or becomes
ambiguous. Wide layouts show discussions and change review in an inspector;
compact layouts open a dedicated view. Unposted replies stay with their discussion.

Saved messages, authors, dates and passage anchors live in bounded HTML comments
containing readable YAML. Other editors can read and edit the same file; ordinary
Markdown previews hide the notes. No account, sidecar or Margined installation is
needed to reply in source. See the [format and complete example](DISCUSSIONS.md).

**Hiding notes does not remove them from a shared file.** Names are labels, not
verified identities. **Share Markdown with Discussions** includes saved notes;
**Export Clean Copy** removes them from a new copy. **Review Another Copy** imports
selected discussion changes, not document prose. Conflicting edits require review.

## Save checkmarks

Clicking a task first asks whether to **Save Checkmarks**. Confirming saves that
tick and enables automatic per-tick saves for this open document. Cancel leaves
the file unchanged. Undo/Redo reverses your ticks; **Stop Saving Checkmarks** stops
future saves and keeps existing progress. Closing the file resets consent.

Only task markers change. Encodings, line endings and permissions are preserved.
If an agent changed the file since the displayed version, the tick is refused and
the file refreshes. External edits clear checkbox Undo history. Unmappable tasks,
Quick Look, snapshots and live streams remain read-only.

## Read Aloud and print

On Mac, **Read Aloud** starts or resumes playback; click again to pause.
The player also offers playback from the beginning, current section or selected text.
Pause, stop, skip sections, choose a voice or adjust speed. **Follow Reading**
scrolls without moving keyboard focus. **Read Conversation** includes saved
messages; document language controls pronunciation, not interface language.

Speech uses installed Apple voices on-device, with no account or model service.
Only one document speaks at a time. Incoming updates wait while speech holds the
displayed version; use **Show Latest** or **Read Latest** to switch. Saved positions
use hashes and offsets, never document text. Live streams have no saved position.

Use **Print…** for the rendered document, or **Print with Discussions…** for a
read-only notes appendix. On Mac, **File → Print…** (⌘P) provides **PDF → Save as PDF**.
Print uses a light page, repeating table headers and wrapped code, without app
controls or temporary highlights. Paused documents print the displayed version.

## Images and folder access

The Mac DMG app loads local images wherever macOS permits access. iOS and the
sandboxed Mac TestFlight app need folder access for images beside a document:
opening one file does not grant access to its neighbors.

Choose a parent folder containing the document and its images; subfolders are
included. You can choose a project folder, or all of Dropbox when Files permits
it, and remember multiple folders. Manage or forget grants in Settings. If a
provider is offline, reconnect or download its files before retrying.

Remote images are off by default. **Load Remote Images** opts the current document
into HTTPS image requests; hosts can see your IP address. Margined sends no document
referrer. The choice resets when the document closes. Quick Look stays offline.

Authors can size images using GitHub-style HTML; printing adds no arbitrary cap:

```html
<img src="images/screenshot.png" alt="Settings screen" width="320">
```

## Quick Look

The extension is bundled with the app. On Mac, launch Margined once, then enable
it from **Settings → Open Extension Settings… → Quick Look**. Finder previews a
selected Markdown file with Space. macOS may choose another enabled Markdown
extension; disable competitors if you want Margined’s preview.

On iOS 27 and some earlier versions, Files currently shows standard Markdown as
plain text instead of dispatching to Margined’s extension. Use **Open With** or
**Share → Margined** for formatted reading. The app’s guide explains this limitation.
Where Quick Look dispatches the extension, it uses the shared offline renderer
and previews the document. Open Margined for discussions; use **Print with
Discussions** or **Export Conversations** to include them explicitly.

## Reading controls and accessibility

Appearance applies to documents and app controls. Settings also chooses the
opening width default. The **↔** button changes
only the current document’s width. Tables fill that width and scroll horizontally
when needed. Sidebars adapt to usable space and text size rather than device name
or orientation. Interface language follows the operating system’s per-app setting.

Mac navigation shortcuts:

| Command | Shortcut |
| --- | --- |
| Pause/Resume Updates | ⌥⌘P |
| Focus Document / Return to Navigation | ⌥⌘D / ⌥⌘U |
| Next/Previous Unchecked Task | ⌥⌘J / ⇧⌥⌘J |
| Next/Previous Unreviewed Change | ⌥⌘] / ⌥⌘[ |

Semantic headings, links, tables and task labels support assistive navigation.
The active reader announces errors, missing search results and review progress.
Math includes MathML; Read Aloud reads TeX rather than interpreting spoken math.
Diagrams use authored `accTitle`/`accDescr` when available. Accessibility feedback
is welcome; full assistive-technology coverage is not claimed.

## Drafts and live streaming

Install the optional [Drafts action](Integrations/Drafts/README.md) from Mac Settings.
URL snapshots use `margined://preview?text=URL_ENCODED_MARKDOWN&title=URL_ENCODED_TITLE`.

For live typing, enable **Marked streaming preview** in **Drafts Settings → General**,
then choose **File → Live Streaming Preview** in Margined. Drafts may require Marked
to be installed to enable its stream; Marked can stay closed. No upgrade is needed.
Other editors using the channel are accepted; Drafts is the tested integration.

Margined independently implements Brett Terpstra’s public
[Marked streaming protocol](https://markedapp.com/help/Streaming_Preview), reading
only `mkStreamingPreview` while the live window is open and unpaused. It does not
use your ordinary clipboard. Margined is not affiliated with or endorsed by Marked.
The footer shows optional source metadata. `margined://stream` reuses the live window.
Streams follow the active draft, do not accumulate file-review highlights, and
have no folder for resolving relative images.

## Rendering and boundaries

[Apex](https://github.com/ApexMarkdown/apex) 1.1.34 provides native Markdown parsing;
its vendored snapshot includes documented build overlays and table fixes.
[SwiftSoup](https://github.com/scinfu/SwiftSoup) adapts and sanitizes HTML. Bundled
KaTeX produces MathML; Mermaid renders sanitized SVG in a private offline worker.
Ordinary documents do not start that worker. See [dependency provenance](Vendor/Apex/PROVENANCE.md)
and the [rendering sample](Fixtures/Rendering.md).

- Prose editing is outside the current scope; checkmarks and discussion actions are explicit file writes.
- UTF-8 and BOM-marked UTF-16 files are supported, up to 8 MB.
- Safe HTML formatting and disclosure blocks are supported; document scripts, plugins, file includes and active embeds are disabled.
- Limits: 200 math expressions and 20 diagrams, 16 KB per expression and 20 KB per diagram. Invalid or oversized content retains readable source. Full GitHub/MathJax parity is not claimed.
- JSON/YAML viewing and syntax coloring are future work. Performance targets and timing boundaries are in [Benchmarks](Benchmarks/README.md); no completed 2.0 speed claim yet.

## Build, contribute and license

See [Contributing](CONTRIBUTING.md) for Mac/iOS builds, tests, signing and packaging,
[Roadmap](ROADMAP.md) for release acceptance, and [Changelog](CHANGELOG.md) for changes.

Margined uses the [MIT license](LICENSE). See [Security](SECURITY.md) for vulnerability
reports. Apex, libyaml, SwiftSoup, KaTeX and Mermaid use MIT licenses; cmark-gfm
includes BSD-2-Clause and component notices. Dependency licenses are bundled.
The icon incorporates the public-domain [Markdown Mark](https://github.com/dcurtis/markdown-mark);
its editable Icon Composer source is `App/AppIcon.icon`.
