import SwiftUI
import UIKit
import WebKit
import XCTest
@testable import MarginediOS

@MainActor
final class ResponseControlsTests: XCTestCase {
    func testTextOnlyDocumentOffersNamedAnswerControlWithoutEnablingAutosave() async throws {
        let f = try await fixture("**Device and OS (short answer):** _Not answered_\n")
        let available = try await poll {
            try await f.web.evaluateJavaScript("document.querySelectorAll('button[data-margined-answer-action]').length") as? Int == 1
        }
        XCTAssertTrue(available, "A text-only document needs an answer control even without checkboxes")
        let label = try await f.web.evaluateJavaScript("document.querySelector('button[data-margined-answer-action]')?.getAttribute('aria-label')") as? String
        XCTAssertTrue(label?.contains("Device and OS") == true)
        XCTAssertFalse(f.reader.checklistMode)
        XCTAssertEqual(try Data(contentsOf: f.file), f.original)
    }

    func testImportedConflictHasVisibleAccessibleWarningWithoutRepairingFile() async throws {
        let f = try await fixture("**Result (choose one):**\n\n- [X] A\n- [x] B\n")
        let warned = try await poll {
            try await f.web.evaluateJavaScript("document.querySelectorAll('[data-margined-response-warning]').length") as? Int == 1
        }
        XCTAssertTrue(warned)
        let described = try await f.web.evaluateJavaScript("document.querySelector('ul[data-margined-choice]')?.getAttribute('aria-describedby')") as? String
        XCTAssertFalse(described?.isEmpty ?? true)
        XCTAssertEqual(try Data(contentsOf: f.file), f.original)
    }

    func testAnswerBridgePresentsFocusedNativeEditorAndCancelDoesNotWrite() async throws {
        let f = try await fixture("**Notes (short answer):** Original\n")
        let available = try await poll {
            try await f.web.evaluateJavaScript("!!document.querySelector('button[data-margined-answer-action]')") as? Bool == true
        }
        XCTAssertTrue(available)
        f.web.becomeFirstResponder()
        _ = try await f.web.evaluateJavaScript("document.querySelector('button[data-margined-answer-action]').focus()")
        _ = try await f.web.callAsyncJavaScript("""
        window.webkit.messageHandlers.taskToggle.postMessage({kind:'answer',id:0,token:window.marginedTaskState.token});
        """, arguments: [:], in: nil, contentWorld: MobileWebView.Coordinator.contentWorld)
        let opened = try await poll { f.reader.answerDraft != nil }
        XCTAssertTrue(opened); guard opened else { return }
        let presented = try await poll { self.editor(in: f.host.presentedViewController?.view) != nil }
        XCTAssertTrue(presented); guard presented else { return }
        let input = try XCTUnwrap(editor(in: f.host.presentedViewController?.view))
        XCTAssertEqual(input.accessibilityLabel, "Notes")
        XCTAssertEqual(input.text, "Original")
        let focused = try await poll { input.isFirstResponder }
        XCTAssertTrue(focused)
        input.selectedRange = NSRange(location: input.text.utf16.count, length: 0)
        input.insertText(" changed")
        let typed = try await poll { f.reader.answerDraft?.text == "Original changed" }
        XCTAssertTrue(typed)
        XCTAssertEqual(try Data(contentsOf: f.file), f.original)
        XCTAssertTrue(input.undoManager?.canUndo == true, "Native input registered typing Undo")
        input.undoManager?.undo()
        let undone = try await poll { f.reader.answerDraft?.text == "Original" }
        XCTAssertEqual(input.text, "Original", "Native text after Undo")
        XCTAssertTrue(undone, "Typing Undo belongs to the input, not the file; draft=\(f.reader.answerDraft?.text ?? "nil")")
        input.undoManager?.redo()
        let redone = try await poll { f.reader.answerDraft?.text == "Original changed" }
        XCTAssertTrue(redone)
        f.reader.cancelAnswer()
        let dismissed = try await poll { f.host.presentedViewController == nil }
        XCTAssertTrue(dismissed)
        let returned = try await poll {
            try await f.web.evaluateJavaScript("document.activeElement?.hasAttribute('data-margined-answer-action')") as? Bool == true
        }
        XCTAssertTrue(returned, "Cancel returns document focus to the originating answer")
        XCTAssertEqual(try Data(contentsOf: f.file), f.original)
        XCTAssertFalse(f.reader.checklistMode)
        XCTAssertTrue(f.reader.beginAnswer(0))
        let reopened = try await poll {
            guard let next = self.editor(in: f.host.presentedViewController?.view) else { return false }
            return next !== input && next.isFirstResponder
        }
        XCTAssertTrue(reopened)
        XCTAssertFalse(editor(in: f.host.presentedViewController?.view)?.undoManager?.canUndo == true,
            "A new editor must not inherit the canceled editor's typing history")
    }

