import SwiftUI

struct MobileDiscussionList: View {
    @Bindable var reader: MobileReaderState
    var body: some View {
        List {
            Section {
                Picker("Show discussions", selection: Binding(get: { reader.discussions.filter }, set: { reader.discussions.filter = $0 })) {
                    Text("Open").tag(DiscussionSession.Filter.open)
                    Text("All").tag(DiscussionSession.Filter.all)
                    Text("Resolved").tag(DiscussionSession.Filter.resolved)
                    Text("Unattached").tag(DiscussionSession.Filter.unattached)
                }
            }
            ForEach(newDrafts, id: \.self) { key in
                Button {
                    reader.discussions.selection = key; reader.discussionRoute = key
                } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Unposted discussion", systemImage: "square.and.pencil")
                        Text(reader.discussions.drafts[key]?.target?.exact ?? "").lineLimit(3)
                    }
                }
            }
            ForEach(reader.inspectorDiscussionThreads, id: \.id) { thread in
                Button { reader.openDiscussion(thread.id) } label: { MobileDiscussionSummary(reader: reader, thread: thread) }
            }
            if newDrafts.isEmpty && reader.inspectorDiscussionThreads.isEmpty {
                Text("Select a passage to start a discussion. Comments and replies stay in this Markdown file.")
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Discussions").navigationBarTitleDisplayMode(.inline)
    }
    private var newDrafts: [DiscussionSession.DraftKey] {
        reader.discussions.drafts.keys.filter { if case .new = $0 { return true }; return false }
            .sorted { String(describing: $0) < String(describing: $1) }
    }
}

struct MobileDiscussionThread: View {
    @Bindable var reader: MobileReaderState
    let key: DiscussionSession.DraftKey
    private var thread: DiscussionThread? {
        if case let .thread(id) = key { return reader.rendered?.discussions?.threads.first { $0.id == id } }
        return nil
    }
    private var quote: String { thread?.target.exact ?? reader.discussions.drafts[key]?.target?.exact ?? "" }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(verbatim: quote)
                .font(.body).textSelection(.enabled).padding(16)
                .frame(maxWidth: .infinity, alignment: .leading).background(.quaternary)
                .accessibilityLabel(String(localized: "Quoted passage") + ", " + quote)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    if let thread { MobileDiscussionMessages(thread: thread) }
                    if let error = reader.discussionError {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red).textSelection(.enabled)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { MobileDiscussionComposer(reader: reader, key: key).padding(16).background(.bar) }
        .navigationTitle("Discussion").navigationBarTitleDisplayMode(.inline)
    }
}

struct MobileDiscussionSummary: View {
    let reader: MobileReaderState
    let thread: DiscussionThread
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: thread.state == .resolved ? "checkmark.bubble" : "bubble.left")
            VStack(alignment: .leading, spacing: 5) {
                Text(verbatim: thread.messages.first?.author ?? "").fontWeight(.semibold)
                Text(verbatim: thread.target.exact).lineLimit(3)
                Text("\(thread.messages.count) messages").font(.caption).foregroundStyle(.secondary)
                if thread.state == .resolved { Text("Resolved").font(.caption) }
                if reader.discussions.drafts[.thread(thread.id)]?.body.isEmpty == false { Text("Draft").font(.caption) }
                if !reader.filteredDiscussionThreads.contains(where: { $0.id == thread.id }),
                   reader.discussions.drafts[.thread(thread.id)]?.body.isEmpty == false {
                    Text("Unposted reply outside this filter").font(.caption).foregroundStyle(.secondary)
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading).foregroundStyle(.primary)
    }
}

