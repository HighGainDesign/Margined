import UIKit
import SwiftUI
import WebKit
import XCTest
@testable import MarginediOS

@MainActor
final class MobileDiscussionSelectionMenuTests: XCTestCase {
    func testNativeMenuCreatesOneUnicodeDraftAndPreservesSource() async throws {
        let f = try await fixture()
        try await select(in: f.web)
        let available = await poll { f.web.canDiscussSelection() }; XCTAssertTrue(available)
        XCTAssertTrue(f.web.canPerformAction(#selector(MobileDocumentWebView.discussSelection(_:)), withSender: nil))
        f.web.discussSelection(nil)
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
        await f.reader.close()
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
            arguments: [:], in: nil, contentWorld: MobileWebView.Coordinator.discussionWorld)
        XCTAssertTrue(f.web.canDiscussSelection(), "The test must start the action with an eligible but obsolete cache")
        f.web.discussSelection(nil)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(f.reader.discussions.drafts.isEmpty)
        XCTAssertNil(f.reader.discussionPassagePicker, "The native action must not turn a vanished selection into a passage-picker fallback")
        XCTAssertEqual(try Data(contentsOf: f.file), f.bytes)
    }

    private struct Fixture {
        let reader: MobileReaderState; let web: MobileDocumentWebView; let window: UIWindow; let file: URL; let bytes: Data
    }
    private func fixture() async throws -> Fixture {
        let bytes = Data("# Plan\n\nCafe\u{301} **bold** passage.\n".utf8)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".md")
        try bytes.write(to: file)
        let reader = MobileReaderState(); await reader.open(url: file); await reader.waitForRendering()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let host = UIHostingController(rootView: MobileDocumentWorkspace(reader: reader, openFolder: {}, closeFile: {}))
        let window = UIWindow(windowScene: scene); window.frame = CGRect(x: 0, y: 0, width: 390, height: 780)
        window.rootViewController = host; window.makeKeyAndVisible(); host.loadViewIfNeeded(); host.view.layoutIfNeeded()
        addTeardownBlock { @MainActor in
            reader.discussions.discardDrafts(); await reader.close(); window.isHidden = true
            window.rootViewController = nil; try? FileManager.default.removeItem(at: file)
        }
        let committed = await WebKitTestReadiness.navigation({ self.find(host.view) },
            expectedURL: file.deletingLastPathComponent())
        _ = try XCTUnwrap(committed, "Finish initial native navigation before checking the discussion bridge")
        let ready = await poll {
            guard let web = self.find(host.view), web.url != nil, !web.isLoading else { return false }
            return try await web.callAsyncJavaScript("return !!window.__marginedDiscussions;", arguments: [:], in: nil,
                contentWorld: MobileWebView.Coordinator.discussionWorld) as? Bool == true
        }
        XCTAssertTrue(ready)
        return .init(reader: reader, web: try XCTUnwrap(find(host.view)), window: window, file: file, bytes: bytes)
    }
    private func find(_ view: UIView) -> MobileDocumentWebView? {
        if let web = view as? MobileDocumentWebView { return web }
        return view.subviews.lazy.compactMap { self.find($0) }.first
    }
    private func select(in web: WKWebView) async throws {
        _ = try await web.evaluateJavaScript("(()=>{const r=document.createRange();r.selectNodeContents(document.querySelector('main p'));getSelection().removeAllRanges();getSelection().addRange(r);return true})()")
    }
    private func poll(_ predicate: () async throws -> Bool) async -> Bool {
        for _ in 0..<150 { if (try? await predicate()) == true { return true }; try? await Task.sleep(for: .milliseconds(20)) }; return false
    }
}
