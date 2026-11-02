import SwiftUI
import UIKit

/// The composer alone owns this editor. Its selection is session state, never
/// Markdown metadata, and old delegates cannot write into a replacement file.
struct MobileDiscussionDraftEditor: UIViewRepresentable {
    let reader: MobileReaderState
    let key: DiscussionSession.DraftKey
    @Binding var text: String
    let document: UUID
    @Environment(\.sizeCategory) private var sizeCategory

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> UITextView {
        let view = DiscussionDraftTextView()
        view.backgroundColor = .clear
        view.adjustsFontForContentSizeCategory = true
        view.textContainerInset = UIEdgeInsets(top: 6, left: 4, bottom: 6, right: 4)
        view.text = text
        if let selection = reader.discussionComposerSelections[key] {
            view.selectedRange = Self.clamp(selection, length: view.text.utf16.count)
        }
        // Initial text assignment can emit selection changes. Observe only
        // after restoring the retained range so it cannot be replaced by EOF.
        view.delegate = context.coordinator
        return view
    }
    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.owner = self
        let font = UIFont.preferredFont(forTextStyle: .body,
            compatibleWith: UITraitCollection(preferredContentSizeCategory: sizeCategory.uiCategory))
        if view.font != font { view.font = font }
        view.textColor = .label
        if view.text != text {
            let selection = view.selectedRange
            view.text = text
            view.selectedRange = Self.clamp(selection, length: text.utf16.count)
        }
    }
    static func dismantleUIView(_ view: UITextView, coordinator: Coordinator) {
        coordinator.invalidate(view)
        view.delegate = nil
    }
    private static func clamp(_ range: NSRange, length: Int) -> NSRange {
        let location = min(max(0, range.location), length)
        return NSRange(location: location, length: min(range.length, length - location))
    }
    @MainActor final class Coordinator: NSObject, UITextViewDelegate {
        var owner: MobileDiscussionDraftEditor
        private let focusID = UUID()
        private var active = true
        init(_ owner: MobileDiscussionDraftEditor) { self.owner = owner }
        private var isCurrent: Bool { active && owner.document == owner.reader.documentGeneration }
        func rememberSelection(_ view: UITextView) {
            guard isCurrent else { return }
            owner.reader.discussionComposerSelections[owner.key] = view.selectedRange
        }
        func textViewDidBeginEditing(_ view: UITextView) {
            guard isCurrent else { view.resignFirstResponder(); return }
            rememberSelection(view)
            owner.reader.discussionFocus = .init(id: focusID, input: .body)
            owner.reader.discussionEndEditing = { [weak view] in view?.resignFirstResponder() }
            if !owner.reader.discussionUsesMargin { owner.reader.discussionSheetExpanded = true }
        }
        func finishEditing(_ view: UITextView) {
            rememberSelection(view)
            if owner.reader.discussionFocus?.id == focusID { owner.reader.discussionFocus = nil }
        }
        func invalidate(_ view: UITextView) { finishEditing(view); active = false }
        func textViewDidEndEditing(_ view: UITextView) { finishEditing(view) }
        func textViewDidChangeSelection(_ view: UITextView) { rememberSelection(view) }
        func textViewDidChange(_ view: UITextView) {
            guard isCurrent else { return }
            owner.text = view.text
            rememberSelection(view)
        }
    }
}

