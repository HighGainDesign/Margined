import SwiftUI
import UIKit

struct MobileDiscussionList: View {
    @Bindable var reader: MobileReaderState
    var body: some View {
        List {
            Menu("Document Actions", systemImage: "ellipsis.circle") { MobileDiscussionFileActions(reader: reader) }
            MobileDiscussionDiagnostics(reader: reader)
            if reader.discussionImportLoading { ProgressView("Reading discussions…") }
            if let error = reader.discussionError { Label(error, systemImage: "exclamationmark.triangle").textSelection(.enabled) }
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
    }
    private var newDrafts: [DiscussionSession.DraftKey] {
        reader.discussions.drafts.keys.filter { if case .new = $0 { return true }; return false }
            .sorted { String(describing: $0) < String(describing: $1) }
    }
}

/// An in-document sheet reserves real reader space rather than obscuring WebKit.
/// Keeping one subtree across detents preserves its editor and history ownership.
struct MobileCompactDiscussionSheet: View {
    @Bindable var reader: MobileReaderState
    let availableHeight: CGFloat
    let navigation: Binding<[MobileDiscussionRoute]>
    private let document: UUID
    private let layout: UUID
    private let intent: UUID
    private let version: MobileDiscussionVersion
    @MainActor init(reader: MobileReaderState, availableHeight: CGFloat, navigation: Binding<[MobileDiscussionRoute]>) {
        self.reader = reader; self.availableHeight = availableHeight; self.navigation = navigation
        document = reader.documentGeneration; layout = reader.discussionLayoutGeneration
        intent = reader.discussionPresentationGeneration
        version = reader.currentDiscussionVersion
    }
    private var isCurrent: Bool {
        document == reader.documentGeneration && layout == reader.discussionLayoutGeneration &&
            intent == reader.discussionPresentationGeneration && reader.inspector == .discussions && !reader.discussionUsesMargin
    }
    @Environment(\.dynamicTypeSize) private var textSize
    private var expanded: Bool { reader.discussionSheetExpanded }
    private var shortTyping: Bool { reader.discussionFocus != nil }
    private var height: CGFloat {
        let usable = max(0, availableHeight - (shortTyping ? 0 : 48))
        return expanded ? usable : min(480, max(0, usable - 160))
    }
    private func context(for key: DiscussionSession.DraftKey) -> String {
        if case let .thread(id) = key {
            return reader.rendered?.discussions?.threads.first(where: { $0.id == id })?.target.exact ?? ""
        }
        return reader.discussions.drafts[key]?.target?.exact ?? ""
    }
    private func canReveal(_ key: DiscussionSession.DraftKey) -> Bool {
        if case let .thread(id) = key { return reader.rendered?.discussionText?.anchorResults[id]?.status == .attached }
        return reader.discussions.draftAnchor(for: key)?.status == .attached
    }
    var body: some View {
        VStack(spacing: 0) {
            Button {
                guard isCurrent else { return }
                reader.endDiscussionEditing()
                reader.discussionSheetExpanded.toggle()
            } label: {
                Image(systemName: expanded ? "chevron.compact.down" : "chevron.compact.up")
                    .font(.system(size: 16, weight: .semibold)).frame(maxWidth: .infinity).frame(height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(expanded ? String(localized: "Collapse discussion") : String(localized: "Expand discussion"))
            .accessibilityValue(expanded ? String(localized: "Expanded") : String(localized: "Collapsed"))
            .frame(height: shortTyping ? 0 : nil).clipped().accessibilityHidden(shortTyping).allowsHitTesting(!shortTyping)
            .gesture(DragGesture(minimumDistance: 15).onEnded { value in
                guard isCurrent else { return }
                reader.endDiscussionEditing()
                reader.discussionSheetExpanded = value.translation.height < 0
            })
            HStack(spacing: 12) {
                if reader.discussionRoute != nil {
                    Button { navigation.wrappedValue = [.list] } label: {
                        if shortTyping { Image(systemName: "chevron.left") }
                        else if textSize.isAccessibilitySize { Label("Discussions", systemImage: "chevron.left") }
                        else { Label("Back to Discussions", systemImage: "chevron.left") }
                    }.accessibilityLabel("Back to Discussions").font(shortTyping ? .system(size: 17) : .subheadline).frame(minWidth: 44, minHeight: 44)
                } else {
                    Text("Discussions").font(.headline)
                }
                Spacer(minLength: 0)
                if shortTyping, let key = reader.discussionRoute {
                    Menu {
                        Text(verbatim: context(for: key))
                        Button(expanded ? "Collapse discussion" : "Expand discussion") {
                            guard isCurrent else { return }
                            reader.endDiscussionEditing(); reader.discussionSheetExpanded.toggle()
                        }
                        if case let .thread(id) = key,
                           let thread = reader.rendered?.discussions?.threads.first(where: { $0.id == id }) {
                            MobileDiscussionControls(reader: reader, thread: thread)
                        }
                    } label: { Image(systemName: "quote.bubble") }
                    .accessibilityLabel(String(localized: "Quoted passage") + ", " + context(for: key))
                    .frame(minWidth: 44, minHeight: 44)
                    Button("Go to Passage", systemImage: "arrow.up.forward") {
                        guard isCurrent else { return }
                        if case let .thread(id) = key { reader.goToDiscussion(id, version: version) }
                        else { reader.goToDiscussionDraft(key, version: version) }
                    }.labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44)
                        .disabled(reader.isRendering || reader.fileSaving || !canReveal(key))
                }
                Spacer(minLength: 0)
                Button { navigation.wrappedValue = [] } label: {
                    if shortTyping || textSize.isAccessibilitySize { Image(systemName: "xmark") }
                    else { Label("Hide", systemImage: "xmark") }
                }.accessibilityLabel("Hide").frame(minWidth: 44, minHeight: 44)
            }.font(shortTyping ? .system(size: 17) : .body).padding(.horizontal, 16).frame(minHeight: 44)
            Divider()
            if let key = reader.discussionRoute {
                MobileDiscussionThread(reader: reader, key: key, compactSheet: true)
            } else {
                MobileDiscussionList(reader: reader)
            }
        }
        .frame(height: height)
        .background(.regularMaterial, in: UnevenRoundedRectangle(topLeadingRadius: 18, topTrailingRadius: 18))
        .overlay(alignment: .top) {
            UnevenRoundedRectangle(topLeadingRadius: 18, topTrailingRadius: 18).stroke(.separator).allowsHitTesting(false)
        }
        .accessibilityIdentifier("compact-discussion-sheet")
        .onAppear { if isCurrent, textSize.isAccessibilitySize { reader.discussionSheetExpanded = true } }
        .onChange(of: textSize) { _, value in if value.isAccessibilitySize { reader.discussionSheetExpanded = true } }
    }
}

struct MobileDiscussionThread: View {
    @Bindable var reader: MobileReaderState
    @Environment(\.dynamicTypeSize) private var textSize
    let key: DiscussionSession.DraftKey
    var compactSheet = false
    private let version: MobileDiscussionVersion
    @MainActor init(reader: MobileReaderState, key: DiscussionSession.DraftKey, compactSheet: Bool = false) {
        self.reader = reader; self.key = key; self.compactSheet = compactSheet
        version = reader.currentDiscussionVersion
    }
    private var thread: DiscussionThread? {
        if case let .thread(id) = key { return reader.rendered?.discussions?.threads.first { $0.id == id } }
        return nil
    }
    private var quote: String { thread?.target.exact ?? reader.discussions.drafts[key]?.target?.exact ?? "" }
    private var shortTyping: Bool { compactSheet && reader.discussionFocus != nil }
    var body: some View {
        GeometryReader { geometry in
            VStack(alignment: .leading, spacing: shortTyping ? 4 : 8) {
                HStack(alignment: .top) {
                    Text(verbatim: quote).font(shortTyping && textSize.isAccessibilitySize ? .caption : .callout).lineLimit(textSize.isAccessibilitySize ? 1 : 2).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityLabel(String(localized: "Quoted passage") + ", " + quote)
                    if let thread {
                        Button {
                            reader.goToDiscussion(thread.id, version: version)
                        } label: {
                            if textSize.isAccessibilitySize { Image(systemName: "arrow.up.forward") }
                            else { Label("Go to Passage", systemImage: "arrow.up.forward") }
                        }.accessibilityLabel("Go to Passage").font(.caption).frame(minWidth: 44, minHeight: 44)
                            .disabled(reader.isRendering || reader.fileSaving || reader.rendered?.discussionText?.anchorResults[thread.id]?.status != .attached)
                        Menu("Discussion Actions", systemImage: "ellipsis.circle") {
                            MobileDiscussionControls(reader: reader, thread: thread)
                        }.labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44)
                    } else {
                        Button("Go to Passage", systemImage: "arrow.up.forward") {
                            reader.goToDiscussionDraft(key, version: version)
                        }.labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44)
                            .disabled(reader.isRendering || reader.fileSaving || reader.discussions.draftAnchor(for: key)?.status != .attached)
                    }
                }.padding(.horizontal, 16).padding(.top, shortTyping ? 2 : 6)
                    .frame(height: shortTyping ? 0 : nil).clipped().accessibilityHidden(shortTyping).allowsHitTesting(!shortTyping)
                if reader.discussionDecision?.key == key || reader.discussionError != nil {
                    MobileDiscussionScrollSection(maxHeight: max(44, geometry.size.height * 0.24)) {
                        MobileDiscussionDecisionView(reader: reader, key: key)
                        if let error = reader.discussionError {
                            Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.red)
                        }
                    }.padding(.horizontal, 16)
                }
                if let thread {
                    MobileDiscussionMessages(reader: reader, thread: thread, fillsAvailableSpace: true, previewLines: shortTyping ? 3 : 4)
                        .labelStyle(MobileDiscussionHistoryLabelStyle(compact: shortTyping))
                        .frame(maxWidth: .infinity, maxHeight: .infinity).padding(.horizontal, 16)
                } else { Spacer(minLength: 0) }
                Divider()
                MobileDiscussionScrollSection(maxHeight: shortTyping ? max(124, geometry.size.height * 0.50) : max(100, geometry.size.height * (textSize.isAccessibilitySize ? 0.44 : 0.58)),
                    revealBottom: shortTyping && reader.discussionFocus?.input == .body,
                    revealTop: shortTyping && reader.discussionFocus?.input == .name) {
                    MobileDiscussionComposer(reader: reader, key: key, compact: compactSheet, shortTyping: shortTyping).padding(.horizontal, 16).padding(.bottom, shortTyping ? 4 : 20)
                }
            }
        }
    }
}

