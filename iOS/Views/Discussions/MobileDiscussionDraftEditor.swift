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
        view.font = UIFont.preferredFont(forTextStyle: .body,
            compatibleWith: UITraitCollection(preferredContentSizeCategory: sizeCategory.uiCategory))
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
    override func layoutSubviews() {
        super.layoutSubviews()
        guard isFirstResponder, window != nil, bounds.height > 0,
              let selection = selectedTextRange else { return }
        scrollRectToVisible(caretRect(for: selection.start).insetBy(dx: 0, dy: -4), animated: false)
    }
}
