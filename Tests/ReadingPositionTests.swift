import AppKit
import SwiftUI
import WebKit
import XCTest
@testable import Margined

@MainActor
final class ReadingPositionTests: XCTestCase {
    func testInsertionAboveViewportPreservesAnchorFocusSelectionAndImageNodes() async throws {
        let fixture = try await fixture()
        defer { fixture.close() }
        let web = fixture.web
        fixture.window.makeFirstResponder(web)
        let before = try await web.callAsyncJavaScript("""
        window.savedHeading = document.getElementById('margined-section-30');
        window.savedInput = document.querySelector('input[data-margined-task="30"]');
        window.savedImage = document.querySelector('img');
        window.savedText = window.savedHeading.nextElementSibling.nextElementSibling.firstChild;
        window.savedInput.focus({preventScroll:true});
        const range = document.createRange(); range.selectNodeContents(window.savedText);
        window.getSelection().removeAllRanges(); window.getSelection().addRange(range);
        window.scrollTo({top: window.savedHeading.getBoundingClientRect().top + window.scrollY - 25, behavior:'instant'});
        return {top:window.savedHeading.getBoundingClientRect().top, y:window.scrollY};
        """, arguments: [:], in: nil, contentWorld: MarkdownWebView.Coordinator.taskWorld) as! [String:Double]
        let updated = "# Inserted above\n\n" + String(repeating: "Additional context above the reading position. ", count: 30) + "\n\n" + fixture.source
        fixture.reader.acceptFileUpdate(updated)
        try await waitForHeading("margined-inserted-above", in: web)
        let result = try await web.callAsyncJavaScript("""
        return {
          heading: window.savedHeading === document.getElementById('margined-section-30'),
          input: window.savedInput === document.querySelector('input[data-margined-task="30"]'),
          image: window.savedImage === document.querySelector('img'),
          focus: document.activeElement === window.savedInput,
          selection: getSelection().anchorNode === window.savedText,
          top: document.getElementById('margined-section-30').getBoundingClientRect().top,
          y: window.scrollY
        };
        """, arguments: [:], in: nil, contentWorld: MarkdownWebView.Coordinator.taskWorld) as! [String:Any]
        for key in ["heading","input","image","focus","selection"] {
            XCTAssertEqual(result[key] as? Bool, true, "Refresh lost the existing \(key)")
        }
        XCTAssertEqual(result["top"] as! Double, before["top"]!, accuracy: 2)
        XCTAssertGreaterThan(result["y"] as! Double, before["y"]! + 100)
        XCTAssertEqual(try MarkdownSource.read(fixture.file), fixture.source, "Rendering must never write the file")
    }

