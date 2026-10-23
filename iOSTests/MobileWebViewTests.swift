import UIKit
import SwiftUI
import WebKit
import XCTest
@testable import MarginediOS

@MainActor
final class MobileWebViewTests: XCTestCase {
    func testCaptionedTablesUseReadingWidthAndConfineHorizontalScrolling() async throws {
        let source = """
        # Plain

        | Name | Status |
        | --- | --- |
        | Plan | Ready |

        # Captioned

        | Name | Status |
        | --- | --- |
        | Plan | Ready |

        [Table summary]

        # Wide

        | One | Two | Three | Four | Five | Six |
        | --- | --- | --- | --- | --- | --- |
        | LongUnbreakableOne | LongUnbreakableTwo | LongUnbreakableThree | LongUnbreakableFour | LongUnbreakableFive | LongUnbreakableSix |

        [Wide table summary]
        """
        let output = try await MarkdownRenderer.shared.render(source, wide: true)
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 402, height: 650), configuration: MobileWebView.configuration())
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let controller = UIViewController(); controller.view = web
        let window = UIWindow(windowScene: scene); window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        let finished = expectation(description: "Captioned table document finished navigation")
        let navigation = TestWebNavigation(finished: finished)
        web.navigationDelegate = navigation
        web.loadHTMLString(output.html, baseURL: nil)
        await fulfillment(of: [finished], timeout: 10)
        XCTAssertNil(navigation.error)
        let count = try await web.callAsyncJavaScript("return document.querySelectorAll('table').length;",
            arguments: [:], in: nil, contentWorld: .defaultClient) as? Int
        XCTAssertEqual(count, 3)
        try await present(web)
        let measured = try await web.callAsyncJavaScript("""
        const main = document.querySelector('main');
        const style = getComputedStyle(main), box = main.getBoundingClientRect();
        const left = box.left + parseFloat(style.paddingLeft);
        const right = box.right - parseFloat(style.paddingRight);
        const tables = Array.from(document.querySelectorAll('.table-scroll'));
        return { left, right,
            bounds: tables.map(node => { const r = node.getBoundingClientRect(); return [r.left, r.right]; }),
            captions: Array.from(document.querySelectorAll('figcaption')).map(node => node.textContent.trim()),
            wideScroll: tables[2].scrollWidth > tables[2].clientWidth,
            pageOverflow: document.documentElement.scrollWidth - document.documentElement.clientWidth };
        """, arguments: [:], in: nil, contentWorld: .defaultClient) as? [String: Any]
        let values = try XCTUnwrap(measured)
        let bounds = try XCTUnwrap(values["bounds"] as? [[Double]])
        XCTAssertEqual(bounds.count, 3)
        let left = try XCTUnwrap(values["left"] as? Double), right = try XCTUnwrap(values["right"] as? Double)
        for table in bounds {
            XCTAssertEqual(table[0], left, accuracy: 1, "Every table starts at the document's reading margin")
            XCTAssertEqual(table[1], right, accuracy: 1, "Captions must not reduce a table's available width")
        }
        XCTAssertEqual(values["captions"] as? [String], ["Table summary", "Wide table summary"])
        XCTAssertEqual(values["wideScroll"] as? Bool, true, "Wide tables remain locally scrollable")
        XCTAssertLessThanOrEqual(try XCTUnwrap(values["pageOverflow"] as? Double), 1)
    }

    func testTaskBridgeRejectsStaleSubframeAndUnmappedRequests() {
        let task = MarkdownTask(id: 0, utf8Offset: 3, marker: 32, label: "Review")
        let message: [String: Any] = ["id": 0, "checked": true, "token": "current"]
        let request = MobileTaskBridge.request(message, isMainFrame: true, enabled: true, token: "current", tasks: [task])
        XCTAssertEqual(request, MobileTaskBridge.Request(id: 0, checked: true))
        XCTAssertNil(MobileTaskBridge.request(message, isMainFrame: false, enabled: true, token: "current", tasks: [task]))
        XCTAssertNil(MobileTaskBridge.request(message, isMainFrame: true, enabled: false, token: "current", tasks: [task]))
        XCTAssertNil(MobileTaskBridge.request(message, isMainFrame: true, enabled: true, token: "new", tasks: [task]))
        XCTAssertNil(MobileTaskBridge.request(message, isMainFrame: true, enabled: true, token: "current", tasks: []))
        XCTAssertNil(MobileTaskBridge.request(["id": true, "checked": true, "token": "current"], isMainFrame: true, enabled: true, token: "current", tasks: [task]))
        XCTAssertNil(MobileTaskBridge.request(["id": 0, "checked": 1, "token": "current"], isMainFrame: true, enabled: true, token: "current", tasks: [task]))
    }

    func testDynamicTypeChangesComputedTextWithoutReloadingOrResizingAuthoredImage() async throws {
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 650), configuration: MobileWebView.configuration())
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let controller = UIViewController()
        controller.view = web
        web.scrollView.contentInsetAdjustmentBehavior = .never
        let window = UIWindow(windowScene: scene)
        window.frame = web.frame
        window.rootViewController = controller
        window.isHidden = false
        window.layoutIfNeeded()
        defer { window.isHidden = true; window.rootViewController = nil }
        XCTAssertNotNil(web.window)
        let paragraphs = (0..<100).map { "<p id='line-\($0)'>A paragraph to keep a stable reading anchor.</p>" }.joined()
        let html = "<!doctype html><html><head><meta name='viewport' content='width=device-width, initial-scale=1'><style>body{margin:0;font-size:16px}p{margin:1em 0}img{max-width:100%}</style></head><body><main id='document'>\(paragraphs)<img id='picture' width='120' height='60' alt='Authored size'></main></body></html>"
        web.loadHTMLString(html, baseURL: nil)
        try await waitForDocument(web)
        try await present(web)
        _ = try await web.callAsyncJavaScript("window.identity = 'same-document'; document.getElementById('line-35').scrollIntoView({block:'start',behavior:'instant'}); return true;", arguments: [:], in: nil, contentWorld: MobileWebView.Coordinator.contentWorld)
        try await MobileWebTypography.apply(to: web, category: .large, zoom: 1)
        let normal = try await presentedMetrics(web)
        // Match the renderer's device-width viewport. A desktop-width fixture
        // activates iOS text autosizing, which changes the scroll geometry while
        // WebKit applies its first native viewport commit.
        XCTAssertEqual(try XCTUnwrap(normal["width"] as? Double), 390, accuracy: 0.5)
        XCTAssertEqual(try XCTUnwrap(normal["scale"] as? Double), 1, accuracy: 0.001)
        XCTAssertEqual(normal["anchorID"] as? String, "line-35")
        XCTAssertEqual(try XCTUnwrap(normal["anchorTop"] as? Double), 0, accuracy: 1)
        try await MobileWebTypography.apply(to: web, category: .accessibilityExtraExtraExtraLarge, zoom: 1)
        let largest = try await presentedMetrics(web)
        let committed = try await presentedMetrics(web)
        XCTAssertEqual(committed["anchorID"] as? String, "line-35")
        XCTAssertEqual(try XCTUnwrap(committed["anchorTop"] as? Double), try XCTUnwrap(normal["anchorTop"] as? Double), accuracy: 1)
        XCTAssertGreaterThan(try XCTUnwrap(largest["font"] as? Double), try XCTUnwrap(normal["font"] as? Double))
        XCTAssertEqual(largest["identity"] as? String, "same-document")
        XCTAssertEqual(try XCTUnwrap(largest["imageWidth"] as? Double), 120, accuracy: 0.5)
        XCTAssertEqual(try XCTUnwrap(largest["imageHeight"] as? Double), 60, accuracy: 0.5)
        XCTAssertEqual(try XCTUnwrap(largest["anchorTop"] as? Double), try XCTUnwrap(normal["anchorTop"] as? Double), accuracy: 1)
        XCTAssertEqual(web.pageZoom, 1)
        let changedHTML = html.replacingOccurrences(of: "</main>", with: "<p>A newly saved change.</p></main>")
        let reconciled = try await web.callAsyncJavaScript(MobileWebTypography.reconcileScript,
            arguments: ["html": changedHTML, "restoreFocus": false, "fontSize": try XCTUnwrap(largest["font"] as? Double)],
            in: nil, contentWorld: MobileWebView.Coordinator.contentWorld) as? Bool
        XCTAssertEqual(reconciled, true)
        let afterRefresh = try await presentedMetrics(web)
        XCTAssertEqual(afterRefresh["identity"] as? String, "same-document")
        XCTAssertEqual(try XCTUnwrap(afterRefresh["anchorTop"] as? Double), try XCTUnwrap(largest["anchorTop"] as? Double), accuracy: 1)
        XCTAssertEqual(try XCTUnwrap(afterRefresh["font"] as? Double), try XCTUnwrap(largest["font"] as? Double), accuracy: 0.5)
        try await MobileWebTypography.apply(to: web, category: .large, zoom: 1.5)
        let zoomed = try await presentedMetrics(web)
        XCTAssertEqual(try XCTUnwrap(zoomed["font"] as? Double), try XCTUnwrap(normal["font"] as? Double) * 1.5, accuracy: 0.5)
    }

    func testResourceNamespaceLeavesRemoteDataAndCodeUntouched() {
        let html = #"<img alt="local" src="margined-resource://local/pic%2Epng"><img src="https://example.com/pic.png"><img src="data:image/png;base64,abc"><code>src="margined-resource://local/example"</code>"#
        let first = MobileWebResources.html(html, token: "first")
        let second = MobileWebResources.html(html, token: "second")
        XCTAssertNotEqual(first, second)
        XCTAssertTrue(first.contains(#"src="margined-resource://local/pic%2Epng?generation=first""#))
        XCTAssertTrue(first.contains(#"src="https://example.com/pic.png""#))
        XCTAssertTrue(first.contains(#"src="data:image/png;base64,abc""#))
        XCTAssertTrue(first.contains(#"<code>src="margined-resource://local/example"</code>"#))
    }

    func testAnOldImageRequestCannotResolveAgainstANewDocumentsFolder() {
        let old = URL(string: "margined-resource://local/image%2Epng?generation=old")!
        let current = URL(string: "margined-resource://local/image%2Epng?generation=current")!
        XCTAssertFalse(MobileWebResources.authorizes(old, token: "current"))
        XCTAssertTrue(MobileWebResources.authorizes(current, token: "current"))
        XCTAssertFalse(MobileWebResources.authorizes(URL(string: "margined-resource://local/image.png")!, token: "current"))
        XCTAssertFalse(MobileWebResources.authorizes(URL(string: "https://example.com/?generation=current")!, token: "current"))
    }

    func testConfigurationDisablesAuthorJavaScriptAndHasNoPersistentWebsiteStore() {
        let configuration = MobileWebView.configuration()
        XCTAssertFalse(configuration.defaultWebpagePreferences.allowsContentJavaScript)
        XCTAssertFalse(configuration.websiteDataStore.isPersistent)
    }

    func testOpeningAnotherSnapshotStartsAtTopAndRejectsOldPageTypography() async throws {
        let reader = MobileReaderState()
        var parts = URLComponents(string: "margined://preview")!
        parts.queryItems = [.init(name: "text", value: "# Snapshot\n\n" + (0..<100).map { "Paragraph \($0)." }.joined(separator: "\n\n"))]
        await reader.openPreview(url: parts.url!); await reader.waitForRendering()
        let coordinator = MobileWebView.Coordinator(reader: reader)
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 650), configuration: MobileWebView.configuration())
        coordinator.webView = web
        web.navigationDelegate = coordinator
        coordinator.update(category: .large)
        try await waitForToken(web)
        let oldTokenValue = try await web.callAsyncJavaScript("window.identity='old'; scrollTo({top:800,behavior:'instant'}); return document.documentElement.getAttribute('data-margined-mobile-token');", arguments: [:], in: nil, contentWorld: MobileWebView.Coordinator.contentWorld)
        let oldToken = try XCTUnwrap(oldTokenValue as? String)
        await reader.openPreview(url: parts.url!); await reader.waitForRendering()
        coordinator.update(category: .large)
        try await waitForToken(web, excluding: oldToken)
        try await MobileWebTypography.apply(to: web, category: .accessibilityExtraExtraExtraLarge, zoom: 3, expectedToken: oldToken)
        let result = try await web.callAsyncJavaScript("return {y:scrollY, identity:window.identity ?? null, font:parseFloat(getComputedStyle(document.body).fontSize)};", arguments: [:], in: nil, contentWorld: MobileWebView.Coordinator.contentWorld) as? [String: Any]
        XCTAssertEqual(try XCTUnwrap(result?["y"] as? Double), 0, accuracy: 1)
        XCTAssertEqual(try XCTUnwrap(result?["font"] as? Double), Double(MobileWebTypography.fontSize(category: .large, zoom: 1)), accuracy: 0.5)
        XCTAssertTrue(result?["identity"] is NSNull)
        coordinator.invalidate()
        await reader.close()
    }

    func testLocalImagesAreNamespacedAcrossFileSwitchAndFolderReload() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let reader = MobileReaderState()
        let coordinator = MobileWebView.Coordinator(reader: reader)
        let configuration = MobileWebView.configuration()
        configuration.setURLSchemeHandler(coordinator.images, forURLScheme: "margined-resource")
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 650), configuration: configuration)
        coordinator.webView = web; web.navigationDelegate = coordinator
        var previousToken: String?, previousImage: String?
        for width in [10, 20] {
            let child = folder.appendingPathComponent(String(width))
            try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
            let format = UIGraphicsImageRendererFormat(); format.scale = 1
            let image = UIGraphicsImageRenderer(size: CGSize(width: width, height: 10), format: format).image { context in
                UIColor.blue.setFill(); context.fill(CGRect(x: 0, y: 0, width: width, height: 10))
            }
            try XCTUnwrap(image.pngData()).write(to: child.appendingPathComponent("image.png"))
            let file = child.appendingPathComponent("document.md")
            try Data("# Images\n\n![Local](image.png)".utf8).write(to: file)
            await reader.open(url: file); await reader.waitForRendering()
            coordinator.update(category: .large)
            try await waitForToken(web, excluding: previousToken)
            var actualWidth = 0.0
            for _ in 0..<100 {
                actualWidth = (try? await web.callAsyncJavaScript("return document.querySelector('img')?.naturalWidth ?? 0;", arguments: [:], in: nil, contentWorld: MobileWebView.Coordinator.contentWorld) as? Double) ?? 0
                if actualWidth > 0 { break }
                try await Task.sleep(for: .milliseconds(25))
            }
            XCTAssertEqual(actualWidth, Double(width), accuracy: 0.5)
            let src = try await web.callAsyncJavaScript("return document.querySelector('img').src;", arguments: [:], in: nil, contentWorld: MobileWebView.Coordinator.contentWorld) as? String
            XCTAssertNotEqual(src, previousImage)
            previousImage = src
            previousToken = try await web.callAsyncJavaScript("return document.documentElement.getAttribute('data-margined-mobile-token');", arguments: [:], in: nil, contentWorld: MobileWebView.Coordinator.contentWorld) as? String
        }
        reader.imageReloadGeneration += 1
        coordinator.update(category: .large)
        try await waitForToken(web, excluding: previousToken)
        let reloadedImage = try await web.callAsyncJavaScript("return document.querySelector('img').src;", arguments: [:], in: nil, contentWorld: MobileWebView.Coordinator.contentWorld) as? String
        XCTAssertNotEqual(reloadedImage, previousImage)
        coordinator.invalidate(); await reader.close()
    }

    func testHostedReaderRespondsToSettledNavigationFindSpeechAndProgress() async throws {
        let defaults = UserDefaults(suiteName: "HostedWebView-\(UUID().uuidString)")!
        let driver = HostedWebSpeechDriver()
        let session = SpeechSession(driver: driver, voices: {
            [SpeechVoice(id: "test", name: "Test", language: "en-US", quality: 1)]
        }, coordinator: SpeechCoordinator())
        let playback = MobilePlaybackOwner(session: session, audioSession: HostedWebAudioSession(),
            nowPlaying: HostedWebNowPlaying(), preferences: SpeechPreferences(defaults: defaults),
            progressStore: SpeechProgressStore(defaults: defaults))
        let reader = MobileReaderState(playback: playback, defaults: defaults)
        var parts = URLComponents(string: "margined://preview")!
        let text = "# Beginning\n\n" + (0..<50).map { "Paragraph \($0) to make a long native reader." }.joined(separator: "\n\n") + "\n\n## Target\n\nFindneedle at the end."
        parts.queryItems = [.init(name: "text", value: text)]
        await reader.openPreview(url: parts.url!); await reader.waitForRendering()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let host = UIHostingController(rootView: HostedWebReader(reader: reader))
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 650)
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil; playback.stop() }
        host.loadViewIfNeeded(); host.view.layoutIfNeeded()
        var candidate: WKWebView?
        for _ in 0..<200 {
            candidate = findWebView(host.view)
            if candidate != nil { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        let web = try XCTUnwrap(candidate)
        try await waitForToken(web)
        try await Task.sleep(for: .milliseconds(300))

        reader.startSpeech(mode: "visible")
        let started = try await eventually { !driver.tokens.isEmpty }
        XCTAssertTrue(started, "A settled representable must observe a new Read Aloud request; pending=\(reader.speechStartRequest?.uuidString ?? "none"), error=\(reader.errorMessage ?? "none")")
        if started {
            let initial = try XCTUnwrap(session.currentSegment?.elementID)
            let highlighted = try await eventually {
                (try await web.callAsyncJavaScript("return document.querySelector('.margined-speaking')?.dataset.marginedSpeech;", arguments: [:], in: nil, contentWorld: MobileWebView.Coordinator.contentWorld) as? String) == initial
            }
            XCTAssertTrue(highlighted)
            driver.finish()
            let next = try XCTUnwrap(session.currentSegment?.elementID)
            XCTAssertNotEqual(next, initial)
            let advanced = try await eventually {
                (try await web.callAsyncJavaScript("return document.querySelector('.margined-speaking')?.dataset.marginedSpeech;", arguments: [:], in: nil, contentWorld: MobileWebView.Coordinator.contentWorld) as? String) == next
            }
            XCTAssertTrue(advanced, "Speech progress must update the DOM without another user intent")
        }
        playback.stop()
        let target = try XCTUnwrap(reader.rendered?.headings.last?.id)
        reader.navigate(to: target)
        let navigated = try await eventually {
            (try await web.callAsyncJavaScript("return document.activeElement?.id;", arguments: [:], in: nil, contentWorld: MobileWebView.Coordinator.contentWorld) as? String) == target
        }
        XCTAssertTrue(navigated, "A settled representable must observe a new navigation request")

        reader.searchText = "Findneedle"; reader.find()
        let found = try await eventually { reader.searchMatch == true }
        XCTAssertTrue(found, "A settled representable must observe a new Find request")

        await reader.close()
    }

    private func findWebView(_ view: UIView) -> WKWebView? {
        if let web = view as? WKWebView { return web }
        return view.subviews.lazy.compactMap { self.findWebView($0) }.first
    }

    private func eventually(_ condition: () async throws -> Bool) async throws -> Bool {
        for _ in 0..<100 {
            if try await condition() { return true }
            try await Task.sleep(for: .milliseconds(25))
        }
        return false
    }

    private func waitForToken(_ web: WKWebView, excluding previous: String? = nil) async throws {
        for _ in 0..<200 {
            if !web.isLoading,
               let token = try? await web.callAsyncJavaScript("return document.documentElement.getAttribute('data-margined-mobile-token');", arguments: [:], in: nil, contentWorld: MobileWebView.Coordinator.contentWorld) as? String,
               token != previous { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTFail("WebKit did not show the current document")
        throw URLError(.timedOut)
    }

    /// A detached WKWebView can report new font geometry before its remote
    /// scroll commit. Measure the actual window-hosted presentation after
    /// WebKit applies pending screen updates, not an unpresented IPC interval.
    private func present(_ web: WKWebView) async throws {
        let configuration = WKSnapshotConfiguration()
        configuration.afterScreenUpdates = true
        let snapshot = try await web.takeSnapshot(configuration: configuration)
        XCTAssertGreaterThan(snapshot.size.width, 0)
        XCTAssertGreaterThan(snapshot.size.height, 0)
    }

    private func presentedMetrics(_ web: WKWebView) async throws -> [String: Any] {
        try await present(web)
        let result = try await metrics(web)
        XCTAssertEqual(try XCTUnwrap(result["y"] as? Double), Double(web.scrollView.contentOffset.y), accuracy: 1,
                       "DOM and native viewport must describe the same presented scroll position")
        return result
    }

    private func metrics(_ web: WKWebView) async throws -> [String: Any] {
        let result = try await web.callAsyncJavaScript("const blocks=Array.from(document.querySelectorAll('#document p')); const anchor=blocks.filter(n=>{const r=n.getBoundingClientRect();return r.height>0&&r.bottom>0&&r.top<innerHeight}).sort((a,b)=>Math.abs(a.getBoundingClientRect().top)-Math.abs(b.getBoundingClientRect().top))[0]; return {width:innerWidth,height:innerHeight,scale:visualViewport?.scale,y:scrollY,scrollHeight:document.documentElement.scrollHeight,anchorID:anchor?.id,nearestTop:anchor?.getBoundingClientRect().top,font:parseFloat(getComputedStyle(document.body).fontSize), identity:window.identity, imageWidth:document.getElementById('picture').getBoundingClientRect().width, imageHeight:document.getElementById('picture').getBoundingClientRect().height, anchorTop:document.getElementById('line-35').getBoundingClientRect().top};", arguments: [:], in: nil, contentWorld: MobileWebView.Coordinator.contentWorld) as? [String: Any]
        return try XCTUnwrap(result)
    }

    private func waitForDocument(_ web: WKWebView) async throws {
        for _ in 0..<200 {
            if !web.isLoading, (try? await web.callAsyncJavaScript("return !!document.getElementById('line-35');", arguments: [:], in: nil, contentWorld: MobileWebView.Coordinator.contentWorld) as? Bool) == true { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTFail("WebKit did not finish the test document")
        throw URLError(.timedOut)
    }
}

private struct HostedWebReader: View {
    let reader: MobileReaderState
    var body: some View {
        NavigationStack {
            MobileReaderView(reader: reader, openFolder: {}, closeFile: {})
        }
    }
}

@MainActor private final class HostedWebSpeechDriver: SpeechDriver {
    var eventHandler: ((SpeechDriverEvent) -> Void)?
    var useAssistiveTechnologySettings = false
    var tokens: [UUID] = []
    func speak(_ text: String, voice: SpeechVoice?, rate: Double, token: UUID) { tokens.append(token) }
    func pause() -> Bool { true }
    func resume() -> Bool { true }
    func stop() {}
    func finish() { if let token = tokens.last { eventHandler?(.finished(token)) } }
}

@MainActor private final class HostedWebAudioSession: MobileAudioSessionManaging {
    func activate() throws {}
    func deactivate() {}
}

@MainActor private final class HostedWebNowPlaying: MobileNowPlayingPublishing {
    func beginOwnership(generation: UUID, handler: @escaping @MainActor (UUID, MobilePlaybackCommand) -> Bool) {}
    func update(_ metadata: MobileNowPlayingMetadata) {}
    func endOwnership() {}
}

/// Navigation readiness is separate from the geometry assertions. A fresh
/// WebContent process can take longer than the polling helper's 2.5-second cap.
@MainActor private final class TestWebNavigation: NSObject, WKNavigationDelegate {
    let finished: XCTestExpectation
    private(set) var error: Error?
    private var completed = false

    init(finished: XCTestExpectation) { self.finished = finished }

    private func complete(_ error: Error? = nil) {
        guard !completed else { return }
        completed = true
        self.error = error
        finished.fulfill()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { complete() }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { complete(error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { complete(error) }
}