private struct MobileDiscussionMessages: View {
    let thread: DiscussionThread
    var body: some View {
        ForEach(thread.messages, id: \.id) { message in
            VStack(alignment: .leading, spacing: 8) {
                Text(verbatim: message.author).font(.headline)
                Text(verbatim: message.body).textSelection(.enabled)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct MobileDiscussionComposer: View {
    @Bindable var reader: MobileReaderState
    let key: DiscussionSession.DraftKey
    @State private var editingName = false
    private var isReply: Bool { if case .thread = key { return true }; return false }
    private var bodyBinding: Binding<String> {
        Binding(get: { reader.discussions.drafts[key]?.body ?? "" },
                set: { reader.discussions.setDraft($0, for: key) })
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if editingName || reader.discussions.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("This name is saved in the Markdown file. It is not a verified identity.")
                    .font(.caption).foregroundStyle(.secondary)
                TextField("Your name", text: Binding(get: { reader.discussions.displayName }, set: { reader.discussions.displayName = $0 }))
                    .textFieldStyle(.roundedBorder).textInputAutocapitalization(.words).onSubmit { editingName = false }
            } else { Text("Reply as \(reader.discussions.displayName)").font(.caption).foregroundStyle(.secondary) }
            TextEditor(text: bodyBinding).frame(minHeight: 90, maxHeight: 150)
                .padding(5).background(.background, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(.separator))
                .accessibilityLabel(isReply ? "Reply" : "Discussion")
                .accessibilityHint("Command-Return posts. Return starts a new line.")
            HStack {
                Text("Replies are saved in this Markdown file.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(isReply ? "Reply" : "Post") { reader.discussions.selection = key; reader.postDiscussion() }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.return, modifiers: .command)
                    .disabled(reader.fileSaving || reader.isRendering || bodyBinding.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .onAppear { if reader.discussions.displayName.isEmpty { editingName = true } }
    }
}

/// Uses viewport coordinates already scaled by MobileWebTypography. Do not apply zoom twice.
struct MobileDiscussionMargin: View {
    @Bindable var reader: MobileReaderState
    @State private var frames: [String: CGRect] = [:]
    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Label("Discussions", systemImage: "bubble.left.and.bubble.right").font(.headline)
                Spacer()
                Button("Hide discussions", systemImage: "xmark") { reader.hideDiscussions() }.labelStyle(.iconOnly)
            }
            Picker("Show discussions", selection: Binding(get: { reader.discussions.filter }, set: { reader.discussions.filter = $0 })) {
                Text("Open").tag(DiscussionSession.Filter.open)
                Text("All").tag(DiscussionSession.Filter.all)
                Text("Resolved").tag(DiscussionSession.Filter.resolved)
                Text("Unattached").tag(DiscussionSession.Filter.unattached)
            }
            GeometryReader { area in
                let threads = reader.inspectorDiscussionThreads
                let indexed = Dictionary(uniqueKeysWithValues: threads.map { ($0.id, $0) })
                let anchors = Dictionary(uniqueKeysWithValues: (reader.discussionMargin?.anchors ?? []).map { ($0.id, $0.top) })
                let positions = DiscussionMarginLayout.cards(ids: threads.map(\.id), anchorTops: anchors,
                    heights: frames.mapValues { Double($0.height) }, topInset: area.frame(in: .named("mobile-discussion-margin")).minY)
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(positions.enumerated()), id: \.element.id) { index, position in
                            let previous = index > 0 ? positions[index - 1] : nil
                            let bottom = previous.map { $0.top + Double(frames[$0.id]?.height ?? 100) } ?? 0
                            Color.clear.frame(height: max(0, position.top - bottom)).accessibilityHidden(true)
                            if let thread = indexed[position.id] {
                                VStack(alignment: .leading, spacing: 14) {
                                    Button { reader.openDiscussion(thread.id) } label: { MobileDiscussionSummary(reader: reader, thread: thread) }
                                    if reader.discussions.selection == .thread(thread.id) {
                                        ScrollView { VStack(alignment: .leading, spacing: 18) { MobileDiscussionMessages(thread: thread) } }.frame(maxHeight: 240)
                                        MobileDiscussionComposer(reader: reader, key: .thread(thread.id))
                                    }
                                }.padding(14).background(.background, in: RoundedRectangle(cornerRadius: 10))
                                    .background(GeometryReader { proxy in Color.clear.preference(key: MobileDiscussionFrames.self,
                                        value: [thread.id: proxy.frame(in: .named("mobile-discussion-margin"))]) })
                            }
                        }
                        ForEach(newDrafts, id: \.self) { key in
                            VStack(alignment: .leading, spacing: 12) {
                                Text("Unposted discussion").font(.headline)
                                Text(reader.discussions.drafts[key]?.target?.exact ?? "")
                                MobileDiscussionComposer(reader: reader, key: key)
                            }.padding(14).background(.background, in: RoundedRectangle(cornerRadius: 10))
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }.padding(16).frame(maxWidth: .infinity, maxHeight: .infinity)
            .coordinateSpace(name: "mobile-discussion-margin")
            .onPreferenceChange(MobileDiscussionFrames.self) { frames = $0 }
    }
    private var newDrafts: [DiscussionSession.DraftKey] {
        reader.discussions.drafts.keys.filter { if case .new = $0 { return true }; return false }
    }
}
private struct MobileDiscussionFrames: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) { value.merge(nextValue(), uniquingKeysWith: { _, new in new }) }
}

/// Frozen semantic units provide a native alternative to selecting text in WebKit.
struct MobileDiscussionPassagePickerView: View {
    let reader: MobileReaderState
    let picker: MobileDiscussionPassagePicker
    @State private var query = ""
    @State private var selected: Int?
    @Environment(\.dismiss) private var dismiss
    private var stale: Bool { !reader.matchesDiscussionVersion(picker.version) || reader.hasPendingFileUpdate }
    private var units: [DiscussionTextUnit] {
        guard !query.isEmpty else { return picker.projection.units }
        return picker.projection.units.filter {
            $0.text.localizedCaseInsensitiveContains(query) || ($0.section?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }
    var body: some View {
        List {
            Section {
                Text("Choose the text to discuss. Your comment stays unposted until you choose Post.")
                    .foregroundStyle(.secondary)
            }
            Section {
                ForEach(units, id: \.id) { unit in
                    Button { selected = unit.id } label: {
                        HStack(alignment: .top, spacing: 12) {
                            VStack(alignment: .leading, spacing: 6) {
                                if let section = unit.section { Text(verbatim: section).font(.caption).foregroundStyle(.secondary) }
                                Text(verbatim: unit.text).lineLimit(4)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                            if selected == unit.id { Image(systemName: "checkmark").accessibilityHidden(true) }
                        }.foregroundStyle(.primary).padding(.vertical, 4)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(selected == unit.id ? .isSelected : [])
                    .disabled(stale)
                }
                if units.isEmpty { Text("No matching passages").foregroundStyle(.secondary) }
            }
            if stale {
                Label("The document changed. Cancel and choose the passage again.", systemImage: "exclamationmark.triangle")
            } else if let error = reader.discussionError {
                Label(error, systemImage: "exclamationmark.triangle")
            }
        }
        .navigationTitle("Choose a Passage").navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: "Find a passage")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { reader.cancelDiscussionPassage(); dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Use Passage") {
                    if let selected { reader.confirmDiscussionPassage(selected) }
                    if reader.discussionPassagePicker == nil { dismiss() }
                }.disabled(selected == nil || stale || reader.isRendering || reader.fileSaving)
            }
        }
        .onChange(of: query) { _, _ in
            if let selected, !units.contains(where: { $0.id == selected }) { self.selected = nil }
        }
    }
}