    func testRemovedReadingAnchorUsesNextSurvivingBlock() async throws {
        let fixture = try await fixture()
        defer { fixture.close() }
        _ = try await fixture.web.callAsyncJavaScript("""
        const anchor = document.getElementById('margined-section-30');
        window.scrollTo({top: anchor.getBoundingClientRect().top + scrollY - 25, behavior:'instant'});
        """, arguments: [:], in: nil, contentWorld: MarkdownWebView.Coordinator.taskWorld)
        fixture.reader.acceptFileUpdate(fixture.source.replacingOccurrences(of: Self.section(30), with: ""))
        for _ in 0..<200 {
            if !fixture.reader.isRendering,
               let gone = try? await fixture.web.evaluateJavaScript("!document.getElementById('margined-section-30')") as? Bool, gone { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let top = try await fixture.web.evaluateJavaScript("document.getElementById('margined-section-31').getBoundingClientRect().top") as! Double
        XCTAssertEqual(top, 25, accuracy: 2, "A removed anchor should fall forward to the next surviving reading block")
    }

    func testPolicyNavigationRestoresSemanticAnchorRatherThanAbsoluteOffset() async throws {
        let fixture = try await fixture()
        defer { fixture.close() }
        fixture.reader.navigate(to:"margined-section-30")
        for _ in 0..<100 {
            if let focused = try? await fixture.web.evaluateJavaScript("document.activeElement.id === 'margined-section-30'") as? Bool, focused { break }
            try await Task.sleep(for:.milliseconds(20))
        }
        _ = try await fixture.web.callAsyncJavaScript("""
        const anchor = document.getElementById('margined-section-30');
        window.scrollTo({top: anchor.getBoundingClientRect().top + scrollY - 25, behavior:'instant'});
        window.oldDocument = document;
        """, arguments: [:], in: nil, contentWorld: MarkdownWebView.Coordinator.taskWorld)
        let beforePolicy = try await fixture.web.evaluateJavaScript("document.getElementById('margined-section-30').getBoundingClientRect().top") as! Double
        XCTAssertEqual(beforePolicy,25,accuracy:2,"Precondition: position before policy navigation")
        fixture.reader.loadRemoteImages = true
        for _ in 0..<200 {
            if let allowed = try? await fixture.web.evaluateJavaScript("document.querySelector('meta[http-equiv=\"Content-Security-Policy\"]').content.includes('https:')") as? Bool, allowed { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        for _ in 0..<200 {
            if !fixture.web.isLoading,
               let focused = try? await fixture.web.evaluateJavaScript("document.activeElement.id === 'margined-section-30'") as? Bool, focused { break }
            try await Task.sleep(for:.milliseconds(20))
        }
        let top = try await fixture.web.evaluateJavaScript("document.getElementById('margined-section-30').getBoundingClientRect().top") as! Double
        XCTAssertEqual(top, 25, accuracy: 2)
        let sameDocument = try await fixture.web.callAsyncJavaScript("return window.oldDocument === document;", arguments: [:], in: nil, contentWorld: MarkdownWebView.Coordinator.taskWorld) as! Bool
        XCTAssertFalse(sameDocument)
        let activeID = try await fixture.web.evaluateJavaScript("document.activeElement.id") as? String
        XCTAssertEqual(activeID,"margined-section-30","Policy reload should restore the document's focused reading target")
    }

    func testFindRequestedDuringSaveKeepsTypingFocusAfterSaveCompletes() async throws {
        let fixture = try await fixture()
        defer { fixture.close() }
        fixture.reader.checklistMode = true
        fixture.window.makeFirstResponder(fixture.web)
        _ = try await fixture.web.callAsyncJavaScript("""
        window.webkit.messageHandlers.taskToggle.postMessage({id:30,checked:true,token:window.marginedTaskState.token});
        """,arguments:[:],in:nil,contentWorld:MarkdownWebView.Coordinator.taskWorld)
        fixture.reader.showFind = true
        for _ in 0..<200 {
            if !fixture.reader.checklistSaving, !fixture.reader.isRendering,
               fixture.reader.source.contains("- [x] Task 30"),
               fixture.window.firstResponder is NSTextView { break }
            try await Task.sleep(for:.milliseconds(20))
        }
        try await Task.sleep(for:.milliseconds(100))
        XCTAssertTrue(fixture.window.firstResponder is NSTextView,"An earlier checkbox gesture must not steal a newer Find request")
        XCTAssertTrue(fixture.reader.source.contains("- [x] Task 30"))
    }

    func testOrdinaryFocusMovementDuringSaveIsNotOverridden() async throws {
        for nativeControl in [false, true] {
            let gate = SaveFocusGate()
            let fixture = try await fixture(checklistWriter: { url, source, task, marker in
                let result = try await ChecklistFileStore.setMarker(at: url, source: source, task: task, marker: marker)
                await gate.hold()
                return result
            })
            defer { gate.release(); fixture.close() }
            fixture.reader.checklistMode = true
            fixture.window.makeFirstResponder(fixture.web)
            _ = try await fixture.web.callAsyncJavaScript("""
            document.querySelector('input[data-margined-task="30"]').focus();
            window.webkit.messageHandlers.taskToggle.postMessage({id:30,checked:true,token:window.marginedTaskState.token});
            """, arguments: [:], in: nil, contentWorld: MarkdownWebView.Coordinator.taskWorld)
            for _ in 0..<200 where !gate.waiting { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertTrue(gate.waiting)
            let button = NSButton(title: "A different native control", target: nil, action: nil)
            if nativeControl {
                let host = try XCTUnwrap(fixture.window.contentView)
                let wrapper = NSView(frame: host.frame)
                fixture.window.contentView = wrapper
                wrapper.addSubview(host); wrapper.addSubview(button)
                fixture.window.makeFirstResponder(button)
            }
            else {
                _ = try await fixture.web.callAsyncJavaScript("""
                document.querySelector('a[href="#margined-section-40"]').focus();
                """, arguments: [:], in: nil, contentWorld: MarkdownWebView.Coordinator.taskWorld)
            }
            gate.release()
            for _ in 0..<200 where fixture.reader.checklistSaving || fixture.reader.isRendering { try await Task.sleep(for: .milliseconds(20)) }
            try await Task.sleep(for: .milliseconds(100))
            if nativeControl { XCTAssertTrue(fixture.window.firstResponder === button, "An ordinary native focus move must survive save completion") }
            else {
                let active = try await fixture.web.evaluateJavaScript("document.activeElement.getAttribute('href')") as? String
                XCTAssertEqual(active, "#margined-section-40", "An ordinary link focus move must survive save completion")
            }
        }
    }

    @MainActor private final class SaveFocusGate {
        var waiting = false
        private var continuation: CheckedContinuation<Void, Never>?
        func hold() async { waiting = true; await withCheckedContinuation { continuation = $0 } }
        func release() { continuation?.resume(); continuation = nil }
    }

    func testHeadingJumpFocusesDestinationAndNewerFindKeepsTypingFocus() async throws {
        let fixture = try await fixture()
        defer { fixture.close() }
        fixture.reader.showFind = true
        for _ in 0..<100 where !(fixture.window.firstResponder is NSTextView) { try await Task.sleep(for:.milliseconds(20)) }
        fixture.reader.navigate(to:"margined-section-40")
        for _ in 0..<100 {
            if let id = try? await fixture.web.evaluateJavaScript("document.activeElement.id") as? String, id == "margined-section-40" { break }
            try await Task.sleep(for:.milliseconds(20))
        }
        let id = try await fixture.web.evaluateJavaScript("document.activeElement.id") as? String
        XCTAssertEqual(id,"margined-section-40","Outline navigation must focus its heading, not just scroll")
        XCTAssertFalse(fixture.window.firstResponder is NSTextView,"Explicit document navigation should leave the Find field")
        fixture.reader.navigate(to:"margined-section-41")
        fixture.reader.showFind = true
        for _ in 0..<100 where !(fixture.window.firstResponder is NSTextView) { try await Task.sleep(for:.milliseconds(20)) }
        try await Task.sleep(for:.milliseconds(100))
        XCTAssertTrue(fixture.window.firstResponder is NSTextView,"A queued jump must not override a newer Find request")
        XCTAssertEqual(try MarkdownSource.read(fixture.file),fixture.source)
    }

    func testUncheckedTaskShortcutsSkipCheckedTasksWrapAndDoNotWrite() async throws {
        let fixture = try await fixture()
        defer { fixture.close() }
        fixture.reader.acceptFileUpdate(fixture.source.replacingOccurrences(of:"- [ ] Task 0\n",with:"- [x] Task 0\n"))
        for _ in 0..<200 {
            if !fixture.reader.isRendering,
               let ready = try? await fixture.web.evaluateJavaScript("document.querySelector('input').defaultChecked && !document.querySelector('input').disabled") as? Bool, ready { break }
            try await Task.sleep(for:.milliseconds(20))
        }
        fixture.reader.jumpToUncheckedTask()
        try await waitForActiveTask("1", in:fixture.web)
        fixture.reader.jumpToUncheckedTask(backwards:true)
        try await waitForActiveTask("59", in:fixture.web)
        fixture.reader.jumpToUncheckedTask()
        try await waitForActiveTask("1", in:fixture.web)
        XCTAssertEqual(try MarkdownSource.read(fixture.file),fixture.source)
    }

    func testUncheckedNavigationUsesActualFocusBeforeCachedTask() async throws {
        let fixture = try await fixture()
        defer { fixture.close() }
        fixture.reader.jumpToUncheckedTask()
        try await waitForActiveTask("0", in: fixture.web)
        _ = try await fixture.web.callAsyncJavaScript("document.querySelector('input[data-margined-task=\"3\"]').focus();",
            arguments: [:], in: nil, contentWorld: MarkdownWebView.Coordinator.taskWorld)
        fixture.reader.jumpToUncheckedTask()
        try await waitForActiveTask("4", in: fixture.web)
        fixture.reader.jumpToUncheckedTask(backwards: true)
        try await waitForActiveTask("3", in: fixture.web)
    }

    func testReturnToOutlineLeavesDocumentResponder() async throws {
        let fixture = try await fixture()
        defer { fixture.close() }
        fixture.reader.navigate(to: "margined-section-30")
        for _ in 0..<100 {
            if let focused = try? await fixture.web.evaluateJavaScript("document.activeElement.id === 'margined-section-30'") as? Bool, focused { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        fixture.reader.returnToNavigation()
        for _ in 0..<100 {
            let responder = fixture.window.firstResponder as? NSView
            if fixture.reader.showOutline, let responder,
               responder !== fixture.web, !responder.isDescendant(of: fixture.web) { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Returning to the outline must move the keyboard responder out of WebKit")
    }

    func testDocumentEntryKeepsReadingPositionAndReturnsToFind() async throws {
        let fixture = try await fixture()
        defer { fixture.close() }
        _ = try await fixture.web.callAsyncJavaScript("""
        const heading = document.getElementById('margined-section-30');
        window.scrollTo({top:scrollY+heading.getBoundingClientRect().top-25,behavior:'instant'});
        """,arguments:[:],in:nil,contentWorld:MarkdownWebView.Coordinator.taskWorld)
        fixture.reader.showFind = true
        for _ in 0..<100 where !(fixture.window.firstResponder is NSTextView) { try await Task.sleep(for:.milliseconds(20)) }
        fixture.reader.focusDocument()
        for _ in 0..<100 {
            if let focused = try? await fixture.web.evaluateJavaScript("document.activeElement.id === 'margined-section-30'") as? Bool, focused { break }
            try await Task.sleep(for:.milliseconds(20))
        }
        let top = try await fixture.web.evaluateJavaScript("document.getElementById('margined-section-30').getBoundingClientRect().top") as! Double
        XCTAssertEqual(top,25,accuracy:2)
        XCTAssertFalse(fixture.window.firstResponder is NSTextView)
        fixture.reader.returnToNavigation()
        for _ in 0..<100 where !(fixture.window.firstResponder is NSTextView) { try await Task.sleep(for:.milliseconds(20)) }
        XCTAssertTrue(fixture.window.firstResponder is NSTextView)
        XCTAssertEqual(try MarkdownSource.read(fixture.file),fixture.source)
    }

    private func waitForActiveTask(_ id:String,in web:WKWebView) async throws {
        for _ in 0..<100 {
            if let actual = try? await web.evaluateJavaScript("document.activeElement.dataset.marginedTask") as? String, actual == id { return }
            try await Task.sleep(for:.milliseconds(20))
        }
        let actual = try? await web.evaluateJavaScript("document.activeElement.outerHTML")
        XCTFail("Expected task \(id) focus, got \(String(describing:actual))")
    }

    func testFocusedHeadingSurvivesAnExternalInsertion() async throws {
        let fixture = try await fixture()
        defer { fixture.close() }
        fixture.reader.navigate(to:"margined-section-30")
        for _ in 0..<100 {
            if let focused = try? await fixture.web.evaluateJavaScript("document.activeElement.id === 'margined-section-30'") as? Bool, focused { break }
            try await Task.sleep(for:.milliseconds(20))
        }
        _ = try await fixture.web.callAsyncJavaScript("window.focusedHeading = document.activeElement;",arguments:[:],in:nil,contentWorld:MarkdownWebView.Coordinator.taskWorld)
        fixture.reader.acceptFileUpdate("# Extra context\n\nInserted above.\n\n" + fixture.source)
        try await waitForHeading("margined-extra-context",in:fixture.web)
        let retained = try await fixture.web.callAsyncJavaScript("return document.activeElement === window.focusedHeading && document.activeElement.id === 'margined-section-30';",arguments:[:],in:nil,contentWorld:MarkdownWebView.Coordinator.taskWorld) as! Bool
        XCTAssertTrue(retained,"Refreshing should retain the reader's focused heading")
    }

    @MainActor private struct Fixture {
        let reader: ReaderState
        let window: NSWindow
        let web: WKWebView
        let file: URL
        let source: String
        func close() { window.close(); reader.stop(); try? FileManager.default.removeItem(at: file) }
    }

    private static func section(_ index: Int) -> String {
        "## Section \(index)\n\n- [ ] Task \(index)\n\n" + String(repeating: "Reading context for section \(index). ", count: 12) + "\n\n"
    }

    private func fixture(checklistWriter: ReaderState.ChecklistWriter? = nil) async throws -> Fixture {
        let image = "![Context image](data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+j5iQAAAAASUVORK5CYII=)\n\n"
        let source = "# Reading\n\n" + image + "[Other section](#section-40)\n\n" + (0..<60).map { Self.section($0) }.joined()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".md")
        try source.write(to: file, atomically: true, encoding: .utf8)
        let reader = checklistWriter.map { ReaderState(checklistWriter: $0) } ?? ReaderState()
        reader.fileURL = file; reader.source = source
        reader.render()
        let controller = NSHostingController(rootView: ReaderView(reader: reader))
        let window = NSWindow(contentViewController: controller)
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 700, height: 500)); window.makeKeyAndOrderFront(nil)
        for _ in 0..<200 {
            if !reader.isRendering, let web = findWebView(controller.view), !web.isLoading,
               let ready = try? await web.evaluateJavaScript("!!document.getElementById('margined-section-30') && !document.querySelector('input').disabled") as? Bool, ready {
                return Fixture(reader:reader,window:window,web:web,file:file,source:source)
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        window.close(); reader.stop(); try? FileManager.default.removeItem(at: file)
        throw NSError(domain: "ReadingPositionTests",code:1,userInfo:[NSLocalizedDescriptionKey:"Reader did not load"])
    }

    private func waitForHeading(_ id: String, in web: WKWebView) async throws {
        for _ in 0..<200 {
            if let ready = try? await web.callAsyncJavaScript("return !!document.getElementById(id) && Array.from(document.querySelectorAll('input[data-margined-task]')).every(input => !input.disabled);",arguments:["id":id],in:nil,contentWorld:MarkdownWebView.Coordinator.taskWorld) as? Bool, ready { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Updated heading did not appear")
    }

    private func findWebView(_ view:NSView) -> WKWebView? {
        if let web = view as? WKWebView { return web }
        for child in view.subviews { if let web = findWebView(child) { return web } }
        return nil
    }
}
