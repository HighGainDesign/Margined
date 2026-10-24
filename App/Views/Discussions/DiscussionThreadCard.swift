import SwiftUI

struct DiscussionThreadCard: View {
    let reader: ReaderState
    let thread: DiscussionThread
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
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(thread.messages, id: \.id) { message in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(message.author).fontWeight(.semibold)
                                Text(verbatim: message.body).textSelection(.enabled)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }.frame(maxHeight: 240)
                if thread.state == .resolved { Label("Resolved", systemImage: "checkmark.circle").font(.caption) }
                DiscussionComposer(reader: reader, key: .thread(thread.id), isReply: true)
            }
        }
        .padding(14).background(.background, in: RoundedRectangle(cornerRadius: 10))
        .overlay(alignment: .leading) {
            if selected { RoundedRectangle(cornerRadius: 2).fill(.tint).frame(width: 3).padding(.vertical, 10) }
        }
    }
}
