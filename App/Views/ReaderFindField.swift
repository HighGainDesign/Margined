import AppKit
import SwiftUI

/// A native field owns its window's focus request; SwiftUI owns the query.
struct ReaderFindField: NSViewRepresentable {
    @Binding var text: String
    let focusGeneration: Int
    let submit: () -> Void
    let cancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> Field {
        let field = Field()
        field.placeholderString = String(localized: "Find in document")
        field.setAccessibilityLabel(String(localized: "Find in document"))
        field.isEditable = true
        field.isSelectable = true
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        field.font = .systemFont(ofSize: NSFont.systemFontSize)
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.delegate = context.coordinator
        field.target = context.coordinator
        field.action = #selector(Coordinator.searchChanged(_:))
        field.sendsSearchStringImmediately = true
        return field
    }

    func updateNSView(_ field: Field, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
        field.requestFocus(focusGeneration)
    }

    static func dismantleNSView(_ field: Field, coordinator: Coordinator) { field.stop() }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: ReaderFindField
        init(_ parent: ReaderFindField) { self.parent = parent }

        @objc func searchChanged(_ field: NSSearchField) { parent.text = field.stringValue }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy command: Selector) -> Bool {
            if command == #selector(NSResponder.insertNewline(_:)) { parent.submit(); return true }
            if command == #selector(NSResponder.cancelOperation(_:)) { parent.cancel(); return true }
            return false
        }
    }

    final class Field: NSSearchField {
        private var requestedGeneration = -1
        private var appliedGeneration = -1
        private var focusTask: Task<Void, Never>?

        func requestFocus(_ generation: Int) {
            requestedGeneration = generation
            scheduleFocus()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            scheduleFocus()
        }

        private func scheduleFocus() {
            guard requestedGeneration >= 0, requestedGeneration != appliedGeneration else { return }
            focusTask?.cancel()
            focusTask = Task { @MainActor [weak self] in
                await Task.yield()
                guard !Task.isCancelled, let self, let window else { return }
                if window.makeFirstResponder(self) { appliedGeneration = requestedGeneration }
            }
        }

        func stop() { focusTask?.cancel(); focusTask = nil }
    }
}