    func testNativeEditorSavesLiteralAnswerAndRetainsItsViewAcrossLargeTextResize() async throws {
        let f = try await fixture("**Notes (short answer):** Original\n")
        XCTAssertTrue(f.reader.beginAnswer(0))
        let presented = try await poll { self.editor(in: f.host.presentedViewController?.view) != nil }
        XCTAssertTrue(presented); guard presented else { return }
        let input = try XCTUnwrap(editor(in: f.host.presentedViewController?.view))
        input.selectedRange = NSRange(location: 0, length: input.text.utf16.count)
        input.insertText("A *literal* https://example.com :smile:")
        let expected = input.text!
        let initialFontSize = input.font?.pointSize ?? 0
        f.host.presentedViewController?.traitOverrides.preferredContentSizeCategory = .accessibilityExtraExtraExtraLarge
        f.window.frame.size = CGSize(width: 820, height: 1000)
        f.host.view.layoutIfNeeded()
        XCTAssertTrue(editor(in: f.host.presentedViewController?.view) === input)
        XCTAssertEqual(input.text, expected)
        let scaled = try await poll { (input.font?.pointSize ?? 0) > initialFontSize }
        XCTAssertTrue(scaled, "Accessibility text sizing must reach the retained native input")
        f.reader.saveAnswer()
        let saved = try await poll { f.reader.answerDraft == nil && !f.reader.fileSaving && !f.reader.isRendering }
        XCTAssertTrue(saved)
        XCTAssertEqual(f.reader.rendered?.responses.answers.first?.plainValue, expected)
        XCTAssertFalse(f.reader.checklistMode)
        f.reader.undoChecklist()
        let undone = try await poll { !f.reader.fileSaving && !f.reader.isRendering && (try? Data(contentsOf: f.file)) == f.original }
        XCTAssertTrue(undone)
    }

    func testOldTokenCannotOpenAnswerAfterEncodingOnlyRefresh() async throws {
        let f = try await fixture("**Notes (short answer):** Original\n")
        let oldToken = try await f.web.callAsyncJavaScript("return window.marginedTaskState.token;", arguments: [:], in: nil,
            contentWorld: MobileWebView.Coordinator.contentWorld) as? String
        let encoded = Data([0xFF, 0xFE]) + (try XCTUnwrap(f.reader.source.data(using: .utf16LittleEndian)))
        try encoded.write(to: f.file, options: .atomic)
        await f.reader.refresh(); await f.reader.waitForRendering()
        let rebound = try await poll {
            try await f.web.callAsyncJavaScript("return window.marginedTaskState.token;", arguments: [:], in: nil,
                contentWorld: MobileWebView.Coordinator.contentWorld) as? String != oldToken
        }
        XCTAssertTrue(rebound)
        _ = try await f.web.callAsyncJavaScript("window.webkit.messageHandlers.taskToggle.postMessage({kind:'answer',id:0,token:oldToken});",
            arguments: ["oldToken": try XCTUnwrap(oldToken)], in: nil, contentWorld: MobileWebView.Coordinator.contentWorld)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertNil(f.reader.answerDraft)
        XCTAssertEqual(try Data(contentsOf: f.file), encoded)
    }

