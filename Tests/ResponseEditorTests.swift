import AppKit
import SwiftUI
import XCTest
@testable import Margined

@MainActor
final class ResponseEditorTests: XCTestCase {
    func testResponseControlsDoNotRestoreFocusAfterThePageIsReleased() {
        let reader = ReaderState()
        let coordinator = MarkdownWebView.Coordinator(reader: reader)
        XCTAssertNil(coordinator.webView)
        let arguments = coordinator.responseArguments(enabled: false, token: "closed-page")
        XCTAssertEqual(arguments["restoreFocus"] as? Bool, false)
        XCTAssertEqual(arguments["enabled"] as? Bool, false)
        reader.stop()
    }

    func testUnorderedNativeEditorUsesTypingUndoAndRetainsDraftAcrossResize() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".md")
        let source = "**Notes (short answer):** Original\n"
        try Data(source.utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let output = try await MarkdownRenderer.shared.render(source, mapTasks: true)
        let draft = ShortAnswerDraft(field: try XCTUnwrap(output.responses.answers.first),
            expected: try SourceFileEdit.read(file), context: UUID())
        let host = NSHostingView(rootView: ShortAnswerEditor(draft: draft, canSave: true,
            unavailableReason: nil, onSave: {}, onCancel: {}))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 420),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        let input = try XCTUnwrap(editor(in: host))
        XCTAssertEqual(input.accessibilityLabel(), "Notes")
        XCTAssertGreaterThan(input.bounds.width, 200, "The native input must fill its scroll view and wrap text")
        window.makeFirstResponder(input)
        input.insertText(" changed", replacementRange: NSRange(location: input.string.utf16.count, length: 0))
        XCTAssertEqual(draft.text, "Original changed")
        XCTAssertTrue(input.undoManager?.canUndo == true)
        ReaderUndo(responder: input, reader: nil).undo()
        for _ in 0..<20 where draft.text != "Original" { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(input.string, "Original", "Native text after Undo")
        XCTAssertEqual(draft.text, "Original")
        ReaderUndo(responder: input, reader: nil).redo()
        XCTAssertEqual(draft.text, "Original changed")
        window.setContentSize(NSSize(width: 700, height: 500)); host.layoutSubtreeIfNeeded()
        XCTAssertTrue(editor(in: host) === input)
        XCTAssertEqual(input.string, "Original changed")
        XCTAssertEqual(try Data(contentsOf: file), Data(source.utf8))
        XCTAssertFalse(window.isVisible, "This local native probe must never foreground a window")
    }

    private func editor(in view: NSView) -> NSTextView? {
        if let text = view as? NSTextView, text.accessibilityIdentifier() == "short-answer-input" { return text }
        return view.subviews.lazy.compactMap { self.editor(in: $0) }.first
    }
}
