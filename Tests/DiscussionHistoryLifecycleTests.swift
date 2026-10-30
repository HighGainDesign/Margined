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

    func testInPlaceRefreshRetiresAnInterruptedRestoreAndCapturesSubsequentScrolling() async throws {
        let state = DiscussionHistoryPresentationState(), gate = HistoryCaptureGate()
        let seedOwner = UUID()
        state.activate(seedOwner)
        state.capture(owner: seedOwner) {
            await gate.wait()
            return ["x": 0, "y": 0, "top": 0, "candidates": []]
        }
        let scope = DiscussionHistoryScope(fileURL: nil, isCurrent: { true }, imageFailed: { _ in },
            openFile: { _ in }, presentationState: state)
        let first = historyHTML()
        let latest = first.replacingOccurrences(of: "</main>", with: "<p id='new-message'>Appended saved message.</p></main>")
        let coordinator = DiscussionHistoryCoordinator(scope: scope), web = coordinator.makeWebView()
        defer { gate.release(); coordinator.invalidate() }
        let navigation = HistoryNavigationProbe(coordinator: coordinator)
        web.navigationDelegate = navigation
        try mount(web)
        coordinator.update(html: first, fontSize: 16, imageGeneration: 0)
        let initial = await poll { navigation.completions == 1 }
        XCTAssertTrue(initial); guard initial else { gate.release(); return }
        _ = try await web.evaluateJavaScript("window.originalHistoryDocument=document;true")
        // The native didFinish callback has marked this page ready. Its restore
        // waits on the held outgoing capture while this same-head update runs.
        coordinator.update(html: latest, fontSize: 16, imageGeneration: 0)
        let reconciled = await poll {
            try await web.evaluateJavaScript("window.originalHistoryDocument===document && !!document.getElementById('new-message')") as? Bool == true
        }
        XCTAssertTrue(reconciled)
        XCTAssertEqual(navigation.completions, 1, "Exercise in-place reconciliation, not replacement navigation")
        gate.release()
        _ = await state.restorePosition()
        try await reveal("history-p23", in: web)
        coordinator.invalidate()

        let successor = DiscussionHistoryCoordinator(scope: scope), restored = successor.makeWebView()
        defer { successor.invalidate() }
        try mount(restored)
        successor.update(html: latest, fontSize: 16, imageGeneration: 0)
        let retained = await poll {
            try await restored.evaluateJavaScript("document.body.style.fontSize==='16px' && Math.abs(document.getElementById('history-p23').getBoundingClientRect().top-24)<2") as? Bool == true
        }
        XCTAssertTrue(retained, "A superseded restore must not prevent capturing the later paragraph being read")
    }

    func testSameMountedHistoryRetainsItsPassageAcrossResizeAndInPlaceTokenRenewal() async throws {
        let scope = DiscussionHistoryScope(fileURL: nil, isCurrent: { true }, imageFailed: { _ in }, openFile: { _ in })
        let coordinator = DiscussionHistoryCoordinator(scope: scope), web = coordinator.makeWebView()
        defer { coordinator.invalidate() }
        try mount(web)
        let first = historyHTML()
        coordinator.update(html: first, fontSize: 16, imageGeneration: 0)
        let ready = await poll {
            try await web.evaluateJavaScript("document.body.style.fontSize==='16px'") as? Bool == true
        }
        XCTAssertTrue(ready); guard ready else { return }
        _ = try await web.evaluateJavaScript("window.resizingHistoryDocument=document;true")
        try await reveal("history-p22", in: web)
        resize(web, to: CGSize(width: 500, height: 400))
        let firstResize = await poll {
            try await web.evaluateJavaScript("innerWidth===500 && window.resizingHistoryDocument===document && Math.abs(document.getElementById('history-p22').getBoundingClientRect().top-24)<2") as? Bool == true
        }
        XCTAssertTrue(firstResize, "The history token must authorize its own same-mounted resize observer after scrolling")

        let latest = first.replacingOccurrences(of: "</main>", with: "<p id='new-message'>Appended saved message.</p></main>")
        coordinator.update(html: latest, fontSize: 16, imageGeneration: 0)
        let reconciled = await poll {
            try await web.evaluateJavaScript("window.resizingHistoryDocument===document && !!document.getElementById('new-message')") as? Bool == true
        }
        XCTAssertTrue(reconciled)
        try await reveal("history-p32", in: web)
        resize(web, to: CGSize(width: 390, height: 400))
        let renewed = await poll {
            try await web.evaluateJavaScript("innerWidth===390 && window.resizingHistoryDocument===document && Math.abs(document.getElementById('history-p32').getBoundingClientRect().top-24)<2") as? Bool == true
        }
        XCTAssertTrue(renewed, "In-place history-token updates must renew the resize lease before later scrolling/reflow")
    }

    private func historyHTML() -> String {
        let paragraphs = (0..<50).map { index in
            "<p id='history-p\(index)'>History paragraph \(index). " + String(repeating: "A retained conversation keeps the actual passage readable while its viewport reflows. ", count: 5) + "</p>"
        }.joined()
        return "<html><head><meta name=\"viewport\" content=\"width=device-width, initial-scale=1\"><style>html{overflow-anchor:none}body{margin:0;font-size:16px;line-height:1.5}main{padding:16px}p{margin:0 0 20px}</style></head><body><main id='document'>" + paragraphs + "</main></body></html>"
    }
    private func reveal(_ id: String, in web: WKWebView) async throws {
        _ = try await web.callAsyncJavaScript("""
        await document.fonts.ready;
        const paragraph=document.getElementById(id);
        scrollTo({top:scrollY+paragraph.getBoundingClientRect().top-24,behavior:'instant'});
        await new Promise(resolve=>requestAnimationFrame(()=>requestAnimationFrame(resolve)));
        return true;
        """, arguments: ["id": id], in: nil, contentWorld: .world(name: "MarginedDiscussionHistory"))
    }
    private func resize(_ web: WKWebView, to size: CGSize) {
        #if os(iOS)
        web.window?.frame.size = size
        web.window?.rootViewController?.view.frame = CGRect(origin: .zero, size: size)
        web.window?.rootViewController?.view.layoutIfNeeded()
        #else
        web.window?.setContentSize(size)
        web.frame.size = size; web.layoutSubtreeIfNeeded()
        #endif
    }
    private func poll(_ predicate: () async throws -> Bool) async -> Bool {
        for _ in 0..<150 {
            if (try? await predicate()) == true { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return false
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

@MainActor
private final class HistoryCaptureGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    func wait() async {
        if released { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func release() { released = true; continuation?.resume(); continuation = nil }
}

@MainActor
private final class HistoryNavigationProbe: NSObject, WKNavigationDelegate {
    let coordinator: DiscussionHistoryCoordinator
    private(set) var completions = 0
    init(coordinator: DiscussionHistoryCoordinator) { self.coordinator = coordinator }
    func webView(_ view: WKWebView, didFinish navigation: WKNavigation!) {
        coordinator.webView(view, didFinish: navigation)
        completions += 1
    }
    func webView(_ view: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        await coordinator.webView(view, decidePolicyFor: action)
    }
}
