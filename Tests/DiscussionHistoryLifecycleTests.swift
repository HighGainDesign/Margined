import XCTest
import WebKit
#if os(iOS)
import UIKit
@testable import MarginediOS
#else
import AppKit
@testable import Margined
#endif

@MainActor
final class DiscussionHistoryLifecycleTests: XCTestCase {
    func testTemporarilyHiddenHistoryCanResumeWithTheLatestSavedMessages() async throws {
        var visible = true
        let scope = DiscussionHistoryScope(fileURL: nil, isCurrent: { visible },
            imageFailed: { _ in XCTFail("No image requests in this fixture") }, openFile: { _ in XCTFail("No navigation in this fixture") })
        let coordinator = DiscussionHistoryCoordinator(scope: scope)
        let web = coordinator.makeWebView()
        defer { coordinator.invalidate() }
        try mount(web)
        let first = "<html><body><main id='document'><p>First saved message.</p></main></body></html>"
        coordinator.update(html: first, fontSize: 16, imageGeneration: 0)
        let loaded = await contains("First saved message.", in: web)
        XCTAssertTrue(loaded, "Establish a committed history before changing its presentation")
        guard loaded else { return }

        visible = false
        coordinator.update(html: first, fontSize: 16, imageGeneration: 0)
        visible = true
        let latest = first.replacingOccurrences(of: "</main>", with: "<p>Second saved message.</p></main>")
        coordinator.update(html: latest, fontSize: 20, imageGeneration: 0)
        let resumed = await contains("Second saved message.", in: web)
        XCTAssertTrue(resumed, "A temporary compact/docked transition must not permanently invalidate a retained history")
        let firstStillPresent = await contains("First saved message.", in: web)
        XCTAssertTrue(firstStillPresent)
        XCTAssertNotNil(web.window)
    }

    func testExplicitlyRetiredHistoryNeverResumes() async throws {
        let scope = DiscussionHistoryScope(fileURL: nil, isCurrent: { true }, imageFailed: { _ in }, openFile: { _ in })
        let coordinator = DiscussionHistoryCoordinator(scope: scope)
        let web = coordinator.makeWebView()
        try mount(web)
        coordinator.update(html: "<html><body><main id='document'>Original message.</main></body></html>", fontSize: 16, imageGeneration: 0)
        let loaded = await contains("Original message.", in: web)
        XCTAssertTrue(loaded)
        coordinator.invalidate()
        coordinator.update(html: "<html><body>Must not load.</body></html>", fontSize: 16, imageGeneration: 0)
        for _ in 0..<5 { await Task.yield() }
        let text = try await web.evaluateJavaScript("document.body.textContent") as? String
        XCTAssertFalse(text?.contains("Must not load.") == true)
    }

    private func mount(_ web: WKWebView) throws {
        web.frame = CGRect(x: 0, y: 0, width: 360, height: 400)
        #if os(iOS)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let controller = UIViewController(); controller.view = web
        let window = UIWindow(windowScene: scene); window.frame = web.frame
        window.rootViewController = controller; window.makeKeyAndVisible()
        addTeardownBlock { @MainActor in window.isHidden = true; window.rootViewController = nil }
        #else
        let window = NSWindow(contentRect: web.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = web; window.makeKeyAndOrderFront(nil)
        addTeardownBlock { @MainActor in window.contentView = nil; window.close() }
        #endif
    }

    private func contains(_ text: String, in web: WKWebView) async -> Bool {
        for _ in 0..<150 {
            if !web.isLoading, (try? await web.evaluateJavaScript("document.querySelector('main')?.textContent")) as? String != nil,
               let body = try? await web.evaluateJavaScript("document.body.textContent") as? String, body.contains(text) { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return false
    }
}
