# Margined demo assets

The video, basic viewer and outline assets show Margined 1.1.0/build13.
The change-review screenshot shows the docked sidebar in 1.2.0/build22; its
layout is also used in the final 1.2 release.

- `live-streaming.mp4`: 24.9-second silent H.264 demo, 1920×1080 at 30 fps.
- `live-streaming.gif`: looping 960×540 README preview at 20 fps.
- `live-streaming-poster.jpg`: still from the table-rendering portion of the video.
- `viewer.jpg`: the basic viewer with tables, lists, and a checklist.
- `outline-sidebar.jpg`: persistent heading navigation.
- `change-review.jpg`: four saved changes in a docked sidebar, before/after
  comparison, and **Mark This Reviewed** and **Mark All Reviewed** buttons.

All three are actual native-window JPEG captures. The viewer and outline are
1840×1584; the change-review capture is 2000×1424. The pointer is absent.
The change-review title bar includes macOS’s remote-control indicator. The
captures use an original, disposable sample document;
no personal files, draft lists, or actions appear. No UI was fabricated.

The video uses simultaneous, continuous recordings of the actual Drafts and
Margined windows through Apple ScreenCaptureKit. Idle intervals were trimmed;
window crops and explanatory labels were added. It demonstrates typing,
Markdown table rendering, Pause while writing, and Resume catching up. Timing
is illustrative rather than a latency benchmark. The pointer and audio are
excluded. The editor shows only an original disposable sample: no private
draft lists, actions, or other windows appear. This replaces the rejected
edited-still demo.

Drafts is the tested streaming integration. Other publishers using the public
Marked-compatible channel are accepted but have not been manually verified.
Drafts may require Marked to be installed to enable streaming; Marked can stay
closed. Margined is not affiliated with Marked or Drafts.

## Suggested launch copy

> I made Margined: a small Markdown viewer for macOS, read-only by default. Keep it beside
> Drafts for live streaming, open documents from your coding agent, or press Space
> in Finder for Quick Look. Saved files refresh automatically, with highlights
> and a comparison panel. Review changes individually or all at once without
> modifying the Markdown file.
>
> Free and open source: https://github.com/HighGainDesign/Margined

No posts, uploads, or messages have been sent to social channels.
