# MDView roadmap

Last updated: October 22, 2026.

MDView should remain a fast Markdown reader with focused integrations. Additions
should make reading, following updates and reviewing documents easier without
turning the app into a general Markdown editor. Saving checklist markers is the
deliberate exception to read-only viewing.

**1.7** adds GitHub alerts, offline math and Mermaid, with a bounded Mac readiness
pass. Version 1.6 added printing and safe HTML/image sizing. An iOS MVP is in development
for 2.0; later milestones are plans, not delivery dates.

| Release | Focus | Planned outcome |
| --- | --- | --- |
| **1.2 — released** | Checklists and bounded accessibility fixes | Save ticks with first-click consent and Undo; clearer controls, task names and focus. |
| **1.3 — released** | Accessible navigation and reliable updates | Preserve reading position, pause file updates, useful announcements, better change review and faster navigation. Prepare localization. |
| **1.5 — released** | Read Aloud, native UX polish and localization | On-device Markdown playback, a coherent native interface and initial translations. |
| **1.6 — released** | Printing and Markdown compatibility | Native printing/PDF export, compact paper layout and authored HTML image dimensions. |
| **1.7** | Mac compatibility and readiness | GitHub alerts, offline math/Mermaid, consistent static output and reproducible builds. |
| **2.0** | macOS and iOS | Shared reading and speech capabilities with native file handling and a mobile listening experience. |

## Mac readiness

Prioritize a dependable Mac app for broader adoption before starting the iOS app.
This milestone is about predictable everyday use, not supporting every Markdown
extension or adding general editing.

- Alert callouts, KaTeX math and Mermaid are implemented locally, with offline
  rendering, readable fallback and bounded work. Native reader, Quick Look and
  print checks pass; broader GitHub parity remains an ongoing compatibility target.
- Verify a representative document set: tables, tasks, links, authored image sizes,
  disclosure blocks, long files and printed/PDF output.
- Check complete workflows: opening files and Quick Look, live streaming,
  refresh/pause/resume, change review, checklist saves/Undo and Read Aloud.
- Address reproducible crashes, slowdowns, keyboard/focus issues, VoiceOver gaps
  and translation/layout defects found in those checks. Distinguish automated
  checks from actual spoken accessibility acceptance.
- Keep installation, setup and brief documentation clear; resolve the local
  Xcode 27 dependency-build issue. The unchanged pinned Apex sources are now
  included locally with provenance and hash verification.

The bounded pass covers these workflows; compatibility fixes continue alongside
2.0. The next development goal is an iOS MVP using the shared reader and speech
code with native Files integration.

## 1.2 — checklists

Keep this release focused; do not hold it for the larger accessibility or audio
projects.

- Clicking a mapped file checkbox asks for consent before the first save.
- Confirming saves that first tick; subsequent ticks save automatically for the
  open document. Cancel changes nothing.
- Change only the task marker and preserve the rest of the file. Refuse stale
  writes when another writer changed the document.
- Provide Undo/Redo and a clear **Stop Saving Checkmarks** action. Stopping keeps
  saved progress and asks again before future checkbox saves.
- Keep Quick Look, Drafts snapshots and live streaming read-only.
- Include bounded accessibility fixes already developed: meaningful task names,
  checked-state semantics, focus restoration, larger targets, outline levels,
  clearer help and reduced-motion scrolling.

Released on October 14, 2026 after local acceptance testing, automated checks and
the signed/notarized release workflow. This release also adds docked change review,
Find focus fixes and normal macOS access to local images without folder grants.
The checklist workflow has passed human-assisted spoken VoiceOver checks; that
does not establish whole-app VoiceOver support.

## 1.3 — accessibility and reading reliability (released)

This release addresses accessibility priorities 1–5 across the reader, rather
than limiting the work to checklists.

1. **Preserve reading position during updates.** Preserve the user's reading
   anchor and VoiceOver cursor where possible. Add Pause Updates/Resume for saved
   files, with a clear indication that newer content is waiting. Live streaming
   already has Pause/Resume.
2. **Make navigation move focus.** Outline jumps and Show in Document should move
   keyboard and VoiceOver focus to the destination, rather than only scrolling.
   Preserve a predictable route back to the control or review panel.
3. **Announce meaningful results.** Convey save failures, conflicts, no search
   matches and newly available changes. Coalesce rapid updates, limit speech to
   the relevant active reader and avoid repeatedly reading an entire document.
4. **Make change review understandable through speech.** Expose change number,
   type and Before/After content. Describe checkbox state and link-target
   differences explicitly. After Mark This Reviewed, move to the next change
   predictably and report the remaining count.
5. **Provide faster navigation.** Add direct access to next/previous unchecked
   tasks and unreviewed changes, and a way to enter the document without stepping
   through every toolbar control. Verify the standard heading, link and table
   rotors before adding custom navigation.

Also consider keeping explicit Undo/Redo available after automatic checkmark
saving stops, while valid history remains. Ordinary checkbox clicks must still
require consent, and external edits must invalidate stale history. This is a
proposed behavior change, not part of the current 1.2 implementation.

### Verification approach

Use automated tests for source safety, paused/latest-content state, DOM focus,
navigation targets, change descriptions and announcement scheduling. Use native
keyboard checks for the complete workflow. These can cover most implementation
work without a spoken test after every small change.

