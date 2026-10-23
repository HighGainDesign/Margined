import AppKit
import XCTest
@testable import Margined

final class MarkdownStreamTests: XCTestCase {
    @MainActor
    func testOptionalSourceMetadataAndChannelIsNotModified() throws {
        let board = NSPasteboard(name: NSPasteboard.Name("MarginedTests.Stream.\(UUID())"))
        defer { board.releaseGlobally() }
        let stream = MarkdownStream(pasteboard: board)
        XCTAssertEqual(try stream.read(after: nil)?.update, .waiting)
        write("<!--\n source: Bear.app\n-->\n# Other editor", to: board)
        XCTAssertEqual(try stream.read(after: nil)?.update, .text("# Other editor", source: "Bear"))
        write("# Not a Drafts stream", to: board)
        XCTAssertEqual(try stream.read(after: nil)?.update, .text("# Not a Drafts stream", source: nil))
        let payload = "<!--\n    source: Drafts.app\n-->\n\n# Café 日本語\n\nA & B + 100%."
        write(payload, to: board)
        let count = board.changeCount
        XCTAssertEqual(try stream.read(after: nil)?.update, .text("# Café 日本語\n\nA & B + 100%.", source: "Drafts"))
        XCTAssertNil(try stream.read(after: count))
        XCTAssertEqual(board.changeCount, count)
        XCTAssertEqual(board.string(forType: .string), payload)
        write("<!--\nsource: Drafts.app\n-->\n\n", to: board)
        XCTAssertEqual(try stream.read(after: nil)?.update, .text("", source: "Drafts"))
    }

    @MainActor
    func testOrdinaryCommentsAndInvalidSourceMetadataRemainMarkdown() throws {
        let board = NSPasteboard(name: NSPasteboard.Name("MarginedTests.Stream.\(UUID())"))
        defer { board.releaseGlobally() }
        let stream = MarkdownStream(pasteboard: board)
        for text in ["<!-- a normal comment -->\n# Text", "<!--\nsource: \n-->\n# Text",
                     "<!--\nsource: " + String(repeating: "a", count: 129) + "\n-->\n# Text"] {
            write(text, to: board)
            XCTAssertEqual(try stream.read(after: nil)?.update, .text(text, source: nil))
        }
        write("<!--\nsource: /Applications/Example.app\n-->\n# Text", to: board)
        XCTAssertEqual(try stream.read(after: nil)?.update, .text("# Text", source: "Example"))
    }

    @MainActor
    func testSourceChangesEvenWhenMarkdownStaysTheSame() async throws {
        let board = NSPasteboard(name: NSPasteboard.Name("MarginedTests.Stream.\(UUID())"))
        defer { board.releaseGlobally() }
        let reader = ReaderState()
        reader.isStreamingPreview = true
        let task = Task { await reader.watchStream(MarkdownStream(pasteboard: board)) }
        defer { task.cancel(); reader.stop() }
        writeDraft("# Shared text", to: board)
        try await waitForSource("# Shared text", reader: reader)
        XCTAssertEqual(reader.streamSourceName, "Drafts")
        write("<!--\nsource: Example.app\n-->\n# Shared text", to: board)
        for _ in 0..<100 where reader.streamSourceName != "Example" {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(reader.streamSourceName, "Example")
        XCTAssertEqual(reader.source, "# Shared text")
        write("# Unattributed", to: board)
        try await waitForSource("# Unattributed", reader: reader)
        XCTAssertNil(reader.streamSourceName)
    }

    @MainActor
    func testOversizeAndInvalidUTF8AreRejected() throws {
        let board = NSPasteboard(name: NSPasteboard.Name("MarginedTests.Stream.\(UUID())"))
        defer { board.releaseGlobally() }
        let stream = MarkdownStream(pasteboard: board)
        board.clearContents()
        board.setData(Data(repeating: 65, count: MarkdownSource.maximumBytes + 1), forType: .string)
        XCTAssertThrowsError(try stream.read(after: nil))
        board.clearContents()
        board.setData(Data([0xFF, 0xFE]), forType: .string)
        XCTAssertThrowsError(try stream.read(after: nil))
    }

    @MainActor
    func testReceiverPausesResumesClearsAndStopsWithoutWriting() async throws {
        let board = NSPasteboard(name: NSPasteboard.Name("MarginedTests.Stream.\(UUID())"))
        defer { board.releaseGlobally() }
        let reader = ReaderState()
        reader.isStreamingPreview = true
        let task = Task { await reader.watchStream(MarkdownStream(pasteboard: board)) }
        defer { task.cancel(); reader.stop() }
        writeDraft("# First draft", to: board)
        try await waitForSource("# First draft", reader: reader)
        reader.streamPaused = true
        writeDraft("# Another draft", to: board)
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertEqual(reader.source, "# First draft")
        reader.streamPaused = false
        try await waitForSource("# Another draft", reader: reader)
        writeDraft("", to: board)
        try await waitForSource("", reader: reader)
        XCTAssertTrue(reader.streamIsReceiving)
        XCTAssertNil(reader.fileURL)
        XCTAssertEqual(reader.changes.count, 0)
        task.cancel()
        await task.value
        writeDraft("# After close", to: board)
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(reader.source, "")
        XCTAssertTrue(board.string(forType: .string)?.contains("# After close") == true)
    }

    @MainActor
    func testInvalidStreamRetainsLastPreviewAndRecovers() async throws {
        let board = NSPasteboard(name: NSPasteboard.Name("MarginedTests.Stream.\(UUID())"))
        defer { board.releaseGlobally() }
        let reader = ReaderState()
        reader.isStreamingPreview = true
        let task = Task { await reader.watchStream(MarkdownStream(pasteboard: board)) }
        defer { task.cancel(); reader.stop() }
        writeDraft("# Valid", to: board)
        try await waitForSource("# Valid", reader: reader)
        board.clearContents()
        board.setData(Data([0xFF]), forType: .string)
        for _ in 0..<50 where reader.streamError == nil { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertNotNil(reader.streamError)
        XCTAssertEqual(reader.source, "# Valid")
        writeDraft("# Recovered", to: board)
        try await waitForSource("# Recovered", reader: reader)
        XCTAssertNil(reader.streamError)
    }

    @MainActor
    func testStreamingDocumentIsReadOnlyAndHasNoFileBase() {
        let document = MarkdownDocument(streamingPreview: true)
        XCTAssertTrue(document.reader.isStreamingPreview)
        XCTAssertFalse(document.isDocumentEdited)
        XCTAssertNil(document.fileURL)
        document.close()
        XCTAssertTrue(document.reader.streamPaused)
    }

    @MainActor
    private func write(_ text: String, to board: NSPasteboard) {
        board.clearContents()
        board.setString(text, forType: .string)
    }

    @MainActor
    private func writeDraft(_ text: String, to board: NSPasteboard) {
        write("<!--\n source: Drafts.app\n-->\n\n" + text, to: board)
    }

    @MainActor
    private func waitForSource(_ text: String, reader: ReaderState) async throws {
        for _ in 0..<100 {
            if reader.source == text { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Live preview did not receive the expected update")
    }
}