/// Keyboard and Dynamic Type transitions can resize the retained editor after
/// UIKit's initial selection scroll. Keep the insertion end visible once the
/// actual viewport has settled without changing the user's selected range.
private final class DiscussionDraftTextView: UITextView {
    private struct Layout: Equatable {
        let size: CGSize
        let insets: UIEdgeInsets
        let font: UIFont?
        let selection: NSRange
        let focused: Bool
    }
    private var lastLayout: Layout?
    #if DEBUG
    private let diagnosticID = UUID()
    private var diagnosticEvents = 0
    private struct DiagnosticSnapshot {
        let size: CGSize
        let offset: CGPoint
        let insets: UIEdgeInsets
        let fontSize: CGFloat?
        let selection: NSRange
        let focused: Bool
        let mounted: Bool
        var description: String {
            "size=\(size) offset=\(offset) insets=\(insets) fontSize=\(fontSize.map(String.init(describing:)) ?? "none") selection=\(selection) focused=\(focused) mounted=\(mounted)"
        }
    }
    private func diagnosticSnapshot() -> DiagnosticSnapshot {
        .init(size: bounds.size, offset: contentOffset, insets: adjustedContentInset,
              fontSize: font?.pointSize, selection: selectedRange,
              focused: isFirstResponder, mounted: window != nil)
    }
    private func diagnosticReason(previous: Layout?, current: Layout) -> String {
        guard let previous else { return "first-focused-layout" }
        var reasons: [String] = []
        if previous.size != current.size { reasons.append("size") }
        if previous.insets != current.insets { reasons.append("insets") }
        if previous.font != current.font { reasons.append("font") }
        if previous.selection != current.selection { reasons.append("selection") }
        if previous.focused != current.focused { reasons.append("focus") }
        return reasons.isEmpty ? "unchanged-key" : reasons.joined(separator: ",")
    }
    private func diagnosticLayout(_ layout: Layout?) -> String {
        guard let layout else { return "none" }
        return "size=\(layout.size) insets=\(layout.insets) fontSize=\(layout.font.map { String(describing: $0.pointSize) } ?? "none") selection=\(layout.selection) focused=\(layout.focused)"
    }
    private func traceLayout(phase: String, reason: String, before: DiagnosticSnapshot,
                             after: DiagnosticSnapshot, keyChanged: Bool,
                             previous: Layout?, current: Layout?) {
        guard diagnosticEvents < 80, keyChanged || before.offset != after.offset else { return }
        diagnosticEvents += 1
        let message = "DRAFT-LAYOUT id=\(diagnosticID.uuidString) view=\(ObjectIdentifier(self)) event=\(diagnosticEvents) phase=\(phase) reason=\(reason) before={\(before.description)} after={\(after.description)} previousKey={\(diagnosticLayout(previous))} currentKey={\(diagnosticLayout(current))}\n"
        FileHandle.standardError.write(Data(message.utf8))
    }
    #endif
    override func layoutSubviews() {
        #if DEBUG
        let beforeSuper = diagnosticSnapshot()
        #endif
        super.layoutSubviews()
        #if DEBUG
        let afterSuper = diagnosticSnapshot()
        let previousLayout = lastLayout
        #endif
        guard isFirstResponder, window != nil, bounds.height > 0,
              let selection = selectedTextRange else {
            lastLayout = nil
            #if DEBUG
            traceLayout(phase: "super", reason: "inactive-reset", before: beforeSuper, after: afterSuper,
                        keyChanged: previousLayout != nil, previous: previousLayout, current: nil)
            #endif
            return
        }
        let layout = Layout(size: bounds.size, insets: adjustedContentInset,
                            font: font, selection: selectedRange, focused: isFirstResponder)
        let changed = lastLayout != layout
        lastLayout = layout
        #if DEBUG
        let reason = diagnosticReason(previous: previousLayout, current: layout)
        traceLayout(phase: "super", reason: reason, before: beforeSuper, after: afterSuper,
                    keyChanged: changed, previous: previousLayout, current: layout)
        #endif
        // A scroll changes bounds.origin, but does not change this key. Let the
        // user browse a long draft without an unrelated layout moving it back.
        guard changed else { return }
        #if DEBUG
        let beforeReveal = diagnosticSnapshot()
        #endif
        scrollRectToVisible(caretRect(for: selection.start).insetBy(dx: 0, dy: -4), animated: false)
        #if DEBUG
        traceLayout(phase: "reveal-caret", reason: reason, before: beforeReveal, after: diagnosticSnapshot(),
                    keyChanged: changed, previous: previousLayout, current: layout)
        #endif
    }
}
