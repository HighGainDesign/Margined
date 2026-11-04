import SwiftUI
import UIKit

#if MARGINED_DRAFT_LAYOUT_DIAGNOSTIC
@MainActor
protocol DiscussionDraftLayoutDiagnostics: AnyObject {
    func draftLayoutDiagnosticReport() -> String
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
    #if MARGINED_DRAFT_LAYOUT_DIAGNOSTIC
    private var diagnosticEntries: [[String: Any]] = []
    private var diagnosticSequence = 0
    private var diagnosticSuperDepth = 0
    private var diagnosticRevealDepth = 0
    private var diagnosticOffsetObservation: NSKeyValueObservation?

    private func diagnosticRecord(_ phase: String, layout: Layout? = nil, changed: Bool? = nil) {
        diagnosticSequence += 1
        // No caret/text-layout getters: retain the key already calculated by
        // the existing implementation, plus native scroll-view value fields.
        let cached = layout ?? lastLayout
        var entry: [String: Any] = ["sequence": diagnosticSequence, "phase": phase,
            "time": CACurrentMediaTime(), "offset": String(describing: contentOffset),
            "bounds": String(describing: bounds), "contentSize": String(describing: contentSize),
            "focused": isFirstResponder, "attached": window != nil,
            "windowBounds": String(describing: window?.bounds), "windowFrame": String(describing: window?.frame),
            "superDepth": diagnosticSuperDepth, "revealDepth": diagnosticRevealDepth]
        if let cached {
            entry["key"] = ["size": String(describing: cached.size),
                "insets": String(describing: cached.insets), "selection": String(describing: cached.selection),
                "font": cached.font?.fontName ?? "nil", "fontSize": cached.font?.pointSize ?? 0,
                "focused": cached.focused]
        }
        if let changed { entry["changed"] = changed }
        if diagnosticEntries.count == 300 { diagnosticEntries.removeFirst() }
        diagnosticEntries.append(entry)
    }

    func draftLayoutDiagnosticReport() -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: diagnosticEntries, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else { return "[]" }
        return json
    }

    override func becomeFirstResponder() -> Bool {
        diagnosticRecord("before-become-first-responder")
        let result = super.becomeFirstResponder()
        diagnosticRecord("after-become-first-responder")
        return result
    }
    override func resignFirstResponder() -> Bool {
        diagnosticRecord("before-resign-first-responder")
        let result = super.resignFirstResponder()
        diagnosticRecord("after-resign-first-responder")
        return result
    }
    #endif
    override func layoutSubviews() {
        #if MARGINED_DRAFT_LAYOUT_DIAGNOSTIC
        if diagnosticOffsetObservation == nil {
            diagnosticOffsetObservation = observe(\.contentOffset) { [weak self] _, _ in
                guard Thread.isMainThread else { return }
                MainActor.assumeIsolated { self?.diagnosticRecord("offset-change") }
            }
        }
        diagnosticRecord("before-super")
        diagnosticSuperDepth += 1
        #endif
        super.layoutSubviews()
        #if MARGINED_DRAFT_LAYOUT_DIAGNOSTIC
        diagnosticSuperDepth -= 1
        diagnosticRecord("after-super")
        #endif
        guard isFirstResponder, window != nil, bounds.height > 0,
              let selection = selectedTextRange else {
            #if MARGINED_DRAFT_LAYOUT_DIAGNOSTIC
            diagnosticRecord("guard-reset")
            #endif
            lastLayout = nil; return
        }
        let layout = Layout(size: bounds.size, insets: adjustedContentInset,
                            font: font, selection: selectedRange, focused: isFirstResponder)
        let changed = lastLayout != layout
        #if MARGINED_DRAFT_LAYOUT_DIAGNOSTIC
        diagnosticRecord("current-key", layout: layout, changed: changed)
        #endif
        lastLayout = layout
        // A scroll changes bounds.origin, but does not change this key. Let the
        // user browse a long draft without an unrelated layout moving it back.
        guard changed else { return }
        #if MARGINED_DRAFT_LAYOUT_DIAGNOSTIC
        diagnosticRecord("before-owned-reveal")
        diagnosticRevealDepth += 1
        #endif
        scrollRectToVisible(caretRect(for: selection.start).insetBy(dx: 0, dy: -4), animated: false)
        #if MARGINED_DRAFT_LAYOUT_DIAGNOSTIC
        diagnosticRevealDepth -= 1
        diagnosticRecord("after-owned-reveal")
        #endif
    }
}
#if MARGINED_DRAFT_LAYOUT_DIAGNOSTIC
extension DiscussionDraftTextView: DiscussionDraftLayoutDiagnostics {}
#endif
