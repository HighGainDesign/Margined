import SwiftUI
import UIKit
import WebKit
import XCTest
@testable import MarginediOS

@MainActor final class MobileDiscussionInteractionTests: XCTestCase {
    func testActualFormattedSelectionStartsAnUnpostedNativeComposer() async throws {
        let f = try await fixture()
        _ = try await f.web.callAsyncJavaScript("""
        const paragraph=Array.from(document.querySelectorAll('main p')).find(p=>p.textContent.includes('bold'));
        const range=document.createRange();range.selectNodeContents(paragraph);
        getSelection().removeAllRanges();getSelection().addRange(range);return true;
        """, arguments: [:], in: nil, contentWorld: .defaultClient)
        f.reader.requestAddDiscussion()
        let selected = await poll { f.reader.discussions.selection != nil }
        XCTAssertTrue(selected, "Add Discussion must read the current native WebKit selection")
        if let key = f.reader.discussions.selection {
            XCTAssertEqual(f.reader.discussions.drafts[key]?.target?.exact, "Café bold passage.")
            XCTAssertEqual(f.reader.discussionRoute, key)
            f.reader.discussions.setDraft("Keep this unposted note.", for: key)
            let visible = await poll { self.editor(in: f.host.view)?.text == "Keep this unposted note." }
            XCTAssertTrue(visible, "The composer belongs to the native UI, outside the document WebView")
        }
        XCTAssertEqual(try Data(contentsOf: f.file), f.original)
    }

    func testDiscussionVisibilityDecoratesExistingPageWithoutReloadingOrWriting() async throws {
        let f = try await fixture(withThread: true)
        _ = try await f.web.evaluateJavaScript("window.mobileDiscussionPage=document;true")
        f.reader.inspector = .discussions
        let decorated = await pollAsync {
            try await f.web.evaluateJavaScript("document.querySelectorAll('[data-margined-thread]').length") as? Int == 1
        }
        XCTAssertTrue(decorated, "Showing discussions must install the shared isolated marker bridge")
        f.reader.hideDiscussions()
        let hidden = await pollAsync {
            try await f.web.evaluateJavaScript("document.querySelectorAll('[data-margined-thread]').length") as? Int == 0
        }
        XCTAssertTrue(hidden)
        XCTAssertNil(f.reader.inspector)
        let retained = try await f.web.evaluateJavaScript("window.mobileDiscussionPage===document") as? Bool
        XCTAssertEqual(retained, true)
        XCTAssertTrue(self.webView(in: f.host.view) === f.web)
        XCTAssertEqual(try Data(contentsOf: f.file), f.original)
    }

    func testBackAndWidthChangesRetainReplyAndTheMountedReadingPage() async throws {
        let f = try await fixture(withThread: true)
        _ = try await f.web.evaluateJavaScript("window.mobileDiscussionPage=document;true")
        f.reader.openDiscussion("t-mobile")
        f.reader.discussions.setDraft("A reply retained across layouts.", for: .thread("t-mobile"))
        let composer = await poll { self.editor(in: f.host.view)?.text == "A reply retained across layouts." }
        XCTAssertTrue(composer, "Opening a thread must expose its native reply editor")
        XCTAssertEqual(f.reader.discussionRoute, .thread("t-mobile"))
        f.reader.backToDiscussionList()
        XCTAssertNil(f.reader.discussionRoute)
        XCTAssertEqual(f.reader.inspector, .discussions)
        f.reader.hideDiscussions()
        XCTAssertNil(f.reader.inspector)
        f.window.frame.size = CGSize(width: 1_024, height: 780)
        f.host.view.frame = f.window.bounds; f.host.view.layoutIfNeeded()
        f.reader.openDiscussion("t-mobile")
        let visibleAfterResize = await poll { self.editor(in: f.host.view)?.text == "A reply retained across layouts." }
        XCTAssertTrue(visibleAfterResize)
        f.reader.inspector = .changes
        f.reader.inspector = .discussions
        XCTAssertEqual(f.reader.discussions.drafts[.thread("t-mobile")]?.body, "A reply retained across layouts.")
        f.reader.hideDiscussions()
        _ = await poll { self.webView(in: f.host.view) != nil }
        XCTAssertTrue(webView(in: f.host.view) === f.web)
        let retained = try await f.web.evaluateJavaScript("window.mobileDiscussionPage===document") as? Bool
        XCTAssertEqual(retained, true)
        XCTAssertEqual(try Data(contentsOf: f.file), f.original)
    }