Then run one short, batched VoiceOver pass covering open/read, outline, find,
update/resume, review and checklist workflows, plus Quick Look. Automated focus
and accessibility-tree assertions cannot establish actual reading-cursor
behavior or whether announcements interrupt speech. Follow
[Apple's VoiceOver evaluation criteria](https://developer.apple.com/help/app-store-connect/manage-app-accessibility/voiceover-evaluation-criteria),
and seek an experienced VoiceOver user's feedback before claiming broad support.

## Localization foundations

Keep three concerns separate:

- **Interface localization:** buttons, menus, help, errors, status text, plurals
  and accessibility labels. Use String Catalogs and test longer translations and
  right-to-left layouts.
- **Document language:** Markdown remains the author's content; MDView does not
  translate it automatically. Replace the hardcoded English HTML language with
  an accurate document language when known or selected.
- **Speech language and voice:** choose an available voice suited to the
  document, with a user override and a predictable fallback. Interface language
  must not force every document to use the same speaking language.

Version 1.3 provides the String Catalog, on-device document language detection
and a per-document language override. Version 1.5 adds localized playback controls
and interface translations in this priority order: English, Spanish, Simplified
Chinese, Traditional Chinese, Japanese, French and German.
Correct language metadata matters for pronunciation and assistive technology;
see [W3C's language guidance](https://www.w3.org/WAI/WCAG22/Understanding/language-of-page.html).

## 1.5 — Read Aloud, UX polish and localization

These features ship together in one macOS release.

### Read Aloud

Provide a listening feature that works independently of whether VoiceOver is on.

#### First playback experience

- Play, pause, resume and stop.
- Read from the beginning, current section or a selected starting point.
- Previous/next section, playback speed and available voice selection.
- Highlight the active paragraph and remember a useful resume position.
- Read document structure sensibly: headings, lists, checkbox states and tables.
  Avoid speaking Markdown punctuation, raw URLs or every code block by default;
  make the treatment of links, tables and code explicit.
- Keep the document version being spoken stable. When the file changes, indicate
  that a newer version is available instead of jumping mid-sentence.
- Handle audio interruptions and coexist with VoiceOver announcements.

Reuse the existing parsed/rendered Markdown structure to create speech segments.
Do not introduce a second handwritten Markdown parser. Keep speech preparation
and the playback engine reusable by the future iOS app.

#### Speech engine

Start with **AVSpeechSynthesizer** and the voices exposed by Apple's public APIs.
[Apple documents speech generation as on-device](https://developer.apple.com/documentation/avfoundation/speech-synthesis);
use [the available-voices API](https://developer.apple.com/documentation/avfaudio/avspeechsynthesisvoice/speechvoices())
to discover what each device can actually use. Voice availability and quality
depend on OS, language and installed voice assets. Do not assume that every Siri
or Apple Intelligence voice is available to third-party apps.

[audio.cpp](https://github.com/0xShug0/audio.cpp) is a candidate **optional engine
for open speech models**, not an adapter for Apple's system voices. Keep the
engine boundary replaceable, but evaluate an open-model backend separately:

- Audible quality and pronunciation on representative Markdown documents.
- Startup latency, long-document playback, memory use and battery impact.
- Intel/Apple Silicon behavior and actual iOS library integration.
- Runtime/dependency licensing and the separate licenses of selected model
  weights; see the project's [model-license documentation](https://github.com/0xShug0/audio.cpp/blob/main/docs/model_licenses.md).
- Optional model downloads, storage management and offline operation.

The repository documents desktop platforms; iOS compatibility must be validated.
A large mandatory model download should not become a requirement for ordinary
viewing or basic Read Aloud. Audio export, voice cloning and cloud speech services
are outside the initial playback scope.

### Native UX polish and initial translations

- Establish a consistent native design for document windows, controls, status,
  settings, setup, change review and playback.
- Preserve clear action affordances and quiet status information.
- Improve typography, spacing, hierarchy and narrow-window behavior.
- Make light/dark appearance, increased contrast, keyboard focus and reduced
  motion part of the design rather than later adjustments.
- Use newer system treatments when available while retaining the supported
  macOS baseline and a readable document surface.
- Ship English, Spanish, Simplified Chinese, Traditional Chinese,
  Japanese, French and German interfaces, in that priority order.

“Modern” should improve reading and navigation without adding clutter, excessive
animation, mandatory glass effects or startup overhead. The approved icon remains
the app's visual identity unless a separate change is requested.

## GitHub compatibility

Use GitHub Flavored Markdown as the compatibility target, with regression fixtures
for tables, task lists, autolinks, strikethrough and sanitized HTML/image sizing.
Keep author-controlled dimensions consistent on screen and paper. Alerts, math
and Mermaid now have dedicated regression coverage. This is a practical GitHub
compatibility target; full GitHub/MathJax parity is not claimed.

## 2.0 — macOS and iOS

Begin after the macOS readiness milestone above.

- Share parsing, rendering, speech preparation and suitable reader state while
  keeping platform document/window/audio integration native.
- Provide iOS file opening and appropriate Files/share entry points.
- Carry over outline, find, checklists, change review and Read Aloud where the
  platform supports the workflow.
- Prioritize mobile listening: background playback, headphone and lock-screen
  controls, interruption handling and resume position, verified on real devices.
- Keep accessibility and localization consistent across both platforms.
- Evaluate iOS preview integrations separately. Do not assume Finder Quick Look
  or macOS's live-streaming integration maps directly to iOS.

## Release discipline

Each release should have one clear primary purpose, relevant automated checks,
native acceptance testing and a reviewable installer. Keep speculative engines
and platform expansion out of the 1.2 release. Validate the complete VoiceOver
workflow after accessibility changes and the real mobile audio workflow before
shipping iOS playback. Later milestones may be reordered as testing and user
feedback clarify their value.
