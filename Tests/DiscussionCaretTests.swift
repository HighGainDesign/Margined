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
        window.setContentSize(NSSize(width: 1120, height: 900)); window.makeKeyAndOrderFront(nil)
        defer { reader.discussions.discardDrafts(); reader.stop(); window.close(); try? FileManager.default.removeItem(at: file) }
        let rendered = await poll { reader.rendered?.discussions?.threads.count == 1 && !reader.isRendering }
        XCTAssertTrue(rendered); guard rendered else { return }
        reader.openDiscussion("t-caret")
        reader.discussions.setDraft((0..<80).map { "Reply line \($0)." }.joined(separator: "\n"), for: .thread("t-caret"))
        let panelReady = await poll { self.history(in: host.view) != nil }
        if !panelReady {
            print("MARGINED-CARET-MOUNT-FAIL selected=\(String(describing: reader.discussions.selection)) visible=\(reader.showDiscussions) rendering=\(reader.isRendering) error=\(String(describing: reader.errorMessage)) threads=\(reader.rendered?.discussions?.threads.count ?? -1) window=\(window.frame) visible=\(window.isVisible) active=\(NSApp.isActive) editor=\(String(describing: self.editor(in: host.view)?.string))")
            for web in webViews(in: host.view) {
                let content = try? await web.evaluateJavaScript("({articles:document.querySelectorAll('article').length,main:document.querySelector('main')?.textContent.slice(0,100)})")
                print("MARGINED-CARET-WEB label=\(String(describing: web.accessibilityLabel())) bounds=\(web.bounds) loading=\(web.isLoading) progress=\(web.estimatedProgress) content=\(String(describing: content))")
            }
        }
        XCTAssertTrue(panelReady); guard panelReady else { return }
        let history = try XCTUnwrap(self.history(in: host.view))
        XCTAssertGreaterThan(history.bounds.height, 300, "Selected history fills the focused pane instead of a fixed 240-point nested card")
        let mounted = await poll { self.editor(in: host.view)?.string.contains("Reply line 79.") == true }
        XCTAssertTrue(mounted); guard mounted else { return }
        let editor = try XCTUnwrap(self.editor(in: host.view))
        XCTAssertTrue(window.makeFirstResponder(editor))
        editor.moveToEndOfDocument(nil)
        let editorFrame = editor.convert(editor.visibleRect, to: host.view)
        XCTAssertTrue(host.view.bounds.insetBy(dx: -1, dy: -1).contains(editorFrame), "The pinned composer is wholly inside the inspector")
        XCTAssertNil(self.pane(in: host.view), "The selected pane must not wrap history and composer in another scrolling card")
        editor.insertText("\nVisible insertion marker.", replacementRange: NSRange(location: NSNotFound, length: 0))
        let visible = await poll {
            let caret = editor.firstRect(forCharacterRange: editor.selectedRange(), actualRange: nil)
            let local = editor.convert(window.convertFromScreen(caret), from: nil)
            return caret.height > 0 && editor.visibleRect.insetBy(dx: -1, dy: -1).contains(local)
        }
        XCTAssertTrue(visible, "The inserted line must be visible through both the editor and sidebar clipping regions")
        let draftUpdated = await poll { reader.discussions.drafts[.thread("t-caret")]?.body.hasSuffix("Visible insertion marker.") == true }
        XCTAssertTrue(draftUpdated)
        XCTAssertTrue(editor.undoManager?.canUndo == true, "The discussion editor retains native text Undo")
        editor.undoManager?.undo()
        let undone = await poll { reader.discussions.drafts[.thread("t-caret")]?.body.hasSuffix("Reply line 79.") == true }
        XCTAssertTrue(undone)
        editor.undoManager?.redo()
        let redone = await poll { reader.discussions.drafts[.thread("t-caret")]?.body.hasSuffix("Visible insertion marker.") == true }
        XCTAssertTrue(redone)
        for size in [NSSize(width: 960, height: 620), NSSize(width: 1200, height: 780)] {
            window.setContentSize(size); host.view.layoutSubtreeIfNeeded()
            let retained = await poll { self.editor(in: host.view)?.string.hasSuffix("Visible insertion marker.") == true }
            XCTAssertTrue(retained, "Resizing must keep the unposted reply")
        }
        let retainedEditor = try XCTUnwrap(self.editor(in: host.view))
        retainedEditor.setSelectedRange(NSRange(location: 15, length: 4))
        let draft = reader.discussions.drafts[.thread("t-caret")]?.body
        reader.discussions.selection = nil
        let list = await poll { self.editor(in: host.view) == nil }
        XCTAssertTrue(list, "Back to Discussions returns to summaries without a composer")
        reader.openDiscussion("t-caret")
        let reopened = await poll { self.editor(in: host.view)?.string == draft }
        XCTAssertTrue(reopened, "Returning from summaries retains the unposted reply")
        XCTAssertEqual(self.editor(in: host.view)?.selectedRange(), NSRange(location: 15, length: 4), "Back/reopen retains the native reply selection")
        retainedEditor.insertText("Obsolete outgoing edit", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(reader.discussions.drafts[.thread("t-caret")]?.body, draft, "A dismantled editor cannot send late text into the reopened draft")
        XCTAssertEqual(try Data(contentsOf: file), bytes)
    }

    private func webViews(in view: NSView) -> [WKWebView] {
        if let web = view as? WKWebView { return [web] }
        return view.subviews.flatMap { webViews(in: $0) }
    }
    private func history(in view: NSView) -> WKWebView? {
        if let web = view as? WKWebView, web.accessibilityLabel() == "Discussion history" { return web }
        for child in view.subviews { if let web = history(in: child) { return web } }
        return nil
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
