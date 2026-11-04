import SwiftUI
import UIKit

#if MARGINED_DRAFT_REVEAL_DIAGNOSTIC
@MainActor
protocol DiscussionDraftRevealDiagnostics: AnyObject {
    func freezeDraftRevealDiagnostics()
    func draftRevealDiagnosticReport() -> [String]
}
#endif

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
    #if MARGINED_DRAFT_REVEAL_DIAGNOSTIC
    private struct Reveal {
        let sequence: Int
        let time: CFTimeInterval
        let previousSize: CGSize?
        let size: CGSize
        let previousSelection: NSRange?
        let selection: NSRange
        let fontChanged: Bool
        let insetsChanged: Bool
        let resets: Int
        let before: CGPoint
        let after: CGPoint
    }
    private var revealEntries: [Reveal] = []
    private var frozenReveals: [Reveal]?
    private var revealSequence = 0
    private var resetCount = 0

    func freezeDraftRevealDiagnostics() { frozenReveals = revealEntries }
    func draftRevealDiagnosticReport() -> [String] {
        (frozenReveals ?? revealEntries).map { entry in
            let record: [String: Any] = ["sequence": entry.sequence, "time": entry.time,
                "previousSize": String(describing: entry.previousSize), "size": String(describing: entry.size),
                "previousSelection": String(describing: entry.previousSelection), "selection": String(describing: entry.selection),
                "fontChanged": entry.fontChanged, "insetsChanged": entry.insetsChanged, "resets": entry.resets,
                "before": String(describing: entry.before), "after": String(describing: entry.after)]
            guard let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]),
                  let json = String(data: data, encoding: .utf8) else { return "{\"serializationFailure\":true}" }
            return json
        }
    }
    #endif
    override func layoutSubviews() {
        super.layoutSubviews()
        guard isFirstResponder, window != nil, bounds.height > 0,
              let selection = selectedTextRange else {
            #if MARGINED_DRAFT_REVEAL_DIAGNOSTIC
            resetCount += 1
            #endif
            lastLayout = nil; return
        }
        let layout = Layout(size: bounds.size, insets: adjustedContentInset,
                            font: font, selection: selectedRange, focused: isFirstResponder)
        let changed = lastLayout != layout
        #if MARGINED_DRAFT_REVEAL_DIAGNOSTIC
        // No extra text/container metrics, pre-super reads or retained UIFonts.
        let previousSize = changed ? lastLayout?.size : nil
        let previousSelection = changed ? lastLayout?.selection : nil
        let fontChanged = changed && lastLayout?.font != layout.font
        let insetsChanged = changed && lastLayout?.insets != layout.insets
        #endif
        lastLayout = layout
        // A scroll changes bounds.origin, but does not change this key. Let the
        // user browse a long draft without an unrelated layout moving it back.
        guard changed else { return }
        #if MARGINED_DRAFT_REVEAL_DIAGNOSTIC
        let beforeReveal = contentOffset
        let revealTime = CACurrentMediaTime()
        #endif
        scrollRectToVisible(caretRect(for: selection.start).insetBy(dx: 0, dy: -4), animated: false)
        #if MARGINED_DRAFT_REVEAL_DIAGNOSTIC
        revealSequence += 1
        let entry = Reveal(sequence: revealSequence, time: revealTime,
            previousSize: previousSize, size: layout.size,
            previousSelection: previousSelection, selection: layout.selection,
            fontChanged: fontChanged, insetsChanged: insetsChanged, resets: resetCount,
            before: beforeReveal, after: contentOffset)
        if revealEntries.count == 64 { revealEntries.removeFirst() }
        revealEntries.append(entry)
        #endif
    }
}
#if MARGINED_DRAFT_REVEAL_DIAGNOSTIC
extension DiscussionDraftTextView: DiscussionDraftRevealDiagnostics {}
#endif