    func testFirstPostKeepsTheSavedConversationOpenAndCanReply() async throws {
        let f = try await fixture()
        _ = try await f.web.callAsyncJavaScript("""
        const paragraph=Array.from(document.querySelectorAll('main p')).find(p=>p.textContent.includes('bold'));
        const range=document.createRange();range.selectNodeContents(paragraph);
        getSelection().removeAllRanges();getSelection().addRange(range);return true;
        """, arguments: [:], in: nil, contentWorld: .defaultClient)
        f.reader.requestAddDiscussion()
        let selected = await poll { f.reader.discussions.selection != nil }
        XCTAssertTrue(selected)
        let draft = try XCTUnwrap(f.reader.discussions.selection)
        f.reader.discussions.displayName = "Test Author"
        f.reader.discussions.setDraft("The first saved note.", for: draft)
        f.reader.postDiscussion()
        let saved = await poll { !f.reader.fileSaving && !f.reader.isRendering && f.reader.rendered?.discussions?.threads.count == 1 }
        XCTAssertTrue(saved, "The first post must finish its real coordinated file save")
        let thread = try XCTUnwrap(try DiscussionCodec.parse(MarkdownSource.read(f.file)).threads.first)
        XCTAssertEqual(thread.messages.first?.body, "The first saved note.")
        XCTAssertEqual(f.reader.discussionRoute, .thread(thread.id), "The saved conversation must replace its now-empty new-draft route")
        XCTAssertEqual(f.reader.discussions.selection, .thread(thread.id))
        let mounted = await poll { self.editor(in: f.host.view) != nil }
        XCTAssertTrue(mounted)
        let reply = try XCTUnwrap(self.editor(in: f.host.view))
        reply.text = "A reply from the mounted composer."
        reply.delegate?.textViewDidChange?(reply)
        XCTAssertEqual(f.reader.discussions.drafts[.thread(thread.id)]?.body, "A reply from the mounted composer.")
        XCTAssertNil(f.reader.discussions.drafts[draft], "Typing the reply must not recreate the old new-thread composer")
        f.reader.postDiscussion()
        let replied = await poll { !f.reader.fileSaving && !f.reader.isRendering && f.reader.rendered?.discussions?.threads.first?.messages.count == 2 }
        XCTAssertTrue(replied)
        XCTAssertEqual(try DiscussionCodec.parse(MarkdownSource.read(f.file)).threads.count, 1)
        XCTAssertTrue(try MarkdownSource.read(f.file).hasPrefix(try MarkdownSource.decode(f.original)))
    }

    func testExternalResolveKeepsTheUnpostedReplyReachableInTheRegularMargin() async throws {
        let f = try await fixture(withThread: true)
        f.window.frame.size = CGSize(width: 1_024, height: 780)
        f.host.view.frame = f.window.bounds; f.host.view.layoutIfNeeded()
        let regular = await poll { f.reader.discussionUsesMargin }
        XCTAssertTrue(regular, "The fixture must actually use the measured regular-width margin")
        f.reader.openDiscussion("t-mobile")
        f.reader.discussions.setDraft("Keep this reply while another author resolves.", for: .thread("t-mobile"))
        let before = await poll { self.editor(in: f.host.view)?.text == "Keep this reply while another author resolves." }
        XCTAssertTrue(before)
        let parsed = try DiscussionCodec.parse(MarkdownSource.read(f.file))
        let replacement = try MarkdownSourceEdits.apply(DiscussionEdits.splices(for:
            .resolve(threadID: "t-mobile", author: "Other Author", created: "2026-10-24T10:00:00Z"), in: parsed),
            to: Data(contentsOf: f.file), expectedSource: parsed.source)
        try replacement.write(to: f.file, options: .atomic)
        await f.reader.refresh(); await f.reader.waitForRendering()
        XCTAssertEqual(f.reader.discussions.filter, .open)
        XCTAssertEqual(f.reader.rendered?.discussions?.threads.first?.state, .resolved)
        let retained = await poll { self.editor(in: f.host.view)?.text == "Keep this reply while another author resolves." }
        XCTAssertTrue(retained, "A filter-changing refresh must not remove the only visible route to an unposted reply")
        XCTAssertEqual(f.reader.discussions.drafts[.thread("t-mobile")]?.body, "Keep this reply while another author resolves.")
        XCTAssertEqual(try Data(contentsOf: f.file), replacement, "Refresh and retained draft presentation must not write")
    }

    func testNoSelectionOffersNativePassagesAndStartsAnUnpostedComment() async throws {
        let f = try await fixture()
        _ = try await f.web.evaluateJavaScript("getSelection().removeAllRanges();true")
        f.reader.requestAddDiscussion()
        let offered = await poll { f.reader.discussionPassagePicker != nil }
        XCTAssertTrue(offered, "Add without a text selection must offer accessible semantic passages")
        guard let picker = f.reader.discussionPassagePicker else { return }
        let presented = await poll { f.host.presentedViewController != nil }
        XCTAssertTrue(presented, "The passage chooser must be a mounted native sheet")
        let unit = try XCTUnwrap(picker.projection.units.first { $0.text == "Café bold passage." })
        XCTAssertNil(f.reader.discussions.selection)
        XCTAssertEqual(try Data(contentsOf: f.file), f.original)
        f.reader.confirmDiscussionPassage(unit.id)
        XCTAssertNil(f.reader.discussionPassagePicker)
        let key = try XCTUnwrap(f.reader.discussions.selection)
        XCTAssertEqual(f.reader.discussions.drafts[key]?.target?.exact, "Café bold passage.")
        let composer = await poll { self.editor(in: f.host.view) != nil }
        XCTAssertTrue(composer)
        XCTAssertEqual(try Data(contentsOf: f.file), f.original, "Choosing a passage only starts a draft")
    }

