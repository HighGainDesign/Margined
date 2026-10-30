import AppKit
import SwiftUI
import WebKit
import XCTest
@testable import Margined

@MainActor
final class DiscussionCaretTests: XCTestCase {
    func testTypingAtTheEndOfALongReplyKeepsTheCaretVisibleAndPreservesTheFile() async throws {
        try await activateNativeTestApplication()
        let prose = "# Plan\n\nA passage to discuss.\n"
        let thread = DiscussionThread(id: "t-caret", state: .open,
            target: .init(type: "TextQuoteSelector", exact: "A passage to discuss.", prefix: "Plan", suffix: "", section: "Plan"),
            messages: [.init(id: "m-caret", author: "Reviewer", created: "2026-10-27T10:00:00Z",
                body: "A saved message.", inReplyTo: nil)], resolvedBy: nil, resolved: nil, attachmentHistory: [])
        let bytes = try MarkdownSourceEdits.apply(DiscussionEdits.splices(for: .newThread(thread), in: DiscussionCodec.parse(prose)),
            to: Data(prose.utf8), expectedSource: prose)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".md")
        try bytes.write(to: file)
        let reader = ReaderState(); reader.fileURL = file; reader.source = try MarkdownSource.decode(bytes); reader.render()
        let host = NSHostingController(rootView: ReaderView(reader: reader))
        let window = NSWindow(contentViewController: host)
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 1120, height: 620)); window.makeKeyAndOrderFront(nil)
        defer { reader.discussions.discardDrafts(); reader.stop(); window.close(); try? FileManager.default.removeItem(at: file) }
        let rendered = await poll { reader.rendered?.discussions?.threads.count == 1 && !reader.isRendering }
        XCTAssertTrue(rendered); guard rendered else { return }
        reader.openDiscussion("t-caret")
        reader.discussions.setDraft((0..<80).map { "Reply line \($0)." }.joined(separator: "\n"), for: .thread("t-caret"))
        let panelReady = await poll { self.pane(in: host.view) != nil }
        XCTAssertTrue(panelReady); guard panelReady else { return }
        let pane = try XCTUnwrap(self.pane(in: host.view))
        let document = try XCTUnwrap(pane.documentView)
        document.scrollToVisible(NSRect(x: 0, y: document.isFlipped ? document.bounds.height - 1 : 0, width: 1, height: 1))
        let mounted = await poll { self.editor(in: host.view)?.string.contains("Reply line 79.") == true }
        XCTAssertTrue(mounted); guard mounted else { return }
        let editor = try XCTUnwrap(self.editor(in: host.view))
        XCTAssertTrue(window.makeFirstResponder(editor))
        editor.moveToEndOfDocument(nil)
        // The reader browses the history while the editor retains focus, then
        // resumes typing. The next input must reveal the insertion point.
        let origin = pane.contentView.bounds.origin
        pane.contentView.scroll(to: NSPoint(x: origin.x, y: origin.y + (document.isFlipped ? -100 : 100)))
        pane.reflectScrolledClipView(pane.contentView)
        editor.insertText("\nVisible insertion marker.", replacementRange: NSRange(location: NSNotFound, length: 0))
        let visible = await poll {
            let caret = editor.firstRect(forCharacterRange: editor.selectedRange(), actualRange: nil)
            let local = editor.convert(window.convertFromScreen(caret), from: nil)
            return caret.height > 0 && editor.visibleRect.insetBy(dx: -1, dy: -1).contains(local)
        }
        XCTAssertTrue(visible, "The inserted line must be visible through both the editor and sidebar clipping regions")
        XCTAssertTrue(reader.discussions.drafts[.thread("t-caret")]?.body.hasSuffix("Visible insertion marker.") == true)
        for size in [NSSize(width: 960, height: 620), NSSize(width: 1200, height: 780)] {
            window.setContentSize(size); host.view.layoutSubtreeIfNeeded()
            let retained = await poll { self.editor(in: host.view)?.string.hasSuffix("Visible insertion marker.") == true }
            XCTAssertTrue(retained, "Resizing must keep the unposted reply")
        }
        XCTAssertEqual(try Data(contentsOf: file), bytes)
    }

    private func editor(in view: NSView) -> NSTextView? {
        if let text = view as? NSTextView, text.isEditable { return text }
        for child in view.subviews { if let text = editor(in: child) { return text } }
        return nil
    }
    private func pane(in view: NSView) -> NSScrollView? {
        if view is WKWebView { return nil }
        if let scroll = view as? NSScrollView, let document = scroll.documentView,
           scroll.contentView.bounds.height > 180, document.bounds.height > scroll.contentView.bounds.height + 60 { return scroll }
        for child in view.subviews { if let scroll = pane(in: child) { return scroll } }
        return nil
    }
    private func poll(_ predicate: () -> Bool) async -> Bool {
        for _ in 0..<150 {
            if predicate() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return false
    }
}
