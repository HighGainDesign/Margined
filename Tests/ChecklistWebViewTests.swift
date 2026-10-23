import AppKit
import SwiftUI
import WebKit
import XCTest
@testable import Margined

@MainActor
final class ChecklistWebViewTests: XCTestCase {
    func testFileCheckboxesInviteConsentAndDisableWhilePromptIsShown() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".md")
        let text = "- [ ] Check this task\n"
        try text.write(to: file, atomically: true, encoding: .utf8)
        let reader = ReaderState(); reader.fileURL = file; reader.source = text
        reader.render()
        let controller = NSHostingController(rootView: ReaderView(reader: reader))
        let window = NSWindow(contentViewController: controller)
        window.setContentSize(NSSize(width: 600, height: 400)); window.makeKeyAndOrderFront(nil)
        defer { window.close(); reader.stop(); try? FileManager.default.removeItem(at: file) }
        try await waitForDisabled(false, in: controller.view)
        reader.requestTaskChecked(0, checked: true)
        XCTAssertTrue(reader.showChecklistConfirmation)
        try await waitForDisabled(true, in: controller.view)
        XCTAssertEqual(try MarkdownSource.read(file), text)
        reader.cancelChecklistConfirmation()
        try await waitForDisabled(false, in: controller.view)
        XCTAssertNil(reader.checklistError)
        XCTAssertEqual(try MarkdownSource.read(file), text)
    }

    func testChecklistBridgeRestoresTaskFocusAfterCancelAndSave() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".md")
        let text = "- [ ] First\n- [ ] Second\n- [ ] Third\n"
        try text.write(to: file, atomically: true, encoding: .utf8)
        let reader = ReaderState(); reader.fileURL = file; reader.source = text; reader.render()
        let controller = NSHostingController(rootView: ReaderView(reader: reader))
        let window = NSWindow(contentViewController: controller)
        window.setContentSize(NSSize(width: 600, height: 400)); window.makeKeyAndOrderFront(nil)
        defer { window.close(); reader.stop(); try? FileManager.default.removeItem(at: file) }
        try await waitForDisabled(false, in: controller.view)
        let webView = try XCTUnwrap(findWebView(controller.view))
        window.makeFirstResponder(webView)
        // Exercise the real isolated-world message handler and reload path.
        // Production change listeners additionally require a trusted user event.
        let request = "window.webkit.messageHandlers.taskToggle.postMessage({id: 1, checked: true, token: window.marginedTaskState.token});"
        _ = try await webView.callAsyncJavaScript(request, arguments: [:], in: nil, contentWorld: MarkdownWebView.Coordinator.taskWorld)
        try await waitForDisabled(true, in: controller.view)
        reader.cancelChecklistConfirmation()
        try await waitForDisabled(false, in: controller.view)
        try await waitForFocus("1", in: webView)
        XCTAssertEqual(try MarkdownSource.read(file), text)
        _ = try await webView.callAsyncJavaScript(request, arguments: [:], in: nil, contentWorld: MarkdownWebView.Coordinator.taskWorld)
        try await waitForDisabled(true, in: controller.view)
        reader.confirmChecklistSaving()
        try await waitForDisabled(false, in: controller.view)
        try await waitForFocus("1", in: webView)
        XCTAssertEqual(try MarkdownSource.read(file), "- [ ] First\n- [x] Second\n- [ ] Third\n")
    }

    private func waitForFocus(_ id: String, in webView: WKWebView) async throws {
        for _ in 0..<150 {
            if !webView.isLoading,
               let value = try? await webView.evaluateJavaScript("document.activeElement?.dataset.marginedTask") as? String,
               value == id { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Focus was not restored to task \(id)")
    }

    func testSavingScrolledChecklistPreservesPageInputAndScrollPosition() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".md")
        let image = "![Context image](data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+j5iQAAAAASUVORK5CYII=)\n\n"
        let text = "# Long checklist\n\n" + image + (0..<60).map {
            "## Section \($0)\n\n- [ ] Task \($0)\n\n" + String(repeating: "Reading context for this task. ", count: 12) + "\n\n"
        }.joined()
        try text.write(to: file, atomically: true, encoding: .utf8)
        let reader = ReaderState(); reader.fileURL = file; reader.source = text; reader.checklistMode = true; reader.render()
        let controller = NSHostingController(rootView: ReaderView(reader: reader))
        let window = NSWindow(contentViewController: controller)
        window.setContentSize(NSSize(width: 600, height: 450)); window.makeKeyAndOrderFront(nil)
        defer { window.close(); reader.stop(); try? FileManager.default.removeItem(at: file) }
        try await waitForDisabled(false, in: controller.view)
        let webView = try XCTUnwrap(findWebView(controller.view))
        let before = try await webView.callAsyncJavaScript("""
        // Retain the actual document; performance.timeOrigin is a rounded clock, not an identity.
        window.marginedTestDocument = document;
        window.inputBefore = document.querySelector('input[data-margined-task="25"]');
        window.imageBefore = document.querySelector('img');
        window.inputBefore.scrollIntoView({block: 'center', behavior: 'instant'});
        return { y: window.scrollY };
        """, arguments: [:], in: nil, contentWorld: MarkdownWebView.Coordinator.taskWorld) as! [String: Double]
        XCTAssertGreaterThan(before["y"]!, 1_000)
        _ = try await webView.callAsyncJavaScript("""
        window.webkit.messageHandlers.taskToggle.postMessage({id: 25, checked: true, token: window.marginedTaskState.token});
        """, arguments: [:], in: nil, contentWorld: MarkdownWebView.Coordinator.taskWorld)
        var saved = false
        for _ in 0..<200 {
            if !reader.checklistSaving, !reader.isRendering,
               let checked = try? await webView.evaluateJavaScript("document.querySelector('input[data-margined-task=\"25\"]')?.defaultChecked") as? Bool,
               checked == true { saved = true; break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(saved)
        let after = try await webView.callAsyncJavaScript("""
        return { y: window.scrollY };
        """, arguments: [:], in: nil, contentWorld: MarkdownWebView.Coordinator.taskWorld) as! [String: Double]
        let sameDocument = try await webView.callAsyncJavaScript("return window.marginedTestDocument === document;",
            arguments: [:], in: nil, contentWorld: MarkdownWebView.Coordinator.taskWorld) as! Bool
        XCTAssertTrue(sameDocument, "A tick must not navigate to a new webpage")
        XCTAssertEqual(after["y"]!, before["y"]!, accuracy: 2)
        let sameInput = try await webView.callAsyncJavaScript("return document.querySelector('input[data-margined-task=\"25\"]') === window.inputBefore;",
            arguments: [:], in: nil, contentWorld: MarkdownWebView.Coordinator.taskWorld) as! Bool
        XCTAssertTrue(sameInput, "A tick should retain the original checkbox element")
        let sameImage = try await webView.callAsyncJavaScript("return !!window.imageBefore && document.querySelector('img') === window.imageBefore;",
            arguments: [:], in: nil, contentWorld: MarkdownWebView.Coordinator.taskWorld) as! Bool
        XCTAssertTrue(sameImage, "An unchanged image should not be recreated during a tick")
        XCTAssertEqual(try MarkdownSource.read(file), text.replacingOccurrences(of: "- [ ] Task 25\n", with: "- [x] Task 25\n"))
    }

    func testContentPolicyChangeStillNavigatesAndAppliesNewPolicy() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".md")
        try "- [ ] Task\n".write(to: file, atomically: true, encoding: .utf8)
        let reader = ReaderState(); reader.fileURL = file; reader.source = "- [ ] Task\n"; reader.render()
        let controller = NSHostingController(rootView: ReaderView(reader: reader))
        let window = NSWindow(contentViewController: controller)
        window.setContentSize(NSSize(width: 600, height: 400)); window.orderFront(nil)
        defer { window.close(); reader.stop(); try? FileManager.default.removeItem(at: file) }
        try await waitForDisabled(false, in: controller.view)
        let webView = try XCTUnwrap(findWebView(controller.view))
        _ = try await webView.evaluateJavaScript("window.marginedTestDocument = document; true")
        reader.loadRemoteImages = true // No image URLs in the sample; no network requests.
        var changed = false
        for _ in 0..<200 {
            if let allowed = try? await webView.evaluateJavaScript("document.querySelector('meta[http-equiv=\"Content-Security-Policy\"]').content.includes('https:')") as? Bool,
               allowed { changed = true; break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(changed)
        let sameDocument = try await webView.evaluateJavaScript("window.marginedTestDocument === document") as! Bool
        XCTAssertFalse(sameDocument, "Policy changes must use a fresh navigation")
    }

    private func waitForDisabled(_ expected: Bool, in view: NSView) async throws {
        for _ in 0..<150 {
            // Wait for the native sheet lifecycle, not only the earlier DOM state.
            // Disable animation in this fixture to avoid macOS27's UpdateCycle
            // close-sheet crash; actual app consent behavior remains unchanged.
            if expected {
                guard let sheet = view.window?.attachedSheet else {
                    try await Task.sleep(for: .milliseconds(20)); continue
                }
                sheet.animationBehavior = .none
            } else if view.window?.attachedSheet != nil {
                try await Task.sleep(for: .milliseconds(20)); continue
            }
            if let webView = findWebView(view), webView.url != nil, !webView.isLoading,
               let value = try? await webView.evaluateJavaScript("document.querySelector('input')?.disabled") as? Bool,
               value == expected { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Checklist checkbox disabled state did not become \(expected)")
    }

    private func findWebView(_ view: NSView) -> WKWebView? {
        if let webView = view as? WKWebView { return webView }
        for child in view.subviews { if let found = findWebView(child) { return found } }
        return nil
    }
}
