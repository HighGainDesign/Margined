import SwiftUI
import UIKit

#if MARGINED_DRAFT_LAYOUT_DIAGNOSTIC
@MainActor
protocol DiscussionDraftLayoutDiagnostics: AnyObject {
    func freezeDraftLayoutDiagnostics()
    func draftLayoutDiagnosticReport() -> [String]
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
    private struct DiagnosticEntry {
        let sequence: Int
        let phase: String
        let time: CFTimeInterval
        let offset: CGPoint
        let bounds: CGRect
        let contentSize: CGSize
        let focused: Bool
        let windowBounds: CGRect?
        let windowFrame: CGRect?
        let layout: Layout?
        let changed: Bool?
    }
    private var diagnosticEntries: [DiagnosticEntry] = []
    private var diagnosticFrozen: [DiagnosticEntry]?
    private var diagnosticSequence = 0

    private func diagnosticRecord(_ phase: String, layout: Layout? = nil, changed: Bool? = nil) {
        diagnosticSequence += 1
        // Value snapshots only. No KVO, responder overrides, formatting, caret
        // reads or text-layout calls run on the layout path.
        let entry = DiagnosticEntry(sequence: diagnosticSequence, phase: phase, time: CACurrentMediaTime(),
            offset: contentOffset, bounds: bounds, contentSize: contentSize,
            focused: isFirstResponder, windowBounds: window?.bounds, windowFrame: window?.frame,
            layout: layout ?? lastLayout, changed: changed)
        if diagnosticEntries.count == 300 { diagnosticEntries.removeFirst() }
        diagnosticEntries.append(entry)
    }

    func freezeDraftLayoutDiagnostics() { diagnosticFrozen = diagnosticEntries }

    func draftLayoutDiagnosticReport() -> [String] {
        let records: [[String: Any]] = (diagnosticFrozen ?? diagnosticEntries).map { entry in
            var result: [String: Any] = ["sequence": entry.sequence, "phase": entry.phase,
                "time": entry.time, "offset": String(describing: entry.offset),
                "bounds": String(describing: entry.bounds), "contentSize": String(describing: entry.contentSize),
                "focused": entry.focused, "windowBounds": String(describing: entry.windowBounds),
                "windowFrame": String(describing: entry.windowFrame)]
            if let key = entry.layout {
                result["key"] = ["size": String(describing: key.size), "insets": String(describing: key.insets),
                    "selection": String(describing: key.selection), "focused": key.focused,
                    "font": key.font?.description ?? "nil",
                    "fontDescriptor": key.font?.fontDescriptor.description ?? "nil"]
            }
            if let changed = entry.changed { result["changed"] = changed }
            return result
        }
        return records.map { record in
            guard let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]),
                  let json = String(data: data, encoding: .utf8) else {
                return "{\"diagnosticSerializationFailure\":true}"
            }
            return json
        }
    }
    #endif
    override func layoutSubviews() {
        #if MARGINED_DRAFT_LAYOUT_DIAGNOSTIC
        diagnosticRecord("before-super")
        #endif
        super.layoutSubviews()
        #if MARGINED_DRAFT_LAYOUT_DIAGNOSTIC
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
        #endif
        scrollRectToVisible(caretRect(for: selection.start).insetBy(dx: 0, dy: -4), animated: false)
        #if MARGINED_DRAFT_LAYOUT_DIAGNOSTIC
        diagnosticRecord("after-owned-reveal")
        #endif
    }
}
#if MARGINED_DRAFT_LAYOUT_DIAGNOSTIC
extension DiscussionDraftTextView: DiscussionDraftLayoutDiagnostics {}
#endif
