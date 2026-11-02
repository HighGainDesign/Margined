import AppKit
import SwiftUI
import WebKit
import XCTest
@testable import Margined

@MainActor
final class DiscussionSelectionMenuTests: XCTestCase {
    func testNativeMenuCreatesOneUnicodeDraftAndPreservesCopyAndSource() async throws {
        let f = try await fixture()
        try await select(in: f.web)
        let available = await poll { f.web.canDiscussSelection() }; XCTAssertTrue(available)
        let menu = NSMenu(); menu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "")
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: f.window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        f.web.willOpenMenu(menu, with: event); f.web.willOpenMenu(menu, with: event)
        XCTAssertEqual(menu.items.filter { $0.title == "Discuss Selection" }.count, 1)
        XCTAssertTrue(menu.items.contains { $0.title == "Copy" })
        let item = try XCTUnwrap(menu.items.first { $0.title == "Discuss Selection" })
        _ = NSApp.sendAction(try XCTUnwrap(item.action), to: item.target, from: item)
        f.web.discussSelection(nil) // A repeated delivery cannot create a second draft.
        let created = await poll { f.reader.discussions.selection != nil }; XCTAssertTrue(created)
        let key = try XCTUnwrap(f.reader.discussions.selection)
        XCTAssertEqual(f.reader.discussions.drafts[key]?.target?.exact, "Café bold passage.")
        XCTAssertEqual(f.reader.discussions.drafts.count, 1)
        XCTAssertEqual(try Data(contentsOf: f.file), f.bytes)
    }

    func testCollapsedUnsupportedAndStaleSelectionsDoNotCreateDrafts() async throws {
        let f = try await fixture()
        XCTAssertFalse(f.web.canDiscussSelection())
        try await select(in: f.web)
        let available = await poll { f.web.canDiscussSelection() }; XCTAssertTrue(available)
        _ = try await f.web.evaluateJavaScript("getSelection().removeAllRanges();true")
        let cleared = await poll { !f.web.canDiscussSelection() }; XCTAssertTrue(cleared)
        f.web.discussSelection(nil)
        try await select(in: f.web)
        let recaptured = await poll { f.web.canDiscussSelection() }; XCTAssertTrue(recaptured)
        _ = try await f.web.evaluateJavaScript("(()=>{const p=document.querySelector('main p'),m=document.createElement('span');m.className='margined-math';m.textContent='x+y';p.insertBefore(m,p.firstChild);const r=document.createRange();r.selectNodeContents(p);getSelection().removeAllRanges();getSelection().addRange(r);return true})()")
        let unsupported = await poll { !f.web.canDiscussSelection() }; XCTAssertTrue(unsupported)
        f.web.discussSelection(nil)
        _ = try await f.web.evaluateJavaScript("document.querySelector('.margined-math').remove();true")
        try await select(in: f.web)
        let beforeRefresh = await poll { f.web.canDiscussSelection() }; XCTAssertTrue(beforeRefresh)
        // A refresh changes the native source version before the previous DOM can act.
        f.reader.source += "\nChanged version.\n"; f.reader.render()
        f.web.discussSelection(nil)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(f.reader.discussions.drafts.isEmpty)
        XCTAssertEqual(try Data(contentsOf: f.file), f.bytes)
    }

    func testActionRecapturesDOMInsteadOfReusingTheMenuEligibilityCache() async throws {
        let f = try await fixture()
        try await select(in: f.web)
        let available = await poll { f.web.canDiscussSelection() }; XCTAssertTrue(available)
        // Silence change notifications to exercise the action-time guard itself.
        _ = try await f.web.callAsyncJavaScript("window.__marginedDiscussions.abort.abort();getSelection().removeAllRanges();return true;",
            arguments: [:], in: nil, contentWorld: MarkdownWebView.Coordinator.discussionWorld)
        XCTAssertTrue(f.web.canDiscussSelection(), "The test must start the action with an eligible but obsolete cache")
        f.web.discussSelection(nil)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(f.reader.discussions.drafts.isEmpty)
        XCTAssertNil(f.reader.discussionPassagePicker, "The native action must not turn a vanished selection into a passage-picker fallback")
        XCTAssertEqual(try Data(contentsOf: f.file), f.bytes)
    }

    private struct Fixture {
        let reader: ReaderState; let web: DiscussionDocumentWebView; let window: NSWindow; let file: URL; let bytes: Data
    }
    private func fixture() async throws -> Fixture {
        let bytes = Data("# Plan\n\nCafe\u{301} **bold** passage.\n".utf8)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".md")
        try bytes.write(to: file)
        let reader = ReaderState(); reader.fileURL = file; reader.source = String(decoding: bytes, as: UTF8.self); reader.render()
        let host = NSHostingController(rootView: ReaderView(reader: reader)), window = NSWindow()
        window.isReleasedWhenClosed = false; window.contentViewController = host
        window.setContentSize(.init(width: 1000, height: 700)); window.makeKeyAndOrderFront(nil)
        addTeardownBlock { @MainActor in reader.stop(); window.close(); try? FileManager.default.removeItem(at: file) }
        let ready = await poll {
            guard let web = self.find(host.view), web.url != nil, !web.isLoading else { return false }
            return try await web.callAsyncJavaScript("return !!window.__marginedDiscussions;", arguments: [:], in: nil,
                contentWorld: MarkdownWebView.Coordinator.discussionWorld) as? Bool == true
        }
        XCTAssertTrue(ready)
        return .init(reader: reader, web: try XCTUnwrap(find(host.view)), window: window, file: file, bytes: bytes)
    }
    private func find(_ view: NSView) -> DiscussionDocumentWebView? {
        if let web = view as? DiscussionDocumentWebView { return web }
        return view.subviews.lazy.compactMap { self.find($0) }.first
    }
    private func select(in web: WKWebView) async throws {
        _ = try await web.evaluateJavaScript("(()=>{const r=document.createRange();r.selectNodeContents(document.querySelector('main p'));getSelection().removeAllRanges();getSelection().addRange(r);return true})()")
    }
    private func poll(_ predicate: () async throws -> Bool) async -> Bool {
        for _ in 0..<150 { if (try? await predicate()) == true { return true }; try? await Task.sleep(for: .milliseconds(20)) }; return false
    }
}