    func testPassageChooserRefusesConfirmationAfterTheFileChanges() async throws {
        let f = try await fixture()
        f.reader.requestAddDiscussion()
        let offered = await poll { f.reader.discussionPassagePicker != nil }
        XCTAssertTrue(offered)
        guard let picker = f.reader.discussionPassagePicker else { return }
        let unit = try XCTUnwrap(picker.projection.units.first { $0.text == "Café bold passage." })
        let replacement = Data(try MarkdownSource.decode(f.original).replacingOccurrences(of: "Before.", with: "Before updated externally.").utf8)
        try replacement.write(to: f.file, options: .atomic)
        await f.reader.refresh(); await f.reader.waitForRendering()
        f.reader.confirmDiscussionPassage(unit.id)
        XCTAssertNil(f.reader.discussions.selection)
        XCTAssertTrue(f.reader.discussions.drafts.isEmpty)
        XCTAssertNotNil(f.reader.discussionError)
        XCTAssertEqual(try Data(contentsOf: f.file), replacement)
        f.reader.cancelDiscussionPassage()
        XCTAssertNil(f.reader.discussionPassagePicker)
    }

    private enum FixtureFailure: Error { case documentDidNotLoad }
    private struct Fixture {
        let reader: MobileReaderState
        let file: URL
        let original: Data
        let window: UIWindow
        let host: UIHostingController<MobileDocumentWorkspace>
        let web: WKWebView
    }
    private func fixture(withThread: Bool = false) async throws -> Fixture {
        var source = "# Plan\n\nBefore.\n\nCafe\u{301} **bold** passage.\n\nAfter.\n"
        if withThread {
            let thread = DiscussionThread(id: "t-mobile", state: .open,
                target: .init(type: "TextQuoteSelector", exact: "Café bold passage.", prefix: "Before.", suffix: "After.", section: "Plan"),
                messages: [.init(id: "m-mobile", author: "Reviewer", created: "2026-10-23T10:00:00Z", body: "A portable note.", inReplyTo: nil)],
                resolvedBy: nil, resolved: nil, attachmentHistory: [])
            let parsed = try DiscussionCodec.parse(source)
            source = try MarkdownSource.decode(MarkdownSourceEdits.apply(DiscussionEdits.splices(for: .newThread(thread), in: parsed),
                to: Data(source.utf8), expectedSource: source))
        }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".md")
        let original = Data(source.utf8); try original.write(to: file)
        let reader = MobileReaderState(defaults: UserDefaults(suiteName: "MobileDiscussionFixture-\(UUID().uuidString)")!)
        await reader.open(url: file); await reader.waitForRendering()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let host = UIHostingController(rootView: MobileDocumentWorkspace(reader: reader, openFolder: {}, closeFile: {}))
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 780)
        window.rootViewController = host; window.makeKeyAndVisible(); host.loadViewIfNeeded(); host.view.layoutIfNeeded()
        addTeardownBlock { @MainActor in
            reader.discussions.discardDrafts(); await reader.close()
            window.isHidden = true; window.rootViewController = nil
            try? FileManager.default.removeItem(at: file)
        }
        let mounted = await poll { self.webView(in: host.view)?.estimatedProgress == 1 && self.webView(in: host.view)?.isLoading == false }
        XCTAssertTrue(mounted, "Wait for a committed navigation before querying WebKit")
        guard mounted else { throw FixtureFailure.documentDidNotLoad }
        let web = try XCTUnwrap(webView(in: host.view))
        let ready = await pollAsync { try await web.evaluateJavaScript("document.querySelector('main')?.textContent.normalize('NFC').includes('Café bold passage.')===true") as? Bool == true }
        XCTAssertTrue(ready, "The actual formatted fixture must be loaded before exercising discussion actions")
        guard ready else { throw FixtureFailure.documentDidNotLoad }
        return .init(reader: reader, file: file, original: original, window: window, host: host, web: web)
    }
    private func poll(_ predicate: () -> Bool) async -> Bool {
        for _ in 0..<500 { if predicate() { return true }; try? await Task.sleep(for: .milliseconds(20)) }
        return false
    }
    private func pollAsync(_ predicate: () async throws -> Bool) async -> Bool {
        for _ in 0..<500 { if (try? await predicate()) == true { return true }; try? await Task.sleep(for: .milliseconds(20)) }
        return false
    }
    private func webView(in view: UIView) -> WKWebView? {
        if let web = view as? WKWebView { return web }
        return view.subviews.lazy.compactMap { self.webView(in: $0) }.first
    }
    private func editor(in view: UIView) -> UITextView? {
        if view is WKWebView { return nil }
        if let text = view as? UITextView, text.isEditable { return text }
        return view.subviews.lazy.compactMap { self.editor(in: $0) }.first
    }
}
