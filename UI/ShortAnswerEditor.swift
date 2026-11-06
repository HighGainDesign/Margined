import SwiftUI

/// Editing is local until Save; file history never owns this input's Undo manager.
struct ShortAnswerEditor: View {
    @Bindable var draft: ShortAnswerDraft
    let canSave: Bool
    let unavailableReason: String?
    let onSave: () -> Void
    let onCancel: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(draft.field.label).font(.headline).accessibilityAddTraits(.isHeader)
                Text("One paragraph, up to 1,000 characters.").font(.subheadline).foregroundStyle(.secondary)
                ShortAnswerInput(draft: draft)
                    .frame(height: 180)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.secondary.opacity(0.4)))
                if let message = draft.error ?? unavailableReason ?? draft.validationMessage {
                    Text(message).font(.callout).foregroundStyle(.secondary)
                        .accessibilityIdentifier("short-answer-validation")
                }
                Text("\(draft.text.count) / 1,000").font(.caption).foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                        .disabled(draft.saving).accessibilityIdentifier("short-answer-cancel")
                    Button("Save") { draft.endEditing?(); onSave() }
                        .keyboardShortcut(.defaultAction).disabled(!canSave)
                        .accessibilityIdentifier("short-answer-save")
                }
            }
            .padding(20)
        }
        #if os(macOS)
        .frame(minWidth: 360, idealWidth: 480, minHeight: 350, idealHeight: 390)
        #endif
        .interactiveDismissDisabled(draft.saving || draft.stale)
    }
}

#if os(iOS)
import UIKit

private struct ShortAnswerInput: UIViewRepresentable {
    let draft: ShortAnswerDraft
    func makeCoordinator() -> Coordinator { Coordinator(draft) }
    func makeUIView(context: Context) -> AnswerTextView {
        let view = AnswerTextView()
        view.delegate = context.coordinator
        view.text = draft.text
        view.backgroundColor = .clear
        view.adjustsFontForContentSizeCategory = true
        view.textContainerInset = UIEdgeInsets(top: 10, left: 6, bottom: 10, right: 6)
        view.accessibilityIdentifier = "short-answer-input"
        view.accessibilityLabel = draft.field.label
        draft.endEditing = { [weak view, weak draft] in
            view?.unmarkText()
            if let view { draft?.text = view.text }
            view?.resignFirstResponder()
        }
        return view
    }
    func updateUIView(_ view: AnswerTextView, context: Context) {
        view.isEditable = !draft.saving
        let font = UIFont.preferredFont(forTextStyle: .body, compatibleWith: view.traitCollection)
        if view.font != font { view.font = font }
        if context.coordinator.lastText != draft.text {
            let selection = view.selectedRange
            view.text = draft.text
            let count = view.text.utf16.count
            view.selectedRange = NSRange(location: min(selection.location, count), length: min(selection.length, max(0, count - selection.location)))
            context.coordinator.lastText = draft.text
        }
        if view.textColor != UIColor.label { view.textColor = .label }
    }
    @MainActor final class Coordinator: NSObject, UITextViewDelegate {
        let draft: ShortAnswerDraft
        var lastText: String
        init(_ draft: ShortAnswerDraft) { self.draft = draft; lastText = draft.text }
        func textViewDidChange(_ view: UITextView) { lastText = view.text; draft.text = view.text }
    }
}

private final class AnswerTextView: UITextView {
    // UITextView supplies its own text-input Undo manager. Replacing it bypasses
    // UIKit's registration of keyboard edits.
    private var didFocus = false
    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil, !didFocus else { return }
        didFocus = true
        DispatchQueue.main.async { [weak self] in
            guard let self, window != nil else { return }
            becomeFirstResponder()
        }
    }
}
#elseif os(macOS)
import AppKit

private struct ShortAnswerInput: NSViewRepresentable {
    let draft: ShortAnswerDraft
    func makeCoordinator() -> Coordinator { Coordinator(draft) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        let view = AnswerTextView(frame: .zero)
        view.delegate = context.coordinator
        context.coordinator.textView = view
        view.isRichText = false; view.importsGraphics = false; view.allowsUndo = true
        view.drawsBackground = false; view.font = .preferredFont(forTextStyle: .body)
        view.textContainerInset = NSSize(width: 10, height: 10)
        view.isVerticallyResizable = true; view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        view.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        view.string = draft.text
        view.setAccessibilityIdentifier("short-answer-input"); view.setAccessibilityLabel(draft.field.label)
        scroll.documentView = view
        draft.endEditing = { [weak view, weak draft] in
            view?.unmarkText()
            if let view { draft?.text = view.string }
            view?.window?.makeFirstResponder(nil)
        }
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? AnswerTextView else { return }
        view.isEditable = !draft.saving
        // AppKit may lay out SwiftUI during Undo, before textDidChange publishes
        // the native edit. Apply only a NEW model value, never the prior value
        // over an in-progress native edit.
        if context.coordinator.lastText != draft.text {
            let selection = view.selectedRange(), count = draft.text.utf16.count
            view.string = draft.text
            view.setSelectedRange(NSRange(location: min(selection.location, count), length: min(selection.length, max(0, count - selection.location))))
            context.coordinator.lastText = draft.text
        }
    }
    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        let draft: ShortAnswerDraft
        var lastText: String
        private let typingUndo = UndoManager()
        weak var textView: NSTextView?
        init(_ draft: ShortAnswerDraft) {
            self.draft = draft; lastText = draft.text
            super.init()
            // Direct menu Undo changes the native storage without necessarily
            // sending textDidChange. Publish after the entire group completes.
            for name in [Notification.Name.NSUndoManagerDidUndoChange, .NSUndoManagerDidRedoChange] {
                NotificationCenter.default.addObserver(self, selector: #selector(historyChanged), name: name, object: typingUndo)
            }
        }
        deinit { NotificationCenter.default.removeObserver(self) }
        @objc private func historyChanged(_ notification: Notification) {
            guard let view = textView else { return }
            lastText = view.string; draft.text = view.string
        }
        func undoManager(for view: NSTextView) -> UndoManager? { typingUndo }
        func textDidChange(_ notification: Notification) {
            if let view = notification.object as? NSTextView { lastText = view.string; draft.text = view.string }
        }
    }
}

private final class AnswerTextView: NSTextView {
    private var didFocus = false
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, !didFocus else { return }
        didFocus = true
        DispatchQueue.main.async { [weak self] in
            guard let self, window != nil else { return }
            window?.makeFirstResponder(self)
        }
    }
}
#endif
