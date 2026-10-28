import AppKit
import SwiftUI

struct DiscussionThreadCard: View {
    let reader: ReaderState
    let thread: DiscussionThread
    var revealComposer: () -> Void = {}
    @FocusState private var headerFocused: Bool
    @AccessibilityFocusState private var accessibleHeaderFocused: Bool
    private var selected: Bool { reader.discussions.selection == .thread(thread.id) }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button { reader.openDiscussion(thread.id) } label: {
                HStack(alignment: .top) {
                    Image(systemName: thread.state == .resolved ? "checkmark.bubble" : "bubble.left")
                    VStack(alignment: .leading, spacing: 4) {
                        Text(thread.messages.first?.author ?? "").fontWeight(.semibold)
                        Text(thread.target.exact).lineLimit(selected ? 3 : 2)
                        Text("\(thread.messages.count) messages").font(.caption).foregroundStyle(.secondary)
                        if reader.discussions.drafts[.thread(thread.id)]?.body.isEmpty == false { Text("Draft").font(.caption.weight(.medium)) }
                    }
                    Spacer(minLength: 0)
                    if !selected { Image(systemName: "chevron.right") }
                }.foregroundStyle(.primary).frame(maxWidth: .infinity, alignment: .leading)
            }.buttonStyle(.plain)
                .focusable(interactions: .automatic)
                .focused($headerFocused).accessibilityFocused($accessibleHeaderFocused)
                .accessibilityIdentifier("discussion-thread-" + thread.id)
                .accessibilityHint("Opens the conversation without moving the document.")
                .task(id: reader.discussionCardFocusGeneration) {
                    guard reader.discussionCardFocusGeneration > 0, selected,
                          reader.discussionCardFocusIntent == reader.focusIntentGeneration else { return }
                    let intent = reader.focusIntentGeneration
                    await Task.yield()
                    guard !Task.isCancelled, intent == reader.focusIntentGeneration, selected else { return }
                    headerFocused = true
                    if reader.announcements.isEligible() { accessibleHeaderFocused = true }
                }
            if !reader.filteredDiscussionThreads.contains(where: { $0.id == thread.id }),
               reader.discussions.drafts[.thread(thread.id)]?.body.isEmpty == false {
                Text("Unposted reply outside this filter").font(.caption).foregroundStyle(.secondary)
            }
            if selected {
                HStack {
                    if thread.state == .open {
                        Button("Resolve", systemImage: "checkmark.bubble") { reader.requestResolveDiscussion(thread.id) }
                    } else {
                        Button("Reopen", systemImage: "arrow.uturn.backward") { reader.reopenDiscussion(thread.id) }
                    }
                    Spacer()
                }.disabled(reader.fileSaving || reader.isRendering)
                if reader.rendered?.discussionText?.anchorResults[thread.id]?.status == .attached {
                    Button("Go to Passage", systemImage: "arrow.up.forward") { reader.goToDiscussion(thread.id) }
                } else { Label("Passage needs attention", systemImage: "link.badge.plus").font(.caption) }
                Button("Reattach to Selection…", systemImage: "link") { reader.requestReattachDiscussion(thread.id) }
                    .disabled(reader.fileSaving || reader.isRendering)
                    .help("Select replacement text in the document, then compare the old and new passages before attaching.")
                history
                if thread.state == .resolved { Label("Resolved", systemImage: "checkmark.circle").font(.caption) }
                DiscussionComposer(reader: reader, key: .thread(thread.id), isReply: true, reveal: revealComposer)
            }
        }
        .padding(14).background(.background, in: RoundedRectangle(cornerRadius: 10))
        .overlay(alignment: .leading) {
            if selected { RoundedRectangle(cornerRadius: 2).fill(.tint).frame(width: 3).padding(.vertical, 10) }
        }
    }
    private var history: some View {
        let context = reader.currentDiscussionVersion.context, speech = reader.existingSpeech
        return DiscussionHistoryView(documentID: context, thread: thread, fileURL: reader.fileURL,
            appearance: reader.documentAppearance, loadRemoteImages: reader.loadRemoteImages,
            zoom: reader.zoom, imageGeneration: reader.imageReloadGeneration,
            documentLanguage: reader.documentLanguageOverride,
            isCurrent: { reader.currentDiscussionVersion.context == context && reader.showDiscussions &&
                reader.discussions.selection == .thread(thread.id) &&
                reader.rendered?.discussions?.threads.contains(where: { $0.id == thread.id }) == true },
            imageFailed: { reader.localImageError = $0 },
            openFile: { url in
                NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, error in
                    if let error { NSApp.presentError(error) }
                }
            }, playback: DiscussionHistoryPlayback(session: speech?.session,
                options: speech?.preferences.options ?? SpeechPreferences.shared.options,
                conversationID: speech?.conversationID,
                enabled: !reader.isRendering && !reader.fileSaving && !reader.showChecklistConfirmation,
                pendingVersion: reader.hasPendingFileUpdate, preparing: speech?.isPreparing ?? false,
                read: { reader.readConversation(thread: thread, document: $0, context: context) },
                toggle: {
                    guard reader.existingSpeech?.conversationID == thread.id, reader.existingSpeech?.session.isActive == true else { return }
                    reader.speech.togglePlayback()
                }, stop: {
                    guard reader.existingSpeech?.conversationID == thread.id else { return }
                    reader.speech.stop()
                }, resumeDocument: {
                    guard reader.existingSpeech?.conversationID == thread.id else { return }
                    reader.speech.resumeSaved()
                }, showLatest: { reader.speech.showLatest() }))
    }
}
