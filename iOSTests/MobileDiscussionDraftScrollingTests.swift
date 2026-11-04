import SwiftUI
import UIKit
import XCTest
@testable import MarginediOS

@MainActor
final class MobileDiscussionDraftScrollingTests: XCTestCase {
    func testBrowsingAFocusedDraftStaysPutUntilItsViewportChanges() async throws {
        let suite = "MarginedTests.DraftScrolling." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let reader = MobileReaderState(defaults: defaults)
        let key = DiscussionSession.DraftKey.thread("scroll-fixture")
        let text = (0..<100).map { "Reply line \($0)." }.joined(separator: "\n")
        reader.discussions.setDraft(text, for: key)
        reader.discussionComposerSelections[key] = NSRange(location: 0, length: 0)
        let host = UIHostingController(rootView: MobileDiscussionDraftEditor(reader: reader, key: key,
            text: Binding(get: { reader.discussions.drafts[key]?.body ?? "" },
                          set: { reader.discussions.setDraft($0, for: key) }), document: reader.documentGeneration)
            .frame(maxWidth: .infinity, maxHeight: .infinity))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 320, height: 240)
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        host.loadViewIfNeeded(); host.view.layoutIfNeeded()
        let editor = try XCTUnwrap(findEditor(host.view))
        editor.inputView = UIView(frame: .zero) // This case needs no software keyboard.
        XCTAssertTrue(editor.becomeFirstResponder())
        let ready = await poll { editor.bounds.height > 40 && editor.contentSize.height > 800 }
        XCTAssertTrue(ready)
        editor.selectedRange = NSRange(location: 0, length: 0)
        editor.setNeedsLayout(); editor.layoutIfNeeded()
        let target = CGPoint(x: 0, y: 500)
        editor.setContentOffset(target, animated: false)
        editor.setNeedsLayout(); editor.layoutIfNeeded()
        for _ in 0..<10 { try await Task.sleep(for: .milliseconds(20)) }
        let actualOffset = editor.contentOffset.y
        #if MARGINED_DRAFT_LAYOUT_DIAGNOSTIC
        let observationTime = CACurrentMediaTime()
        #endif
        XCTAssertEqual(actualOffset, target.y, accuracy: 1,
                       "Unrelated layout must not pull a deliberately scrolled draft back to its caret")
        #if MARGINED_DRAFT_LAYOUT_DIAGNOSTIC
        (editor as? any DiscussionDraftLayoutDiagnostics)?.freezeDraftLayoutDiagnostics()
        #endif
        XCTAssertEqual(editor.selectedRange, NSRange(location: 0, length: 0))
        XCTAssertTrue(editor.isFirstResponder)
        window.frame.size.height = 200
        host.view.frame = window.bounds; host.view.layoutIfNeeded()
        let revealed = await poll {
            guard let selection = editor.selectedTextRange else { return false }
            return editor.bounds.contains(editor.caretRect(for: selection.start))
        }
        XCTAssertTrue(revealed, "A changed viewport must reveal the retained caret")
        XCTAssertEqual(reader.discussions.drafts[key]?.body, text)
        #if MARGINED_DRAFT_LAYOUT_DIAGNOSTIC
        if let diagnostic = editor as? any DiscussionDraftLayoutDiagnostics {
            print("DRAFT-LIGHT-LAYOUT-DIAGNOSTIC time=\(observationTime) observedOffset=\(actualOffset) \(diagnostic.draftLayoutDiagnosticReport())")
        }
        #endif
    }

    private func findEditor(_ view: UIView) -> UITextView? {
        if let editor = view as? UITextView { return editor }
        return view.subviews.lazy.compactMap { self.findEditor($0) }.first
    }
    private func poll(_ predicate: () -> Bool) async -> Bool {
        for _ in 0..<100 {
            if predicate() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return false
    }
}
