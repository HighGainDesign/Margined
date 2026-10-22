// Drafts action: add one Script step with this content. No draft is saved to disk.
const url = "mdview://preview?title=" + encodeURIComponent(draft.displayTitle) +
    "&text=" + encodeURIComponent(draft.content);
if (!app.openURL(url)) {
    context.fail("Could not open MDView. Launch MDView once to register its URL scheme.");
}
