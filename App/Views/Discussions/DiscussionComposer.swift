import AppKit
import SwiftUI

struct DiscussionComposerAnchor: Hashable {
    let key: DiscussionSession.DraftKey
}

struct DiscussionComposer: View {
    let reader: ReaderState
    let key: DiscussionSession.DraftKey
    let isReply: Bool
    var reveal: () -> Void = {}
    @State private var focused = false

    private struct DraftOwner: Hashable { let document: UUID; let key: DiscussionSession.DraftKey }
    private var bodyText: Binding<String> {
        Binding(get: { reader.discussions.drafts[key]?.body ?? "" },
                set: { reader.discussions.setDraft($0, for: key) })
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(reader.discussions.displayName.isEmpty
                 ? String(localized: "Your name will be stored with this comment.")
                 : String(localized: "Reply as \(reader.discussions.displayName)"))
                .font(.caption).foregroundStyle(.secondary)
            let context = reader.currentDiscussionVersion.context
            DiscussionDraftEditor(text: bodyText,
                selection: Binding(get: { reader.discussionComposerSelections[key] ?? NSRange(location: 0, length: 0) },
                                   set: { reader.discussionComposerSelections[key] = $0 }),
                label: isReply ? String(localized: "Reply") : String(localized: "Comment"),
                focusGeneration: reader.discussionComposerFocusGeneration,
                isCurrent: { reader.currentDiscussionVersion.context == context && reader.showDiscussions && reader.discussions.selection == key },
                focusChanged: { focused = $0 }, post: {
                    guard !reader.fileSaving, !reader.isRendering,
                          !bodyText.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                    reader.postDiscussion()
                })
                .id(DraftOwner(document: context, key: key))
                .frame(minHeight: 96, maxHeight: 144)
                .padding(6).overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
            HStack {
                if reader.discussionSaving { ProgressView().controlSize(.small) }
                Spacer()
                Button(isReply ? "Reply" : "Post") {
                    reader.discussions.selection = key
                    reader.postDiscussion()
                }
                .keyboardShortcut(.return, modifiers: .command)
                .buttonStyle(.borderedProminent)
                .disabled(reader.fileSaving || reader.isRendering || bodyText.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .id(DiscussionComposerAnchor(key: key))
        .onChange(of: focused) { _, value in if value { reveal() } }
        .onChange(of: bodyText.wrappedValue) { _, _ in if focused { reveal() } }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { _ in
            if focused { reveal() }
        }
    }
}

/// A bounded native editor keeps its own scrolling/Undo. The owning document
/// retains only the unposted text and selection across inspector transitions.
private struct DiscussionDraftEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var selection: NSRange
    let label: String
    let focusGeneration: Int
    let isCurrent: @MainActor () -> Bool
    let focusChanged: @MainActor (Bool) -> Void
    let post: @MainActor () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        let editor = DraftTextView(frame: CGRect(x: 0, y: 0, width: 100, height: 96))
        editor.isRichText = false; editor.allowsUndo = true
        editor.font = .preferredFont(forTextStyle: .body)
        editor.isVerticallyResizable = true; editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.minSize = .zero; editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.textContainer?.containerSize = NSSize(width: 100, height: CGFloat.greatestFiniteMagnitude)
        editor.textContainer?.widthTracksTextView = true
        editor.textContainerInset = NSSize(width: 2, height: 4)
        editor.setAccessibilityLabel(label)
        editor.setAccessibilityHelp(String(localized: "Command-Return posts. Return starts a new line."))
        editor.string = text
        editor.setSelectedRange(clamped(selection, in: text))
        editor.delegate = context.coordinator
        editor.focusChanged = { [weak coordinator = context.coordinator] focused in
            guard let coordinator, coordinator.active, coordinator.owner.isCurrent() else { return }
            coordinator.owner.focusChanged(focused)
        }
        scroll.documentView = editor
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.owner = self
        guard coordinator.active, let editor = scroll.documentView as? NSTextView else { return }
        if editor.string != text {
            editor.string = text
            editor.setSelectedRange(clamped(selection, in: text))
        }
        if focusGeneration > 0, focusGeneration != coordinator.focusGeneration, isCurrent() {
            coordinator.focusGeneration = focusGeneration
            let expected = focusGeneration
            Task { @MainActor [weak coordinator, weak editor] in
                await Task.yield()
                guard let coordinator, coordinator.active, coordinator.owner.isCurrent(),
                      coordinator.owner.focusGeneration == expected, coordinator.focusGeneration == expected, let editor else { return }
                editor.window?.makeFirstResponder(editor)
                editor.scrollRangeToVisible(editor.selectedRange())
            }
        }
    }
    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        coordinator.active = false
        if let editor = scroll.documentView as? DraftTextView { editor.delegate = nil; editor.focusChanged = nil }
    }
    private func clamped(_ range: NSRange, in text: String) -> NSRange {
        let length = text.utf16.count, start = min(length, max(0, range.location))
        return NSRange(location: start, length: min(max(0, range.length), length - start))
    }
    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        var owner: DiscussionDraftEditor
        var active = true
        var focusGeneration = 0
        init(_ owner: DiscussionDraftEditor) { self.owner = owner }
        func textDidChange(_ notification: Notification) {
            guard active, owner.isCurrent(), let editor = notification.object as? NSTextView else { return }
            owner.text = editor.string; owner.selection = editor.selectedRange()
            editor.scrollRangeToVisible(editor.selectedRange())
        }
        func textViewDidChangeSelection(_ notification: Notification) {
            guard active, owner.isCurrent(), let editor = notification.object as? NSTextView else { return }
            owner.selection = editor.selectedRange()
        }
        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard active, owner.isCurrent(), commandSelector == #selector(NSResponder.insertNewline(_:)),
                  NSApp.currentEvent?.modifierFlags.contains(.command) == true else { return false }
            owner.post(); return true
        }
    }
}

private final class DraftTextView: NSTextView {
    var focusChanged: (@MainActor (Bool) -> Void)?
    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder(); if result { focusChanged?(true) }; return result
    }
    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder(); if result { focusChanged?(false) }; return result
    }
}

struct DiscussionAuthorForm: View {
    let reader: ReaderState
    @State private var name = ""
    @FocusState private var focused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Choose a comment name").font(.headline)
            Text("This label is saved in the Markdown file. It is not a verified identity. Changing it later affects future messages only.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextField("Your name", text: $name).textFieldStyle(.roundedBorder).focused($focused)
            HStack {
                Button("Cancel") { reader.cancelDiscussionAuthor() }
                Spacer()
                Button(reader.discussionAuthorButtonTitle) { reader.confirmDiscussionAuthor(name) }
                    .buttonStyle(.borderedProminent)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(12).background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
        .task { name = reader.discussions.displayName; focused = true }
    }
}