    func testUntrustedClickCannotOpenEditorAndEditingDisablesSourceControls() async throws {
        let f = try await fixture("**Notes (short answer):** Original\n\n- [ ] Ordinary\n")
        let available = try await poll {
            try await f.web.evaluateJavaScript("!!document.querySelector('button[data-margined-answer-action]')") as? Bool == true
        }
        XCTAssertTrue(available)
        _ = try await f.web.evaluateJavaScript("document.querySelector('button[data-margined-answer-action]').click()")
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(f.reader.answerDraft, "Only a trusted user click may dispatch the bridge")
        XCTAssertTrue(f.reader.beginAnswer(0))
        let disabled = try await poll {
            try await f.web.evaluateJavaScript("Array.from(document.querySelectorAll('input[data-margined-task],button[data-margined-answer-action]')).every(x=>x.disabled)") as? Bool == true
        }
        XCTAssertTrue(disabled)
        f.reader.answerDraft?.text = "Keep this recovery draft"
        let changed = Data("**Notes (short answer):** External version\n\n- [ ] Ordinary\n".utf8)
        try changed.write(to: f.file, options: .atomic)
        await f.reader.refresh(); await f.reader.waitForRendering()
        XCTAssertFalse(f.reader.canSaveAnswer)
        XCTAssertTrue(f.reader.answerDraft?.stale == true)
        f.reader.saveAnswer()
        XCTAssertEqual(f.reader.answerDraft?.text, "Keep this recovery draft")
        XCTAssertEqual(try Data(contentsOf: f.file), changed)
        let validation = try await poll {
            self.editor(in: f.host.presentedViewController?.view)?.text == "Keep this recovery draft"
        }
        XCTAssertTrue(validation)
    }

    private struct Fixture {
        let reader: MobileReaderState
        let file: URL
        let original: Data
        let host: UIViewController
        let web: WKWebView
        let window: UIWindow
    }

    private func fixture(_ source: String) async throws -> Fixture {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".md")
        let original = Data(source.utf8); try original.write(to: file)
        let reader = MobileReaderState()
        await reader.open(url: file); await reader.waitForRendering()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let host = UIHostingController(rootView: MobileDocumentWorkspace(reader: reader, openFolder: {}, closeFile: {}))
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 780)
        window.rootViewController = host; window.makeKeyAndVisible()
        host.loadViewIfNeeded(); host.view.layoutIfNeeded()
        addTeardownBlock { @MainActor in
            reader.cancelAnswer(); await reader.close()
            window.isHidden = true; window.rootViewController = nil
            try? FileManager.default.removeItem(at: file)
        }
        let committed = await WebKitTestReadiness.navigation({ self.web(in: host.view) }, expectedURL: file.deletingLastPathComponent())
        let web = try XCTUnwrap(committed)
        let configured = try await poll {
            try await web.callAsyncJavaScript("return typeof window.marginedTaskState?.token === 'string';", arguments: [:], in: nil,
                contentWorld: MobileWebView.Coordinator.contentWorld) as? Bool == true
        }
        XCTAssertTrue(configured)
        return .init(reader: reader, file: file, original: original, host: host, web: web, window: window)
    }

    private func web(in view: UIView) -> WKWebView? {
        if let web = view as? WKWebView { return web }
        return view.subviews.lazy.compactMap { self.web(in: $0) }.first
    }
    private func editor(in view: UIView?) -> UITextView? {
        guard let view else { return nil }
        if let text = view as? UITextView, text.accessibilityIdentifier == "short-answer-input" { return text }
        return view.subviews.lazy.compactMap { self.editor(in: $0) }.first
    }
    private func poll(_ condition: () async throws -> Bool) async throws -> Bool {
        for _ in 0..<160 {
            if try await condition() { return true }
            try await Task.sleep(for: .milliseconds(25))
        }
        return false
    }
}
