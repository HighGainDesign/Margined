import AppKit
import XCTest
@testable import Margined

@MainActor
final class ReaderUndoTests: XCTestCase {
    func testFindTextUndoRedoDoesNotChangeSavedCheckmarks() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".md")
        try "- [ ] Task\n".write(to: file, atomically: true, encoding: .utf8)
        let reader = ReaderState(); reader.fileURL = file; reader.source = "- [ ] Task\n"; reader.render()
        defer { reader.stop(); try? FileManager.default.removeItem(at: file) }
        try await settle(reader)
        reader.checklistMode = true; reader.setTaskChecked(0, checked: true); try await settle(reader)
        let editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 80))
        let delegate = UndoWindowDelegate()
        let window = NSWindow(); window.isReleasedWhenClosed = false
        window.delegate = delegate; window.contentView = editor
        defer { window.close() }
        editor.allowsUndo = true
        delegate.manager.beginUndoGrouping()
        editor.insertText("Find query", replacementRange: NSRange(location: 0, length: 0))
        delegate.manager.endUndoGrouping()
        let actions = ReaderUndo(responder: editor, reader: reader)
        XCTAssertTrue(actions.canUndo)
        actions.undo(); try await settle(reader)
        XCTAssertEqual(editor.string, "")
        XCTAssertEqual(try MarkdownSource.read(file), "- [x] Task\n")
        XCTAssertTrue(actions.canRedo)
        actions.redo(); try await settle(reader)
        XCTAssertEqual(editor.string, "Find query")
        XCTAssertEqual(try MarkdownSource.read(file), "- [x] Task\n")

        delegate.manager.removeAllActions()
        XCTAssertFalse(actions.canUndo, "An empty text history must not fall back to checkbox history")
        let documentActions = ReaderUndo(responder: nil, reader: reader)
        XCTAssertTrue(documentActions.canUndo)
        documentActions.undo(); try await settle(reader)
        XCTAssertEqual(try MarkdownSource.read(file), "- [ ] Task\n")
        XCTAssertTrue(documentActions.canRedo)
        documentActions.redo(); try await settle(reader)
        XCTAssertEqual(try MarkdownSource.read(file), "- [x] Task\n")
    }

    private func settle(_ reader: ReaderState) async throws {
        for _ in 0..<200 {
            if !reader.isRendering && !reader.checklistSaving { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Checklist did not settle")
    }

    @MainActor private final class UndoWindowDelegate: NSObject, NSWindowDelegate {
        let manager = UndoManager()
        func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? { manager }
    }
}
