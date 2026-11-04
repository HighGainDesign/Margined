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
        // BEGIN PASSIVE-NATIVE-PRECONDITIONS draft-reader
        func observeDraftNative(_ phase: String) -> (record: [String: Any], font: UIFont?) {
            let epoch = Date().timeIntervalSince1970
            let uptime = ProcessInfo.processInfo.systemUptime
            let bounds = editor.bounds, adjusted = editor.adjustedContentInset, inset = editor.contentInset
            let font = editor.font, selection = editor.selectedRange, focused = editor.isFirstResponder
            let offset = editor.contentOffset, content = editor.contentSize, attachedWindow = editor.window
            var signature: [String: Any] = ["boundsSize": ["width": Double(bounds.width), "height": Double(bounds.height)],
                "adjustedContentInset": ["top": Double(adjusted.top), "left": Double(adjusted.left), "bottom": Double(adjusted.bottom), "right": Double(adjusted.right)],
                "selectedRange": ["location": selection.location, "length": selection.length], "focused": focused]
            if let font {
                signature["font"] = ["objectIdentity": String(describing: ObjectIdentifier(font)),
                    "name": font.fontName, "family": font.familyName, "pointSize": Double(font.pointSize),
                    "descriptorPostscriptName": font.fontDescriptor.postscriptName,
                    "descriptorPointSize": Double(font.fontDescriptor.pointSize),
                    "descriptorTraits": Int(font.fontDescriptor.symbolicTraits.rawValue),
                    "descriptorAttributes": String(describing: font.fontDescriptor.fontAttributes)]
            } else { signature["font"] = NSNull() }
            var value: [String: Any] = ["phase": phase, "epoch": epoch, "uptime": uptime,
                "editorIdentity": String(describing: ObjectIdentifier(editor)), "layoutSignature": signature,
                "boundsOrigin": ["x": Double(bounds.origin.x), "y": Double(bounds.origin.y)],
                "contentOffset": ["x": Double(offset.x), "y": Double(offset.y)],
                "contentSize": ["width": Double(content.width), "height": Double(content.height)],
                "contentInset": ["top": Double(inset.top), "left": Double(inset.left), "bottom": Double(inset.bottom), "right": Double(inset.right)],
                "attachedToWindow": attachedWindow != nil, "attachedToFixtureWindow": attachedWindow === window,
                "presentationBounds": String(describing: editor.layer.presentation()?.bounds)]
            if let attachedWindow {
                value["windowIdentity"] = String(describing: ObjectIdentifier(attachedWindow))
                value["windowKey"] = attachedWindow.isKeyWindow
                value["windowHidden"] = attachedWindow.isHidden
            }
            return (value, font)
        }
        // END PASSIVE-NATIVE-PRECONDITIONS draft-reader
        editor.inputView = UIView(frame: .zero) // This case needs no software keyboard.
        XCTAssertTrue(editor.becomeFirstResponder())
        let ready = await poll { editor.bounds.height > 40 && editor.contentSize.height > 800 }
        XCTAssertTrue(ready)
        editor.selectedRange = NSRange(location: 0, length: 0)
        editor.setNeedsLayout(); editor.layoutIfNeeded()
        let target = CGPoint(x: 0, y: 500)
        // BEGIN PASSIVE-NATIVE-PRECONDITIONS draft-before-scroll
        let nativeBeforeScroll = observeDraftNative("before-existing-setContentOffset")
        // END PASSIVE-NATIVE-PRECONDITIONS draft-before-scroll
        editor.setContentOffset(target, animated: false)
        editor.setNeedsLayout(); editor.layoutIfNeeded()
        // BEGIN PASSIVE-NATIVE-PRECONDITIONS draft-after-layout
        let nativeAfterLayout = observeDraftNative("after-existing-layoutIfNeeded")
        let fontValueEqualBeforeAfterLayout = editor.font == nativeBeforeScroll.font
        // END PASSIVE-NATIVE-PRECONDITIONS draft-after-layout
        for _ in 0..<10 { try await Task.sleep(for: .milliseconds(20)) }
        // BEGIN PASSIVE-NATIVE-PRECONDITIONS draft-after-wait
        let nativeAfterWait = observeDraftNative("after-existing-ten-sleeps-before-assertions")
        let fontValueEqualBeforeAfterWait = editor.font == nativeBeforeScroll.font
        // END PASSIVE-NATIVE-PRECONDITIONS draft-after-wait
        XCTAssertEqual(editor.contentOffset.y, target.y, accuracy: 1,
                       "Unrelated layout must not pull a deliberately scrolled draft back to its caret")
        XCTAssertEqual(editor.selectedRange, NSRange(location: 0, length: 0))
        XCTAssertTrue(editor.isFirstResponder)
        // BEGIN PASSIVE-NATIVE-PRECONDITIONS draft-failure-log
        if abs(editor.contentOffset.y - target.y) > 1 {
            let report: [String: Any] = ["test": self.name, "targetY": Double(target.y),
                "observations": [nativeBeforeScroll.record, nativeAfterLayout.record, nativeAfterWait.record],
                "fontValueEqualBeforeAfterLayout": fontValueEqualBeforeAfterLayout,
                "fontValueEqualBeforeAfterWait": fontValueEqualBeforeAfterWait]
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]) {
                print("IOS-DRAFT-NATIVE-PRECONDITIONS " + String(decoding: data, as: UTF8.self))
            }
        }
        // END PASSIVE-NATIVE-PRECONDITIONS draft-failure-log
        window.frame.size.height = 200
        host.view.frame = window.bounds; host.view.layoutIfNeeded()
        let revealed = await poll {
            guard let selection = editor.selectedTextRange else { return false }
            return editor.bounds.contains(editor.caretRect(for: selection.start))
        }
        XCTAssertTrue(revealed, "A changed viewport must reveal the retained caret")
        XCTAssertEqual(reader.discussions.drafts[key]?.body, text)
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
