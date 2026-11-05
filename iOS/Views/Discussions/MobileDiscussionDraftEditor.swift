import SwiftUI
import UIKit

#if MARGINED_DRAFT_SCROLL_CALLBACK_DIAGNOSTIC
import Darwin
@MainActor enum DraftDismissalCallbackDiagnostic {
    private static var sequence = 0
    private(set) static var started: Double?, completed: Double?
    static func begin() -> Int {
        sequence += 1; started = CACurrentMediaTime(); completed = nil; return sequence
    }
    static func end(_ value: Int) { if value == sequence { completed = CACurrentMediaTime() } }
    static var snapshot: [String: Any] {
        ["started": started as Any? ?? NSNull(), "completed": completed as Any? ?? NSNull()]
    }
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
        #if MARGINED_DRAFT_SCROLL_CALLBACK_DIAGNOSTIC
        private struct ScrollEvent {
            let time: Double, offset: CGPoint
            let ownedDepth: Int, ownedCount: Int
            let dismissalCompleted: Double?
            let stack: [NSNumber]
        }
        private var scrollEvents: [ScrollEvent] = [], originalScrollEvents: [ScrollEvent] = []
        private var scrollTarget: Double?, capturedUnexpected = false
        private var originalCallbackCount = 0, callbackCount = 0
        func armScrollDiagnostic(target: Double) {
            scrollTarget = target; scrollEvents = []; callbackCount = 0; capturedUnexpected = false
        }
        func freezeOriginalScrollDiagnostic() {
            originalScrollEvents = scrollEvents; originalCallbackCount = callbackCount; scrollTarget = nil
        }
        func stopScrollDiagnostic() { scrollTarget = nil }
        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            guard let target = scrollTarget else { return }
            let offset = scrollView.contentOffset
            callbackCount += 1
            let unexpected = abs(Double(offset.y) - target) > 1 && !capturedUnexpected
            // Routine target callbacks cannot consume the trigger's slot.
            guard scrollEvents.count < 16 || unexpected else { return }
            if unexpected { capturedUnexpected = true }
            let editor = scrollView as? DiscussionDraftTextView
            if scrollEvents.count == 16 { scrollEvents.removeLast() }
            scrollEvents.append(ScrollEvent(time: CACurrentMediaTime(), offset: offset,
                ownedDepth: editor?.diagnosticOwnedRevealDepth ?? -1,
                ownedCount: editor?.diagnosticOwnedRevealCount ?? -1,
                dismissalCompleted: DraftDismissalCallbackDiagnostic.completed,
                stack: unexpected ? Thread.callStackReturnAddresses : []))
        }
        func scrollDiagnosticReport() -> [String: Any] {
            func records(_ events: [ScrollEvent]) -> [[String: Any]] {
                events.map { e in
                    ["time": e.time, "x": e.offset.x, "y": e.offset.y,
                     "ownedDepth": e.ownedDepth, "ownedCount": e.ownedCount,
                     "dismissalCompleted": e.dismissalCompleted as Any? ?? NSNull(),
                     "callbackStack": e.stack.map { number -> [String: String] in
                        let address = UInt(truncating: number)
                        var info = Dl_info()
                        guard let pointer = UnsafeRawPointer(bitPattern: address), dladdr(pointer, &info) != 0 else {
                            return ["address": String(address, radix: 16)]
                        }
                        return ["address": String(address, radix: 16),
                            "image": info.dli_fname.map { String(cString: $0) } ?? "",
                            "symbol": info.dli_sname.map { String(cString: $0) } ?? "",
                            "imageBase": info.dli_fbase.map { String(UInt(bitPattern: $0), radix: 16) } ?? ""]
                     }]
                }
            }
            return ["original": records(originalScrollEvents), "originalCallbackCount": originalCallbackCount,
                "viewportChangeCalibration": records(scrollEvents), "viewportCallbackCount": callbackCount]
        }
        #endif
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
    #if MARGINED_DRAFT_SCROLL_CALLBACK_DIAGNOSTIC
    var diagnosticOwnedRevealDepth = 0, diagnosticOwnedRevealCount = 0
    #endif
    private struct Layout: Equatable {
        let size: CGSize
        let insets: UIEdgeInsets
        let font: UIFont?
        let selection: NSRange
        let focused: Bool
    }
    private var lastLayout: Layout?
    override func layoutSubviews() {
        super.layoutSubviews()
        guard isFirstResponder, window != nil, bounds.height > 0,
              let selection = selectedTextRange else { lastLayout = nil; return }
        let layout = Layout(size: bounds.size, insets: adjustedContentInset,
                            font: font, selection: selectedRange, focused: isFirstResponder)
        let changed = lastLayout != layout
        lastLayout = layout
        // A scroll changes bounds.origin, but does not change this key. Let the
        // user browse a long draft without an unrelated layout moving it back.
        guard changed else { return }
        #if MARGINED_DRAFT_SCROLL_CALLBACK_DIAGNOSTIC
        diagnosticOwnedRevealDepth += 1; diagnosticOwnedRevealCount += 1
        defer { diagnosticOwnedRevealDepth -= 1 }
        #endif
        scrollRectToVisible(caretRect(for: selection.start).insetBy(dx: 0, dy: -4), animated: false)
    }
}