private struct MobileDiscussionHistoryLabelStyle: LabelStyle {
    let compact: Bool
    @ViewBuilder func makeBody(configuration: Configuration) -> some View {
        if compact { Label(configuration).labelStyle(.iconOnly).font(.system(size: 17)) }
        else { Label(configuration).labelStyle(.titleAndIcon) }
    }
}

/// A bounded form scroll keeps every field reachable at large text. History has
/// its own sole scroller, and the composer stays mounted while its budget changes.
private struct MobileDiscussionScrollSection<Content: View>: View {
    let maxHeight: CGFloat
    var revealBottom = false
    var revealTop = false
    @ViewBuilder var content: Content
    @State private var contentHeight: CGFloat?
    private let bottomID = "discussion-form-bottom"
    private let topID = "discussion-form-top"
    var body: some View {
        ScrollViewReader { scroller in
            ScrollView {
                VStack(spacing: 0) {
                    Color.clear.frame(height: 0).id(topID)
                    content
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
                    Color.clear.frame(height: 0).id(bottomID)
                }
            }
            .scrollBounceBehavior(.basedOnSize)
            .onChange(of: revealBottom, initial: true) { _, value in
                if value { scroller.scrollTo(bottomID, anchor: .bottom) }
            }
            .onChange(of: revealTop, initial: true) { _, value in
                if value { scroller.scrollTo(topID, anchor: .top) }
            }
            .onChange(of: contentHeight) { _, _ in
                if revealBottom { scroller.scrollTo(bottomID, anchor: .bottom) }
                else if revealTop { scroller.scrollTo(topID, anchor: .top) }
            }
        }
        .frame(height: min(maxHeight, contentHeight ?? maxHeight))
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
    let reader: MobileReaderState
    let thread: DiscussionThread
    var fillsAvailableSpace = false
    var previewLines = 4
    var body: some View {
        let context = reader.documentGeneration, playback = reader.playback
        DiscussionHistoryView(documentID: context, thread: thread, fileURL: reader.fileURL,
            appearance: reader.appearance, loadRemoteImages: reader.loadRemoteImages,
            zoom: reader.zoom, imageGeneration: reader.imageReloadGeneration, documentLanguage: nil,
            isCurrent: { reader.documentGeneration == context && reader.inspector == .discussions &&
                reader.discussions.selection == .thread(thread.id) &&
                (reader.discussionUsesMargin || reader.discussionRoute == .thread(thread.id)) &&
                reader.rendered?.discussions?.threads.contains(where: { $0.id == thread.id }) == true },
            imageFailed: { reader.localImageError = $0 },
            openFile: { url in
                guard ["md", "markdown", "mdown", "mkd", "mkdn"].contains(url.pathExtension.lowercased()) else { return }
                Task {
                    guard reader.documentGeneration == context else { return }
                    await reader.open(url: url)
                }
            }, playback: DiscussionHistoryPlayback(session: playback.session, options: playback.preferences.options,
                conversationID: playback.ownerID == reader.id ? playback.conversationID : nil,
                enabled: !reader.isRendering && !reader.fileSaving && !reader.showChecklistConfirmation,
                pendingVersion: reader.hasPendingFileUpdate, preparing: reader.speechPreparing,
                read: { reader.readConversation(thread: thread, document: $0, context: context) },
                toggle: {
                    guard playback.ownerID == reader.id, playback.conversationID == thread.id, playback.session.isActive else { return }
                    reader.toggleSpeechPlayback()
                }, stop: {
                    guard playback.ownerID == reader.id, playback.conversationID == thread.id else { return }
                    reader.stopSpeech()
                }, resumeDocument: {
                    guard playback.ownerID == reader.id, playback.conversationID == thread.id else { return }
                    reader.resumeSpeechPosition()
                }, showLatest: { reader.showLatest() }), fillsAvailableSpace: fillsAvailableSpace,
            presentationState: reader.discussionHistoryPosition(for: thread.id), previewLines: previewLines)
    }
}

struct MobileDiscussionComposer: View {
    @Bindable var reader: MobileReaderState
    let key: DiscussionSession.DraftKey
    var compact = false
    var shortTyping = false
    private struct Identity: Hashable {
        let document: UUID
        let draft: DiscussionSession.DraftKey
    }
    var body: some View {
        // Keep native binding storage separate when navigation reuses this view
        // for another document or thread, including files with identical IDs.
        MobileDiscussionComposerFields(reader: reader, key: key, compact: compact, shortTyping: shortTyping)
            .id(Identity(document: reader.documentGeneration, draft: key))
    }
}

private struct MobileDiscussionComposerFields: View {
    @Bindable var reader: MobileReaderState
    let key: DiscussionSession.DraftKey
    let compact: Bool
    let shortTyping: Bool
    @State private var nameFocusID = UUID()
    @FocusState private var nameFocused: Bool
    private let documentContext: UUID
    @MainActor init(reader: MobileReaderState, key: DiscussionSession.DraftKey, compact: Bool, shortTyping: Bool) {
        self.reader = reader; self.key = key; self.compact = compact; self.shortTyping = shortTyping; documentContext = reader.documentGeneration
    }
    private var isCurrent: Bool { documentContext == reader.documentGeneration }
    private var isReply: Bool { if case .thread = key { return true }; return false }
    private var bodyBinding: Binding<String> {
        Binding(get: { isCurrent ? reader.discussions.drafts[key]?.body ?? "" : "" },
                set: { if isCurrent { reader.discussions.setDraft($0, for: key) } })
    }
    private var fieldLayout: AnyLayout {
        shortTyping ? AnyLayout(HStackLayout(alignment: .bottom, spacing: 8)) : AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
    }
    private var actionLayout: AnyLayout {
        shortTyping ? AnyLayout(VStackLayout(alignment: .trailing, spacing: 0)) : AnyLayout(HStackLayout())
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !compact {
                Text("This name is saved in the Markdown file. It is not a verified identity.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            fieldLayout {
                VStack(alignment: .leading, spacing: shortTyping ? 0 : 10) {
                    TextField("Your name", text: Binding(get: { reader.discussions.displayName },
                        set: { if isCurrent { reader.discussions.displayName = $0 } }))
                        .textFieldStyle(.roundedBorder).textInputAutocapitalization(.words)
                        .accessibilityHint("This name is saved in the Markdown file. It is not a verified identity.")
                        .focused($nameFocused)
                        .onChange(of: nameFocused) { _, focused in
                            guard isCurrent else { return }
                            if focused {
                                reader.discussionFocus = .init(id: nameFocusID, input: .name)
                                if !reader.discussionUsesMargin { reader.discussionSheetExpanded = true }
                            } else if reader.discussionFocus?.id == nameFocusID { reader.discussionFocus = nil }
                        }
                        .onChange(of: reader.discussionEditingDismissal) { _, _ in nameFocused = false }
                        .frame(height: shortTyping && reader.discussionFocus?.input != .name ? 0 : nil)
                        .clipped().accessibilityHidden(shortTyping && reader.discussionFocus?.input != .name)
                        .allowsHitTesting(!shortTyping || reader.discussionFocus?.input == .name)
                    MobileDiscussionDraftEditor(reader: reader, key: key, text: bodyBinding, document: documentContext)
                        .frame(minHeight: shortTyping && reader.discussionFocus?.input == .name ? 0 : (compact ? 66 : 90),
                            maxHeight: shortTyping && reader.discussionFocus?.input == .name ? 0 : (compact ? 100 : 150))
                        .padding(shortTyping && reader.discussionFocus?.input == .name ? 0 : 5).background(.background, in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.separator))
                        .accessibilityLabel(isReply ? "Reply" : "Discussion")
                        .accessibilityHint("Command-Return posts. Return starts a new line.")
                        .clipped().accessibilityHidden(shortTyping && reader.discussionFocus?.input == .name)
                        .allowsHitTesting(!shortTyping || reader.discussionFocus?.input != .name)
                }
                actionLayout {
                    if shortTyping {
                        Button {
                            guard isCurrent else { return }
                            reader.discussionFocus = .init(id: nameFocusID, input: .name)
                            nameFocused = true
                        } label: {
                            Label {
                                if reader.discussions.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { Text("Your name") }
                                else { Text("Reply as \(reader.discussions.displayName)") }
                            } icon: { Image(systemName: "person.crop.circle").font(.system(size: 17)) }
                                .labelStyle(.iconOnly)
                        }.font(.caption).lineLimit(1).frame(minWidth: 44, minHeight: 44)
                            .accessibilityIdentifier("discussion-author-action")
                            .accessibilityHint("This name is saved in the Markdown file. It is not a verified identity.")
                    } else { Text("Replies are saved in this Markdown file.").font(.caption).foregroundStyle(.secondary) }
                    Spacer(minLength: 0).frame(width: shortTyping ? 0 : nil, height: shortTyping ? 0 : nil)
                    Button {
                        guard isCurrent, reader.discussionDecision?.key != key else { return }
                        reader.discussions.selection = key; reader.postDiscussion()
                    } label: {
                        ViewThatFits(in: .horizontal) {
                            Text(isReply ? LocalizedStringKey("Reply") : LocalizedStringKey("Post")).font(.body).fixedSize()
                            Image(systemName: "paperplane.fill").font(.system(size: 17))
                        }.frame(maxWidth: shortTyping ? .infinity : nil)
                    }
                        .controlSize(shortTyping ? .small : .regular)
                        .accessibilityLabel(isReply ? Text("Reply") : Text("Post"))
                        .buttonStyle(.borderedProminent).frame(minWidth: 44, minHeight: 44)
                        .accessibilityIdentifier("discussion-post-action").keyboardShortcut(.return, modifiers: .command)
                        .accessibilityHint("Replies are saved in this Markdown file.")
                        .disabled(!isCurrent || reader.discussionDecision?.key == key || reader.fileSaving || reader.isRendering || reader.discussions.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || bodyBinding.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }.frame(width: shortTyping ? 190 : nil)
            }
        }
    }
}

/// Uses viewport coordinates already scaled by MobileWebTypography. Do not apply zoom twice.
struct MobileDiscussionMargin: View {
    @Bindable var reader: MobileReaderState
    var includesInspectorPicker = false
    @State private var frames: [String: CGRect] = [:]
    var body: some View {
        VStack(spacing: 12) {
            if includesInspectorPicker {
                MobileInspectorHeader(reader: reader)
            } else {
                HStack {
                    Label("Discussions", systemImage: "bubble.left.and.bubble.right").font(.headline)
                    Spacer()
                    Button("Hide discussions", systemImage: "xmark") { reader.hideDiscussions() }.labelStyle(.iconOnly)
                }
            }
            if let key = reader.discussionRoute {
                HStack {
                    Button("Back to Discussions", systemImage: "chevron.left") {
                        reader.backToDiscussionList()
                    }.font(.subheadline)
                    Spacer(minLength: 0)
                    Menu("Document Actions", systemImage: "ellipsis.circle") { MobileDiscussionFileActions(reader: reader) }
                }
                MobileDiscussionThread(reader: reader, key: key)
            } else {
                Menu("Document Actions", systemImage: "ellipsis.circle") { MobileDiscussionFileActions(reader: reader) }
                MobileDiscussionDiagnostics(reader: reader)
                if reader.discussionImportLoading { ProgressView("Reading discussions…") }
                if let error = reader.discussionError { Label(error, systemImage: "exclamationmark.triangle").font(.footnote) }
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
                                    Button { reader.openDiscussion(thread.id) } label: {
                                        MobileDiscussionSummary(reader: reader, thread: thread)
                                    }.padding(14).background(.background, in: RoundedRectangle(cornerRadius: 10))
                                        .background(GeometryReader { proxy in Color.clear.preference(key: MobileDiscussionFrames.self,
                                            value: [thread.id: proxy.frame(in: .named("mobile-discussion-margin"))]) })
                                }
                            }
                            ForEach(newDrafts, id: \.self) { key in
                                Button {
                                    reader.discussions.selection = key; reader.discussionRoute = key
                                } label: {
                                    VStack(alignment: .leading, spacing: 12) {
                                        Text("Unposted discussion").font(.headline)
                                        Text(reader.discussions.drafts[key]?.target?.exact ?? "").lineLimit(3)
                                    }.frame(maxWidth: .infinity, alignment: .leading)
                                }.padding(14).background(.background, in: RoundedRectangle(cornerRadius: 10))
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
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
    private var explanation: String {
        switch picker.request.intent {
        case .add: String(localized: "Choose the text to discuss. Your comment stays unposted until you choose Post.")
        case .reattach: String(localized: "Choose replacement text. You will compare the old and new passages before attaching.")
        }
    }
    private var units: [DiscussionTextUnit] {
        guard !query.isEmpty else { return picker.projection.units }
        return picker.projection.units.filter {
            $0.text.localizedCaseInsensitiveContains(query) || ($0.section?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }
    var body: some View {
        List {
            Section {
                Text(explanation)
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
                Button("Cancel") {
                    guard reader.discussionPassagePicker?.id == picker.id else { return }
                    reader.cancelDiscussionPassage(pickerID: picker.id); dismiss()
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Use Passage") {
                    guard reader.discussionPassagePicker?.id == picker.id else { return }
                    if let selected { reader.confirmDiscussionPassage(selected, pickerID: picker.id) }
                    if reader.discussionPassagePicker == nil { dismiss() }
                }.disabled(selected == nil || stale || reader.isRendering || reader.fileSaving)
            }
        }
        .onChange(of: query) { _, _ in
            if let selected, !units.contains(where: { $0.id == selected }) { self.selected = nil }
        }
    }
}

struct MobileDiscussionControls: View {
    let reader: MobileReaderState
    let thread: DiscussionThread
    private let version: MobileDiscussionVersion
    @MainActor init(reader: MobileReaderState, thread: DiscussionThread) {
        self.reader = reader; self.thread = thread; version = reader.currentDiscussionVersion
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if reader.rendered?.discussionText?.anchorResults[thread.id]?.status == .attached {
                Button("Go to Passage", systemImage: "arrow.up.forward") {
                    reader.goToDiscussion(thread.id, version: version)
                }.buttonStyle(.bordered).disabled(reader.isRendering || reader.fileSaving)
            } else {
                Label("Passage needs attention", systemImage: "link.badge.plus")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button(thread.state == .open ? "Resolve" : "Reopen",
                       systemImage: thread.state == .open ? "checkmark.bubble" : "arrow.uturn.backward") {
                    guard reader.matchesDiscussionVersion(version) else {
                        reader.discussionError = DiscussionSession.Failure.staleSource.localizedDescription; return
                    }
                    if thread.state == .open { reader.requestResolveDiscussion(thread.id) }
                    else { reader.reopenDiscussion(thread.id) }
                }.buttonStyle(.bordered).disabled(!reader.canEditDiscussions)
                Button("Reattach…", systemImage: "link") {
                    guard reader.matchesDiscussionVersion(version) else {
                        reader.discussionError = DiscussionSession.Failure.staleSource.localizedDescription; return
                    }
                    reader.requestReattachDiscussion(thread.id)
                }.buttonStyle(.bordered).disabled(!reader.canEditDiscussions)
                    .accessibilityHint("Select replacement text in the document, or choose a passage from a list.")
                Spacer()
            }
        }
    }
}

struct MobileDiscussionDecisionView: View {
    let reader: MobileReaderState
    let key: DiscussionSession.DraftKey
    var body: some View {
        if let decision = reader.discussionDecision, decision.key == key {
            MobileDiscussionDecisionCard(reader: reader, decision: decision).id(decision.id)
        }
    }
}

private struct MobileDiscussionDecisionCard: View {
    let reader: MobileReaderState
    let decision: MobileDiscussionDecision
    private var stale: Bool {
        !reader.matchesDiscussionVersion(decision.version) || (decision.checksDraftRevision && reader.discussions.drafts[decision.key]?.revision != decision.draftRevision)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch decision.kind {
            case .resolve:
                Text("Resolve with an unposted reply?").font(.headline).accessibilityAddTraits(.isHeader)
                Text("Keep the discussion open, post your reply before resolving, or discard this draft and resolve.")
                    .font(.callout).foregroundStyle(.secondary)
                Button("Keep Open") { reader.confirmDiscussionResolution(decision.id, choice: .keepOpen) }
                Button("Post Reply and Resolve") { reader.confirmDiscussionResolution(decision.id, choice: .postDraft) }
                    .buttonStyle(.borderedProminent).disabled(stale || !reader.canEditDiscussions)
                Button("Discard Draft and Resolve", role: .destructive) { reader.confirmDiscussionResolution(decision.id, choice: .discardDraft) }
                    .disabled(stale || !reader.canEditDiscussions)
            case .reopenReply:
                Text("Reopen and post this reply?").font(.headline).accessibilityAddTraits(.isHeader)
                Text("This discussion is resolved. Posting your reply reopens it and keeps every earlier message.")
                    .font(.callout).foregroundStyle(.secondary)
                Button("Cancel") { reader.cancelDiscussionDecision(decision.id) }
                Button("Reopen and Reply") { reader.confirmDiscussionReopenReply(decision.id) }
                    .buttonStyle(.borderedProminent).disabled(stale || !reader.canEditDiscussions)
            case let .reattach(_, old, selected):
                Text("Attach this discussion to a new passage?").font(.headline).accessibilityAddTraits(.isHeader)
                quote("Previous passage", old.exact)
                quote("New passage", selected.target.exact)
                Text("The previous passage stays in the discussion’s history.").font(.caption).foregroundStyle(.secondary)
                Button("Cancel") { reader.cancelDiscussionDecision(decision.id) }
                Button("Attach to Selection") { reader.confirmDiscussionReattachment(decision.id) }
                    .buttonStyle(.borderedProminent).disabled(stale || !reader.canEditDiscussions)
            }
            if stale {
                Label("The document or reply changed. Close this confirmation and try again.", systemImage: "exclamationmark.triangle")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
        .disabled(reader.fileSaving)
    }
    private func quote(_ title: LocalizedStringKey, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ScrollView { Text(verbatim: text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                .frame(maxHeight: 110)
        }
    }
}


/// Unrecognized blocks remain in the file and can be inspected without editing it.
struct MobileDiscussionDiagnostics: View {
    let reader: MobileReaderState
    private struct SourceSnapshot: Identifiable {
        let id = UUID()
        let title: String
        let source: String
    }
    @State private var snapshot: SourceSnapshot?
    @State private var expanded = true

    var body: some View {
        if let document = reader.rendered?.discussions, !document.diagnostics.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                DisclosureGroup(isExpanded: $expanded) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(Array(document.diagnostics.enumerated()), id: \.offset) { _, item in
                                Text("Line \(item.line): \(item.message)").font(.caption)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(maxHeight: 100)
                } label: {
                    Label("Some discussions are unavailable", systemImage: "exclamationmark.bubble")
                        .font(.callout)
                }
                Button("Show Source", systemImage: "doc.text") {
                    snapshot = .init(title: reader.title, source: document.source)
                }
            }.textSelection(.enabled)
                .accessibilityIdentifier("discussion-diagnostics")
                .sheet(item: $snapshot) { source in
                    NavigationStack {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Read-only source snapshot. Includes saved discussions and metadata. Unposted comments are not included.")
                                .font(.caption).foregroundStyle(.secondary).padding(.horizontal)
                            MobileDiscussionSourceText(source: source.source)
                        }
                        .navigationTitle(Text("Source — \(source.title)"))
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .topBarLeading) {
                                Button("Copy") { UIPasteboard.general.string = source.source }
                            }
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Done") { snapshot = nil }
                            }
                        }
                    }.presentationDragIndicator(.visible)
                }
        }
    }
}

private struct MobileDiscussionSourceText: UIViewRepresentable {
    let source: String
    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.isSelectable = true
        view.font = UIFontMetrics(forTextStyle: .body).scaledFont(for: .monospacedSystemFont(ofSize: 14, weight: .regular))
        view.adjustsFontForContentSizeCategory = true
        view.textColor = .label
        view.backgroundColor = .systemBackground
        view.textContainerInset = UIEdgeInsets(top: 12, left: 16, bottom: 12, right: 16)
        view.accessibilityLabel = String(localized: "Markdown source, read only")
        return view
    }
    func updateUIView(_ view: UITextView, context: Context) {
        if view.text != source { view.text = source }
    }
}
