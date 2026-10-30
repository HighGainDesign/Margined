import AppKit
import SwiftUI
import WebKit
import XCTest
@testable import Margined

@MainActor
final class SpeechPlayerIntegrationTests: XCTestCase {
    func testReadAloudToolbarStartsAndPausesWithoutASecondPlayClick() async throws {
        let fixture = try await makeFixture(); defer { fixture.close() }
        fixture.window.setContentSize(NSSize(width: 1200, height: 780))
        try await activateNativeTestApplication()
        fixture.window.makeKeyAndOrderFront(nil)
        fixture.host.view.layoutSubtreeIfNeeded()
        var labels: [String] = []
        func readButton(_ element: Any) -> AnyObject? {
            var visited: Set<ObjectIdentifier> = []
            func walk(_ element: Any) -> AnyObject? {
                guard let object = element as? NSObject, visited.insert(ObjectIdentifier(object)).inserted else { return nil }
                let accessible: AnyObject = object
                if let label = accessible.accessibilityLabel?(), labels.count < 80 { labels.append(label) }
                if accessible.accessibilityRole?() == .button,
                   let label = accessible.accessibilityLabel?(),
                   ["Read Aloud controls", "Read Aloud", "Pause Reading", "Resume Reading"].contains(label) { return accessible }
                let children = accessible.accessibilityChildren?() ?? []
                for child in children { if let result = walk(child) { return result } }
                for child in (object as? NSView)?.subviews ?? [] {
                    if let result = walk(child) { return result }
                }
                return nil
            }
            return walk(element)
        }
        for _ in 0..<100 {
            if readButton(fixture.host.view) != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let button = try XCTUnwrap(readButton(fixture.host.view), "Find the actual native toolbar action: \(labels)")
        XCTAssertTrue(button.accessibilityPerformPress?() == true)
        for _ in 0..<100 where fixture.driver.requests.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(fixture.driver.requests.count, 1, "Read Aloud must start playback on its first activation")
        XCTAssertEqual(fixture.reader.speech.session.status, .playing)
        XCTAssertTrue(fixture.reader.speech.showPlayer)
        XCTAssertTrue(try XCTUnwrap(readButton(fixture.host.view)).accessibilityPerformPress?() == true)
        for _ in 0..<100 where fixture.reader.speech.session.status != .paused { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(fixture.reader.speech.session.status, .paused)
        XCTAssertEqual(fixture.driver.requests.count, 1)
        XCTAssertEqual(try MarkdownSource.read(fixture.file), fixture.source)
    }

    func testPlayerReservesSpaceWithoutCoveringDocumentAndClosesCleanly() async throws {
        let fixture = try await makeFixture(); defer { fixture.close() }
        let before = fixture.web.convert(fixture.web.bounds, to: fixture.host.view)
        fixture.reader.speech.showPlayer = true
        var after = before
        for _ in 0..<100 {
            fixture.host.view.layoutSubtreeIfNeeded()
            after = fixture.web.convert(fixture.web.bounds, to: fixture.host.view)
            if after.height < before.height - 40 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertLessThan(after.height, before.height - 40)
        XCTAssertGreaterThan(after.height, 150)
        XCTAssertEqual(after.minX, before.minX, accuracy: 1)
        fixture.reader.speech.close()
        for _ in 0..<100 where fixture.web.bounds.height < before.height - 1 { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(fixture.web.bounds.height, before.height, accuracy: 1)
    }

    func testSelectionStartsAtChosenTextThroughTheRealIsolatedBridge() async throws {
        let fixture = try await makeFixture(); defer { fixture.close() }
        _ = try await fixture.web.evaluateJavaScript("""
        const node = document.querySelector('p').lastChild;
        const range = document.createRange();
        range.setStart(node, node.textContent.indexOf('ending'));
        range.setEnd(node, node.length);
        getSelection().removeAllRanges(); getSelection().addRange(range);
        """)
        fixture.reader.speech.requestStart(.selection)
        for _ in 0..<150 where !fixture.reader.speech.session.isActive { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(fixture.driver.requests.last?.text, "ending.", "request=\(String(describing: fixture.reader.speech.startRequest)); message=\(fixture.reader.speech.message ?? "none")")
        XCTAssertEqual(fixture.reader.speech.session.status, .playing)
        _ = try await fixture.web.evaluateJavaScript("""
        const first = document.querySelector('p').firstChild;
        const next = document.createRange(); next.selectNodeContents(first);
        getSelection().removeAllRanges(); getSelection().addRange(next);
        """)
        fixture.reader.speech.requestStart(.selection)
        for _ in 0..<100 where fixture.driver.requests.last?.text.hasPrefix("Alpha") != true { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(fixture.driver.requests.last?.text.hasPrefix("Alpha") == true)
        XCTAssertEqual(try MarkdownSource.read(fixture.file), fixture.source)
    }

    func testHighlightAndFollowOffNeverMoveFocusSelectionOrScroll() async throws {
        let fixture = try await makeFixture(); defer { fixture.close() }
        fixture.window.makeFirstResponder(fixture.web)
        _ = try await fixture.web.evaluateJavaScript("""
        const heading = document.querySelector('h1'); heading.tabIndex = -1; heading.focus({preventScroll:true});
        const range = document.createRange(); range.selectNodeContents(document.querySelector('p'));
        getSelection().removeAllRanges(); getSelection().addRange(range);
        """)
        let selected = try await fixture.web.evaluateJavaScript("getSelection().toString()") as? String
        fixture.reader.speech.setFollowReading(false)
        fixture.reader.speech.start(at: 3)
        var highlighted = false
        for _ in 0..<150 {
            highlighted = (try? await fixture.web.evaluateJavaScript("!!document.querySelector('.margined-speaking')")) as? Bool == true
            if highlighted { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(highlighted)
        let focused = try await fixture.web.evaluateJavaScript("document.activeElement.tagName") as? String
        let after = try await fixture.web.evaluateJavaScript("getSelection().toString()") as? String
        let scroll = try await fixture.web.evaluateJavaScript("scrollY") as? Double
        XCTAssertEqual(focused, "H1")
        XCTAssertEqual(after, selected)
        XCTAssertEqual(scroll, 0)
        fixture.reader.speech.session.seek(1)
        var moved = false
        for _ in 0..<100 {
            moved = (try? await fixture.web.evaluateJavaScript("document.querySelector('p').classList.contains('margined-speaking')")) as? Bool == true
            if moved { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(moved, "Speech advancement must update the existing WebKit view")
    }

    @MainActor private struct Fixture {
        let reader: ReaderState, driver: RecordingSpeechDriver, host: NSHostingController<ReaderView>
        let window: NSWindow, web: WKWebView, file: URL, source: String
        func close() { reader.stop(); window.close(); try? FileManager.default.removeItem(at: file) }
    }
    private func makeFixture() async throws -> Fixture {
        let name = "MarginedTests.SpeechPlayer.\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }
        let driver = RecordingSpeechDriver(), preferences = SpeechPreferences(defaults: defaults)
        let reader = ReaderState(speechFactory: { reader in
            ReaderSpeech(reader: reader, session: SpeechSession(driver: driver,
                voices: { [SpeechVoice(id: "test", name: "Test", language: "en-US", quality: 1)] },
                coordinator: SpeechCoordinator()), preferences: preferences, progress: SpeechProgressStore(defaults: defaults))
        })
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".md")
        let source = "# Section\n\nAlpha **bold** 👩🏽‍💻 ending.\n\n## Next\n\nOther text.\n"
        try source.write(to: file, atomically: true, encoding: .utf8); reader.source = source; reader.fileURL = file
        let host = NSHostingController(rootView: ReaderView(reader: reader)), window = NSWindow()
        window.isReleasedWhenClosed = false; window.contentViewController = host
        window.setContentSize(NSSize(width: 720, height: 680)); window.makeKeyAndOrderFront(nil)
        for _ in 0..<200 {
            if !reader.isRendering, let web = findWeb(host.view), !web.isLoading,
               (try? await web.evaluateJavaScript("!!document.querySelector('p')")) as? Bool == true {
                return Fixture(reader: reader, driver: driver, host: host, window: window, web: web, file: file, source: source)
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        reader.stop(); window.close(); try? FileManager.default.removeItem(at: file)
        throw NSError(domain: "SpeechPlayerTests", code: 1)
    }
    private func findWeb(_ view: NSView) -> WKWebView? {
        if let web = view as? WKWebView { return web }
        return view.subviews.lazy.compactMap { self.findWeb($0) }.first
    }
}
