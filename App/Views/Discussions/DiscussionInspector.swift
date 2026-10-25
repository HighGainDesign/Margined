import AppKit
import SwiftUI

struct DiscussionInspector: View {
    @Bindable var reader: ReaderState
    var aligned = false
    @State private var frames: [String: CGRect] = [:]

    private enum Item: Identifiable {
        case thread(DiscussionThread), draft(UUID)
        var id: String {
            switch self { case .thread(let thread): "t:" + thread.id; case .draft(let id): "d:" + id.uuidString }
        }
    }
    private var threads: [DiscussionThread] { reader.inspectorDiscussionThreads }
    private var items: [Item] {
        let drafts = reader.discussions.drafts.keys.compactMap { key -> UUID? in if case let .new(id) = key { id } else { nil } }
            .sorted { $0.uuidString < $1.uuidString }.map(Item.draft)
        return drafts + threads.map(Item.thread)
    }
    private var anchorTops: [String: Double] {
        guard aligned else { return [:] }
        var values = Dictionary(uniqueKeysWithValues: (reader.discussionMargin?.anchors ?? []).map { ("t:" + $0.id, $0.top * reader.zoom) })
        for item in items { if case .draft = item { values[item.id] = -1_000_000_000 } }
        return values
    }
    var body: some View {
        let entries = items
        let indexed = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Discussions", systemImage: "bubble.left.and.bubble.right").font(.headline)
                Spacer()
                Button { reader.selectNextDiscussion(backwards: true) } label: { Image(systemName: "chevron.up") }
                    .buttonStyle(.borderless).accessibilityLabel("Previous discussion").help("Previous discussion")
                    .disabled(reader.isRendering || reader.filteredDiscussionThreads.isEmpty)
                Button { reader.selectNextDiscussion() } label: { Image(systemName: "chevron.down") }
                    .buttonStyle(.borderless).accessibilityLabel("Next discussion").help("Next discussion")
                    .disabled(reader.isRendering || reader.filteredDiscussionThreads.isEmpty)
                Button { reader.showDiscussions = false } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless).accessibilityLabel("Hide discussions")
                    .keyboardShortcut(reader.showFind ? nil : KeyboardShortcut(.escape, modifiers: []))
            }
            Picker("Show discussions", selection: Binding(get: { reader.discussions.filter }, set: { reader.discussions.filter = $0 })) {
                Text("Open").tag(DiscussionSession.Filter.open)
                Text("All").tag(DiscussionSession.Filter.all)
                Text("Resolved").tag(DiscussionSession.Filter.resolved)
                Text("Unattached").tag(DiscussionSession.Filter.unattached)
            }.labelsHidden()
            Menu("Document Actions", systemImage: "ellipsis.circle") {
                Button("Review Another Copy…") { reader.chooseDiscussionCopy() }
                    .disabled(reader.fileURL == nil || reader.isStreamingPreview || reader.hasPendingFileUpdate)
                Button("Save Markdown Copy…") { reader.saveDiscussionCopy() }
                Button("Export Clean Copy…") { reader.exportDiscussions(.clean) }
                Button("Export Conversations…") { reader.exportDiscussions(.conversation) }
                Divider()
                Button("Show Markdown Source…") { reader.inspectDiscussionSource() }
            }.disabled(reader.fileSaving || reader.isRendering || reader.discussionImportLoading)
            if reader.discussionImportLoading { ProgressView("Reading discussions…").controlSize(.small) }
            if reader.discussionCopySaving { ProgressView("Saving copy…").controlSize(.small) }
            if let exported = reader.discussionExportedURL {
                Label("Exported \(exported.lastPathComponent)", systemImage: "checkmark.circle")
                    .font(.callout).fixedSize(horizontal: false, vertical: true)
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([exported]) }.buttonStyle(.link)
            }
            Button("Add Discussion from Selection", systemImage: "plus.bubble") { reader.requestAddDiscussion() }
                .disabled(reader.isRendering || reader.fileSaving)
            if reader.showDiscussionAuthorPrompt { DiscussionAuthorForm(reader: reader) }
            else {
                Button("Change Comment Name…", systemImage: "person.crop.circle") { reader.requestChangeDiscussionAuthor() }
                    .buttonStyle(.link)
            }
            DiscussionActionPrompts(reader: reader)
            if reader.discussionCopyOffered {
                Button("Save Markdown Copy…", systemImage: "doc.badge.plus") { reader.saveDiscussionCopy() }
                    .buttonStyle(.borderedProminent).disabled(reader.fileSaving || reader.isRendering)
            }
            if let error = reader.discussionError {
                Label(error, systemImage: "exclamationmark.triangle").font(.callout)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                Button("Inspect Source…") { reader.inspectDiscussionSource() }.buttonStyle(.link)
            }
            // Web anchors use viewport coordinates; subtract the fixed controls in this layout pass.
            GeometryReader { bodyGeometry in
                let positions = DiscussionMarginLayout.cards(ids: entries.map(\.id), anchorTops: anchorTops,
                    heights: frames.mapValues { Double($0.height) },
                    topInset: aligned ? bodyGeometry.frame(in: .named("discussion-margin")).minY : 0)
                ScrollViewReader { scroll in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(positions.enumerated()), id: \.element.id) { index, position in
                                let previous = index > 0 ? positions[index - 1] : nil
                                let priorBottom = previous.map { $0.top + Double(frames[$0.id]?.height ?? 100) } ?? 0
                                Color.clear.frame(height: max(0, position.top - priorBottom)).accessibilityHidden(true)
                                if let item = indexed[position.id] {
                                    itemView(item).id(item.id)
                                        .background(GeometryReader { proxy in
                                            Color.clear.preference(key: DiscussionCardFrames.self, value: [item.id: proxy.frame(in: .named("discussion-margin"))])
                                        })
                                }
                            }
                            if entries.isEmpty {
                                Text("Select a passage to start a discussion. Comments and replies stay in this Markdown file.")
                                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            }
                            if let diagnostics = reader.rendered?.discussions?.diagnostics, !diagnostics.isEmpty {
                                VStack(alignment: .leading, spacing: 6) {
                                    Label("Some discussions are unavailable", systemImage: "exclamationmark.bubble")
                                    ForEach(Array(diagnostics.enumerated()), id: \.offset) { _, item in
                                        Text("Line \(item.line): \(item.message)").font(.caption)
                                    }
                                }.textSelection(.enabled).padding(.top, 14)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .task(id: reader.discussionComposerFocusGeneration) {
                        guard reader.discussionComposerFocusGeneration > 0, case let .new(id) = reader.discussions.selection else { return }
                        scroll.scrollTo("d:" + id.uuidString, anchor: .top)
                    }
                    .task(id: reader.discussionCardFocusGeneration) {
                        guard reader.discussionCardFocusGeneration > 0,
                              reader.discussionCardFocusIntent == reader.focusIntentGeneration,
                              case let .thread(id) = reader.discussions.selection else { return }
                        let intent = reader.focusIntentGeneration
                        await Task.yield()
                        guard !Task.isCancelled, intent == reader.focusIntentGeneration else { return }
                        scroll.scrollTo("t:" + id, anchor: .top)
                    }
                }
            }
        }
        .font(.callout).padding(16).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .coordinateSpace(name: "discussion-margin")
        .onPreferenceChange(DiscussionCardFrames.self) {
            frames = $0
            #if MARGINED_BENCHMARK
            ViewingBenchmarkSession.current?.didLayoutDiscussions(reader: reader, frames: $0)
            #endif
        }
        .overlay { DiscussionConnectors(reader: reader, frames: frames, aligned: aligned) }
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: Text("Add Discussion")) { reader.requestAddDiscussion() }
        .accessibilityAction(named: Text("Next Discussion")) { reader.selectNextDiscussion() }
        .accessibilityAction(named: Text("Previous Discussion")) { reader.selectNextDiscussion(backwards: true) }
    }
    @ViewBuilder private func itemView(_ item: Item) -> some View {
        switch item {
        case .thread(let thread): DiscussionThreadCard(reader: reader, thread: thread)
        case .draft(let id):
            let key = DiscussionSession.DraftKey.new(id)
            if let draft = reader.discussions.drafts[key] {
                VStack(alignment: .leading, spacing: 12) {
                    Button {
                        reader.discussions.selection = key
                    } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("Unposted discussion").font(.headline)
                            if let target = draft.target { Text(verbatim: target.exact).lineLimit(3).foregroundStyle(.secondary) }
                        }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                    if reader.discussions.selection == key { DiscussionComposer(reader: reader, key: key, isReply: false) }
                }.padding(14).background(.background, in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }
}

private struct DiscussionCardFrames: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) { value.merge(nextValue(), uniquingKeysWith: { _, new in new }) }
}
