import SwiftUI
import LinkPresentation
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
        f.reader.confirmDiscussionPassage(unit.id, pickerID: picker.id)
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
        f.reader.confirmDiscussionPassage(unit.id, pickerID: picker.id)
        XCTAssertNil(f.reader.discussions.selection)
        XCTAssertTrue(f.reader.discussions.drafts.isEmpty)
        XCTAssertNotNil(f.reader.discussionError)
        XCTAssertEqual(try Data(contentsOf: f.file), replacement)
        f.reader.cancelDiscussionPassage(pickerID: picker.id)
        XCTAssertNil(f.reader.discussionPassagePicker)
    }

    func testOldPassageConfirmationCannotStartADraftInAnotherDocument() async throws {
        try await checkOldPickerAction(confirm: true)
    }

    func testOldPassageCancellationCannotDismissAnotherDocumentsPicker() async throws {
        try await checkOldPickerAction(confirm: false)
    }

    private func checkOldPickerAction(confirm: Bool) async throws {
        let f = try await fixture()
        f.reader.requestAddDiscussion()
        let offered = await poll { f.reader.discussionPassagePicker != nil }
        XCTAssertTrue(offered)
        let old = try XCTUnwrap(f.reader.discussionPassagePicker)
        let oldUnit = try XCTUnwrap(old.projection.units.first { $0.text == "Café bold passage." })
        // Capture exactly the request identity held by the old native sheet.
        let oldAction = {
            if confirm { f.reader.confirmDiscussionPassage(oldUnit.id, pickerID: old.id) }
            else { f.reader.cancelDiscussionPassage(pickerID: old.id) }
        }
        f.reader.cancelDiscussionPassage(pickerID: old.id)
        let dismissed = await poll { f.host.presentedViewController == nil }
        XCTAssertTrue(dismissed, "The original native picker must finish dismissal before replacing the file")
        guard dismissed else { return }
        let second = f.file.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".md")
        let data = Data("# Other\n\nDifferent nearby text.\n\nAn unrelated new passage.\n\nAfter.\n".utf8)
        try data.write(to: second)
        defer { try? FileManager.default.removeItem(at: second) }
        await f.reader.open(url: second); await f.reader.waitForRendering()
        let loaded = await pollAsync {
            try await f.web.evaluateJavaScript("document.querySelector('main')?.textContent.includes('An unrelated new passage.')===true") as? Bool == true
        }
        XCTAssertTrue(loaded)
        f.reader.requestAddDiscussion()
        let currentOffered = await poll { f.reader.discussionPassagePicker != nil }
        XCTAssertTrue(currentOffered)
        let current = try XCTUnwrap(f.reader.discussionPassagePicker)
        let currentUnit = try XCTUnwrap(current.projection.units.first { $0.text == "An unrelated new passage." })
        XCTAssertEqual(oldUnit.id, currentUnit.id, "The case must reuse semantic unit IDs across two distinct documents")
        oldAction()
        XCTAssertEqual(f.reader.discussionPassagePicker?.id, current.id, "A delayed action from another sheet must leave the current picker open")
        XCTAssertNil(f.reader.discussions.selection)
        XCTAssertTrue(f.reader.discussions.drafts.isEmpty, "An old native action must never select text in a new file")
        XCTAssertEqual(try Data(contentsOf: second), data)
        XCTAssertEqual(try Data(contentsOf: f.file), f.original)
        if f.reader.discussionPassagePicker?.id == current.id {
            f.reader.confirmDiscussionPassage(currentUnit.id, pickerID: current.id)
            let key = try XCTUnwrap(f.reader.discussions.selection)
            XCTAssertEqual(f.reader.discussions.drafts[key]?.target?.exact, "An unrelated new passage.")
        }
        f.reader.discussions.discardDrafts(); await f.reader.close()
    }

    func testDiscardedComposersLateEditCannotChangeAnotherDocumentsReply() async throws {
        let f = try await fixture(withThread: true)
        f.reader.openDiscussion("t-mobile")
        f.reader.discussions.setDraft("Original document draft.", for: .thread("t-mobile"))
        let mounted = await poll { self.editor(in: f.host.view)?.text == "Original document draft." }
        XCTAssertTrue(mounted)
        let oldEditor = try XCTUnwrap(self.editor(in: f.host.view))
        let oldDelegate = try XCTUnwrap(oldEditor.delegate)
        let second = f.file.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".md")
        try f.original.write(to: second)
        defer { try? FileManager.default.removeItem(at: second) }
        await f.reader.open(url: second)
        XCTAssertTrue(f.reader.showDraftDiscardConfirmation)
        await f.reader.confirmDiscardDrafts(); await f.reader.waitForRendering()
        XCTAssertEqual(f.reader.fileURL, second)
        let popped = await poll { self.editor(in: f.host.view) == nil }
        XCTAssertTrue(popped, "Finish the old native destination before opening another file's same-ID thread")
        guard popped else { return }
        f.reader.openDiscussion("t-mobile")
        f.reader.discussions.setDraft("Only the new document reply.", for: .thread("t-mobile"))
        let remounted = await poll { self.editor(in: f.host.view)?.text == "Only the new document reply." }
        XCTAssertTrue(remounted)
        let newEditor = try XCTUnwrap(self.editor(in: f.host.view))
        XCTAssertFalse(oldEditor === newEditor)
        guard oldEditor !== newEditor else { return }
        oldEditor.text = "Delayed text from the discarded document."
        oldDelegate.textViewDidChange?(oldEditor)
        XCTAssertEqual(f.reader.discussions.drafts[.thread("t-mobile")]?.body, "Only the new document reply.", "A queued callback still holds the old editor's binding, not permission to alter the new file's draft")
        f.reader.discussions.displayName = "Test Author"
        f.reader.postDiscussion()
        let saved = await poll { !f.reader.fileSaving && !f.reader.isRendering && f.reader.rendered?.discussions?.threads.first?.messages.count == 2 }
        XCTAssertTrue(saved)
        XCTAssertEqual(try DiscussionCodec.parse(MarkdownSource.read(second)).threads.first?.messages.last?.body, "Only the new document reply.")
        XCTAssertEqual(try Data(contentsOf: f.file), f.original)
        f.reader.discussions.discardDrafts(); await f.reader.close()
    }

    func testResolveOffersDraftChoicesAndReopenPreservesTheConversation() async throws {
        let f = try await fixture(withThread: true)
        f.reader.openDiscussion("t-mobile")
        f.reader.discussions.displayName = "Test Author"
        f.reader.discussions.setDraft("Post this reply before resolving.", for: .thread("t-mobile"))
        f.reader.requestResolveDiscussion("t-mobile")
        XCTAssertNotNil(f.reader.discussionDecision, "Resolve must ask what to do with the unposted reply")
        guard let first = f.reader.discussionDecision else { return }
        XCTAssertEqual(try Data(contentsOf: f.file), f.original)
        f.reader.confirmDiscussionResolution(first.id, choice: .keepOpen)
        XCTAssertNil(f.reader.discussionDecision)
        XCTAssertEqual(f.reader.discussions.drafts[.thread("t-mobile")]?.body, "Post this reply before resolving.")
        f.reader.requestResolveDiscussion("t-mobile")
        let decision = try XCTUnwrap(f.reader.discussionDecision)
        f.reader.confirmDiscussionResolution(decision.id, choice: .postDraft)
        let resolved = await poll { !f.reader.fileSaving && !f.reader.isRendering && f.reader.rendered?.discussions?.threads.first?.state == .resolved }
        XCTAssertTrue(resolved)
        let saved = try XCTUnwrap(try DiscussionCodec.parse(MarkdownSource.read(f.file)).threads.first)
        XCTAssertEqual(saved.messages.map(\.body), ["A portable note.", "Post this reply before resolving."])
        XCTAssertEqual(saved.resolvedBy, "Test Author")
        XCTAssertNil(f.reader.discussionDecision)
        XCTAssertFalse(f.reader.discussions.hasUnpostedDrafts)
        f.reader.reopenDiscussion("t-mobile")
        let reopened = await poll { !f.reader.fileSaving && !f.reader.isRendering && f.reader.rendered?.discussions?.threads.first?.state == .open }
        XCTAssertTrue(reopened)
        XCTAssertEqual(try DiscussionCodec.parse(MarkdownSource.read(f.file)).threads.first?.messages, saved.messages)
    }

    func testResolvedReplyConfirmationRejectsNewTypingAndOldDecisionCallbacks() async throws {
        let f = try await fixture(withThread: true)
        f.reader.openDiscussion("t-mobile"); f.reader.discussions.displayName = "Test Author"
        f.reader.resolveDiscussion("t-mobile", choice: .discardDraft)
        let resolved = await poll { !f.reader.fileSaving && !f.reader.isRendering && f.reader.rendered?.discussions?.threads.first?.state == .resolved }
        XCTAssertTrue(resolved)
        let before = try Data(contentsOf: f.file)
        f.reader.discussions.setDraft("First version of the reply.", for: .thread("t-mobile"))
        f.reader.postDiscussion()
        XCTAssertNotNil(f.reader.discussionDecision, "Posting to a resolved thread needs explicit reopening confirmation")
        guard let first = f.reader.discussionDecision else { return }
        f.reader.discussions.setDraft("New typing must be reviewed first.", for: .thread("t-mobile"))
        f.reader.confirmDiscussionReopenReply(first.id)
        XCTAssertEqual(try Data(contentsOf: f.file), before)
        XCTAssertNotNil(f.reader.discussionError)
        f.reader.cancelDiscussionDecision(first.id)
        f.reader.postDiscussion()
        let current = try XCTUnwrap(f.reader.discussionDecision)
        XCTAssertNotEqual(current.id, first.id)
        f.reader.confirmDiscussionReopenReply(first.id)
        f.reader.cancelDiscussionDecision(first.id)
        XCTAssertEqual(f.reader.discussionDecision?.id, current.id)
        XCTAssertEqual(try Data(contentsOf: f.file), before)
        f.reader.confirmDiscussionReopenReply(current.id)
        let saved = await poll { !f.reader.fileSaving && !f.reader.isRendering && f.reader.rendered?.discussions?.threads.first?.messages.count == 2 }
        XCTAssertTrue(saved)
        let thread = try XCTUnwrap(try DiscussionCodec.parse(MarkdownSource.read(f.file)).threads.first)
        XCTAssertEqual(thread.state, .open)
        XCTAssertEqual(thread.messages.last?.body, "New typing must be reviewed first.")
        XCTAssertNil(f.reader.discussionDecision)
        XCTAssertFalse(f.reader.discussions.hasUnpostedDrafts)
    }

    func testResolveConfirmationRejectsAnIdenticalExternalReplacement() async throws {
        let f = try await fixture(withThread: true)
        f.reader.openDiscussion("t-mobile"); f.reader.discussions.displayName = "Test Author"
        f.reader.discussions.setDraft("Keep this unposted reply.", for: .thread("t-mobile"))
        f.reader.requestResolveDiscussion("t-mobile")
        XCTAssertNotNil(f.reader.discussionDecision)
        guard let decision = f.reader.discussionDecision else { return }
        try f.original.write(to: f.file, options: .atomic)
        await f.reader.refresh(); await f.reader.waitForRendering()
        f.reader.confirmDiscussionResolution(decision.id, choice: .discardDraft)
        XCTAssertEqual(try Data(contentsOf: f.file), f.original)
        XCTAssertEqual(f.reader.discussions.drafts[.thread("t-mobile")]?.body, "Keep this unposted reply.")
        XCTAssertEqual(f.reader.rendered?.discussions?.threads.first?.state, .open)
        XCTAssertNotNil(f.reader.discussionError)
    }

    func testActualSelectionReattachmentRequiresConfirmationAndPreservesDraftAndHistory() async throws {
        let f = try await fixture(withThread: true)
        f.reader.openDiscussion("t-mobile"); f.reader.discussions.displayName = "Test Author"
        f.reader.discussions.setDraft("Keep my unsent reply.", for: .thread("t-mobile"))
        _ = try await f.web.callAsyncJavaScript("""
        const paragraph=Array.from(document.querySelectorAll('main p')).find(p=>p.textContent==='Before.');
        const range=document.createRange();range.selectNodeContents(paragraph);
        getSelection().removeAllRanges();getSelection().addRange(range);return true;
        """, arguments: [:], in: nil, contentWorld: .defaultClient)
        f.reader.requestReattachDiscussion("t-mobile")
        let offered = await poll { f.reader.discussionDecision != nil }
        XCTAssertTrue(offered, "Reattachment needs an old/new quote comparison before writing")
        guard let decision = f.reader.discussionDecision else { return }
        if case let .reattach(id, old, selected) = decision.kind {
            XCTAssertEqual(id, "t-mobile"); XCTAssertEqual(old.exact, "Café bold passage.")
            XCTAssertEqual(selected.target.exact, "Before.")
        } else { XCTFail("Expected reattachment comparison") }
        XCTAssertEqual(try Data(contentsOf: f.file), f.original)
        f.reader.confirmDiscussionReattachment(decision.id)
        let saved = await poll { !f.reader.fileSaving && !f.reader.isRendering && f.reader.rendered?.discussions?.threads.first?.target.exact == "Before." }
        XCTAssertTrue(saved)
        let thread = try XCTUnwrap(try DiscussionCodec.parse(MarkdownSource.read(f.file)).threads.first)
        XCTAssertEqual(thread.messages.map(\.body), ["A portable note."])
        XCTAssertEqual(thread.attachmentHistory.first?.target.exact, "Café bold passage.")
        XCTAssertEqual(thread.attachmentHistory.first?.author, "Test Author")
        XCTAssertEqual(f.reader.discussions.drafts[.thread("t-mobile")]?.body, "Keep my unsent reply.")
        XCTAssertNil(f.reader.discussionDecision)
        f.reader.undoDiscussion()
        _ = await poll { !f.reader.fileSaving && !f.reader.isRendering }
        XCTAssertEqual(try Data(contentsOf: f.file), f.original)
        XCTAssertEqual(f.reader.discussions.drafts[.thread("t-mobile")]?.body, "Keep my unsent reply.")
    }

    func testReattachmentWithoutSelectionUsesTheNativePassagePicker() async throws {
        let f = try await fixture(withThread: true)
        f.reader.openDiscussion("t-mobile"); f.reader.discussions.displayName = "Test Author"
        _ = try await f.web.evaluateJavaScript("getSelection().removeAllRanges();true")
        f.reader.requestReattachDiscussion("t-mobile")
        let offered = await poll { f.reader.discussionPassagePicker != nil }
        XCTAssertTrue(offered, "Reattach must offer accessible semantic passages when nothing is selected")
        guard let picker = f.reader.discussionPassagePicker else { return }
        let unit = try XCTUnwrap(picker.projection.units.first { $0.text == "Before." })
        f.reader.confirmDiscussionPassage(unit.id, pickerID: picker.id)
        let decision = try XCTUnwrap(f.reader.discussionDecision)
        if case let .reattach(_, old, selected) = decision.kind {
            XCTAssertEqual(old.exact, "Café bold passage."); XCTAssertEqual(selected.target.exact, "Before.")
        } else { XCTFail("Choosing a replacement must compare the quotes, not start a new discussion") }
        XCTAssertTrue(f.reader.discussions.drafts.isEmpty)
        XCTAssertEqual(try Data(contentsOf: f.file), f.original)
        f.reader.cancelDiscussionDecision(decision.id)
        XCTAssertNil(f.reader.discussionDecision)
        XCTAssertEqual(try Data(contentsOf: f.file), f.original)
    }

    func testReattachmentRejectsStaleSourceAndOldDecisionsButKeepsNewTyping() async throws {
        let f = try await fixture(withThread: true)
        f.reader.openDiscussion("t-mobile"); f.reader.discussions.displayName = "Test Author"
        f.reader.discussions.setDraft("My original draft.", for: .thread("t-mobile"))
        _ = try await f.web.evaluateJavaScript("getSelection().removeAllRanges();true")
        f.reader.requestReattachDiscussion("t-mobile")
        let offered = await poll { f.reader.discussionPassagePicker != nil }
        XCTAssertTrue(offered)
        guard let picker = f.reader.discussionPassagePicker else { return }
        let unit = try XCTUnwrap(picker.projection.units.first { $0.text == "Before." })
        f.reader.confirmDiscussionPassage(unit.id, pickerID: picker.id)
        let old = try XCTUnwrap(f.reader.discussionDecision)
        try f.original.write(to: f.file, options: .atomic)
        await f.reader.refresh(); await f.reader.waitForRendering()
        f.reader.confirmDiscussionReattachment(old.id)
        XCTAssertEqual(try Data(contentsOf: f.file), f.original)
        XCTAssertNotNil(f.reader.discussionError)
        f.reader.cancelDiscussionDecision(old.id)
        f.reader.requestReattachDiscussion("t-mobile")
        let currentOffered = await poll { f.reader.discussionPassagePicker != nil }
        XCTAssertTrue(currentOffered)
        let currentPicker = try XCTUnwrap(f.reader.discussionPassagePicker)
        let currentUnit = try XCTUnwrap(currentPicker.projection.units.first { $0.text == "Before." })
        f.reader.confirmDiscussionPassage(currentUnit.id, pickerID: currentPicker.id)
        let current = try XCTUnwrap(f.reader.discussionDecision)
        f.reader.confirmDiscussionReattachment(old.id); f.reader.cancelDiscussionDecision(old.id)
        XCTAssertEqual(f.reader.discussionDecision?.id, current.id)
        f.reader.discussions.setDraft("New typing stays with my reply.", for: .thread("t-mobile"))
        f.reader.confirmDiscussionReattachment(current.id)
        let saved = await poll { !f.reader.fileSaving && !f.reader.isRendering && f.reader.rendered?.discussions?.threads.first?.target.exact == "Before." }
        XCTAssertTrue(saved)
        XCTAssertEqual(f.reader.discussions.drafts[.thread("t-mobile")]?.body, "New typing stays with my reply.")
        XCTAssertEqual(try DiscussionCodec.parse(MarkdownSource.read(f.file)).threads.first?.attachmentHistory.count, 1)
    }

    func testNativeCopyPickerShowsAReadOnlyPreviewBeforeExplicitImport() async throws {
        let f = try await fixture(withThread: true)
        f.reader.openDiscussion("t-mobile")
        f.reader.discussions.setDraft("Keep my local reply.", for: .thread("t-mobile"))
        let other = f.file.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".md")
        let incoming = try incomingCopy(f.original, conflict: false); try incoming.write(to: other)
        defer { try? FileManager.default.removeItem(at: other) }
        f.reader.requestReviewAnotherCopy()
        XCTAssertNotNil(f.reader.discussionCopyRequest, "Review Another Copy must start a version-fenced native file choice")
        guard f.reader.discussionCopyRequest != nil else { return }
        let mounted = await poll { self.documentPicker(in: f.host) != nil }
        XCTAssertTrue(mounted)
        let picker = try XCTUnwrap(documentPicker(in: f.host))
        XCTAssertFalse(picker.allowsMultipleSelection)
        picker.delegate?.documentPicker?(picker, didPickDocumentsAt: [other])
        let reviewed = await poll { f.reader.discussionImportReview != nil }
        XCTAssertTrue(reviewed)
        let review = try XCTUnwrap(f.reader.discussionImportReview)
        XCTAssertEqual(review.preview.items.first?.kind, .replies)
        XCTAssertEqual(f.reader.fileURL, f.file)
        XCTAssertEqual(try Data(contentsOf: f.file), f.original)
        XCTAssertEqual(try Data(contentsOf: other), incoming)
        f.reader.confirmDiscussionImport(review.id)
        let saved = await poll { !f.reader.fileSaving && !f.reader.isRendering && f.reader.rendered?.discussions?.threads.first?.messages.count == 2 }
        XCTAssertTrue(saved)
        XCTAssertTrue(f.reader.source.hasPrefix("# Plan\n"))
        XCTAssertFalse(f.reader.source.contains("# Other copy prose"))
        XCTAssertEqual(try Data(contentsOf: other), incoming)
        XCTAssertEqual(f.reader.discussions.drafts[.thread("t-mobile")]?.body, "Keep my local reply.")
        XCTAssertNil(f.reader.discussionImportReview)
        f.reader.undoDiscussion(); _ = await poll { !f.reader.fileSaving && !f.reader.isRendering }
        XCTAssertEqual(try Data(contentsOf: f.file), f.original)
    }

    func testOldFilePickerSelectionCannotReviewIntoAnotherDocument() async throws {
        let f = try await fixture(withThread: true)
        let other = f.file.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".md")
        try incomingCopy(f.original, conflict: false).write(to: other)
        defer { try? FileManager.default.removeItem(at: other) }
        f.reader.requestReviewAnotherCopy()
        XCTAssertNotNil(f.reader.discussionCopyRequest)
        guard let request = f.reader.discussionCopyRequest else { return }
        let second = f.file.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".md")
        try f.original.write(to: second); defer { try? FileManager.default.removeItem(at: second) }
        await f.reader.open(url: second); await f.reader.waitForRendering()
        await f.reader.completeDiscussionCopyPicker(other, request: request)
        XCTAssertEqual(f.reader.fileURL, second)
        XCTAssertNil(f.reader.discussionImportPreview)
        XCTAssertNil(f.reader.discussionImportReview)
        XCTAssertEqual(try Data(contentsOf: second), f.original)
        f.reader.discussions.discardDrafts(); await f.reader.close()
    }

    func testConflictingCopyRequiresAChoiceAndCanRemainSeparate() async throws {
        let f = try await fixture(withThread: true)
        let other = f.file.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".md")
        let incoming = try incomingCopy(f.original, conflict: true); try incoming.write(to: other)
        defer { try? FileManager.default.removeItem(at: other) }
        f.reader.requestReviewAnotherCopy()
        XCTAssertNotNil(f.reader.discussionCopyRequest)
        guard f.reader.discussionCopyRequest != nil else { return }
        let mounted = await poll { self.documentPicker(in: f.host) != nil }; XCTAssertTrue(mounted)
        let picker = try XCTUnwrap(documentPicker(in: f.host))
        picker.delegate?.documentPicker?(picker, didPickDocumentsAt: [other])
        let reviewed = await poll { f.reader.discussionImportReview != nil }; XCTAssertTrue(reviewed)
        let review = try XCTUnwrap(f.reader.discussionImportReview)
        XCTAssertEqual(review.preview.items.first?.kind, .conflict)
        XCTAssertEqual(review.preview.current.threads.first?.messages.first?.body, "A portable note.")
        XCTAssertEqual(review.preview.incoming.threads.first?.messages.first?.body, "Incoming conflicting comment.")
        f.reader.confirmDiscussionImport(review.id)
        XCTAssertEqual(try Data(contentsOf: f.file), f.original)
        XCTAssertNotNil(f.reader.discussionError)
        f.reader.confirmDiscussionImport(review.id, choices: ["t-mobile": .keepSeparate])
        let saved = await poll { !f.reader.fileSaving && !f.reader.isRendering && f.reader.rendered?.discussions?.threads.count == 2 }; XCTAssertTrue(saved)
        let threads = try DiscussionCodec.parse(MarkdownSource.read(f.file)).threads
        XCTAssertEqual(Set(threads.flatMap(\.messages).map(\.body)), ["A portable note.", "Incoming conflicting comment."])
        XCTAssertEqual(Set(threads.flatMap(\.messages).map(\.id)).count, 2)
        XCTAssertEqual(try Data(contentsOf: other), incoming)
    }

    func testImportReviewRejectsOldCallbacksAndReplacedCurrentFile() async throws {
        let f = try await fixture(withThread: true)
        let other = f.file.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".md")
        try incomingCopy(f.original, conflict: false).write(to: other)
        defer { try? FileManager.default.removeItem(at: other) }
        f.reader.requestReviewAnotherCopy()
        XCTAssertNotNil(f.reader.discussionCopyRequest)
        guard let request = f.reader.discussionCopyRequest else { return }
        await f.reader.completeDiscussionCopyPicker(other, request: request)
        let old = try XCTUnwrap(f.reader.discussionImportReview)
        f.reader.cancelDiscussionImportReview(old.id)
        _ = await poll { f.host.presentedViewController == nil }
        f.reader.requestReviewAnotherCopy()
        let currentRequest = try XCTUnwrap(f.reader.discussionCopyRequest)
        await f.reader.completeDiscussionCopyPicker(other, request: currentRequest)
        let current = try XCTUnwrap(f.reader.discussionImportReview)
        f.reader.cancelDiscussionImportReview(old.id); f.reader.confirmDiscussionImport(old.id)
        XCTAssertEqual(f.reader.discussionImportReview?.id, current.id)
        try f.original.write(to: f.file, options: .atomic)
        await f.reader.refresh(); await f.reader.waitForRendering()
        f.reader.confirmDiscussionImport(current.id)
        XCTAssertEqual(try Data(contentsOf: f.file), f.original)
        XCTAssertNotNil(f.reader.discussionError)
    }

    func testSnapshotCopyMovesLatestDraftOnlyWhenExplicitlyOpened() async throws {
        let f = try await fixture()
        var previewURL = URLComponents(string: "margined://preview")!
        previewURL.queryItems = [.init(name: "text", value: try MarkdownSource.decode(f.original)), .init(name: "title", value: "Snapshot")]
        await f.reader.openPreview(url: try XCTUnwrap(previewURL.url))
        await f.reader.waitForRendering()
        let projection = try XCTUnwrap(f.reader.rendered?.discussionText)
        let unit = try XCTUnwrap(projection.units.first { $0.text.contains("bold passage") })
        let selection = try XCTUnwrap(projection.selection(unit.range, renderID: "copy-test"))
        let key = try f.reader.discussions.beginDraft(selection, in: projection)
        f.reader.discussions.displayName = "Copy Author"
        f.reader.discussions.setDraft("Unposted before saving.", for: key)
        f.reader.requestDiscussionExport(.savedCopy)
        XCTAssertNotNil(f.reader.discussionExport, "A read-only snapshot must offer a native new-copy flow")
        guard let export = f.reader.discussionExport else { return }
        let target = f.file.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".md")
        defer { try? FileManager.default.removeItem(at: target) }
        f.reader.createDiscussionExport(export.id, at: target)
        XCTAssertTrue(f.reader.fileSaving, "Save must be accepted synchronously before close or navigation")
        await f.reader.waitForSaving()
        let result = try XCTUnwrap(f.reader.discussionExportResult)
        XCTAssertEqual(try Data(contentsOf: target), f.original)
        XCTAssertNil(f.reader.fileURL)
        XCTAssertEqual(f.reader.discussions.drafts[key]?.body, "Unposted before saving.")
        f.reader.discussions.setDraft("A newer reply before moving.", for: key)
        let copy = try XCTUnwrap(f.reader.takeDiscussionCopyToOpen(result.id))
        defer { Task { @MainActor in copy.discussions.discardDrafts(); await copy.close() } }
        XCTAssertEqual(copy.fileURL, target)
        XCTAssertEqual(copy.discussions.drafts[key]?.body, "A newer reply before moving.")
        XCTAssertFalse(f.reader.discussions.hasUnpostedDrafts)
        XCTAssertEqual(copy.discussions.draftAnchor(for: key)?.status, .attached)
        copy.postDiscussion(); await copy.waitForSaving(); await copy.waitForRendering()
        XCTAssertEqual(try DiscussionCodec.parse(MarkdownSource.read(target)).threads.first?.messages.first?.body, "A newer reply before moving.")
        XCTAssertEqual(try Data(contentsOf: f.file), f.original)
    }

    func testNativeExportModesPreserveSourceEncodingAndDrafts() async throws {
        let f = try await fixture(withThread: true)
        let encoded = Data([0xff, 0xfe]) + (try MarkdownSource.decode(f.original)).data(using: .utf16LittleEndian)!
        try encoded.write(to: f.file, options: .atomic)
        await f.reader.refresh(); await f.reader.waitForRendering()
        f.reader.discussions.setDraft("Never export this unsaved reply.", for: .thread("t-mobile"))
        for kind in [MobileDiscussionExport.Kind.markdown, .clean, .conversation] {
            f.reader.requestDiscussionExport(kind)
            XCTAssertNotNil(f.reader.discussionExport, "Each labeled export must prepare its real document payload")
            guard let export = f.reader.discussionExport else { return }
            let target = f.file.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".md")
            defer { try? FileManager.default.removeItem(at: target) }
            if kind == .clean { XCTAssertEqual(export.removedBlocks, 1) }
            f.reader.createDiscussionExport(export.id, at: target); await f.reader.waitForSaving()
            let written = try Data(contentsOf: target), text = try MarkdownSource.decode(written)
            switch kind {
            case .markdown: XCTAssertEqual(written, encoded)
            case .clean:
                XCTAssertTrue(written.starts(with: [0xff, 0xfe]))
                XCTAssertTrue(try DiscussionCodec.parse(text).blocks.isEmpty)
                XCTAssertTrue(text.contains("Cafe\u{301} **bold** passage."))
            case .conversation:
                XCTAssertTrue(text.contains("A portable note."))
                XCTAssertTrue(text.contains("Reviewer"))
                XCTAssertFalse(text.contains("<!-- margined:thread"))
            case .savedCopy: XCTFail("This case tests exported files, not reader handoff")
            }
            XCTAssertFalse(text.contains("Never export this unsaved reply."))
            XCTAssertEqual(try Data(contentsOf: f.file), encoded)
            XCTAssertEqual(f.reader.discussions.drafts[.thread("t-mobile")]?.body, "Never export this unsaved reply.")
            f.reader.cancelDiscussionExport(export.id)
        }
    }

    func testExportNeverOverwritesAnExistingDestination() async throws {
        let f = try await fixture(withThread: true)
        f.reader.discussions.setDraft("Keep my reply after failure.", for: .thread("t-mobile"))
        f.reader.requestDiscussionExport(.savedCopy)
        XCTAssertNotNil(f.reader.discussionExport)
        guard let export = f.reader.discussionExport else { return }
        let target = f.file.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".md")
        let other = Data("A different existing file.\n".utf8); try other.write(to: target)
        defer { try? FileManager.default.removeItem(at: target) }
        f.reader.createDiscussionExport(export.id, at: target); await f.reader.waitForSaving()
        XCTAssertEqual(try Data(contentsOf: target), other)
        XCTAssertEqual(try Data(contentsOf: f.file), f.original)
        XCTAssertNotNil(f.reader.discussionError)
        XCTAssertNil(f.reader.discussionExportResult)
        XCTAssertEqual(f.reader.discussions.drafts[.thread("t-mobile")]?.body, "Keep my reply after failure.")
        XCTAssertEqual(f.reader.discussionExport?.id, export.id)
    }

    func testOldExportCallbackCannotSaveOrDismissAnotherDocument() async throws {
        let f = try await fixture(withThread: true)
        f.reader.requestDiscussionExport(.clean)
        XCTAssertNotNil(f.reader.discussionExport)
        guard let old = f.reader.discussionExport else { return }
        let second = f.file.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".md")
        let target = f.file.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".md")
        try f.original.write(to: second)
        defer { try? FileManager.default.removeItem(at: second); try? FileManager.default.removeItem(at: target) }
        await f.reader.open(url: second); await f.reader.waitForRendering()
        f.reader.requestDiscussionExport(.markdown)
        let current = try XCTUnwrap(f.reader.discussionExport)
        f.reader.cancelDiscussionExport(old.id)
        f.reader.createDiscussionExport(old.id, at: target); await f.reader.waitForSaving()
        XCTAssertEqual(f.reader.discussionExport?.id, current.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        XCTAssertEqual(try Data(contentsOf: second), f.original)
        f.reader.cancelDiscussionExport(current.id)
        f.reader.requestDiscussionExport(.clean)
        let review = try XCTUnwrap(f.reader.discussionExport)
        try f.original.write(to: second, options: .atomic)
        await f.reader.refresh(); await f.reader.waitForRendering()
        f.reader.createDiscussionExport(review.id, at: target); await f.reader.waitForSaving()
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        XCTAssertNotNil(f.reader.discussionError)
    }

    func testCloseDrainsAnAcceptedNewCopySave() async throws {
        let f = try await fixture(withThread: true)
        f.reader.requestDiscussionExport(.savedCopy)
        XCTAssertNotNil(f.reader.discussionExport)
        guard let export = f.reader.discussionExport else { return }
        let target = f.file.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".md")
        defer { try? FileManager.default.removeItem(at: target) }
        f.reader.createDiscussionExport(export.id, at: target)
        XCTAssertTrue(f.reader.fileSaving)
        await f.reader.close()
        XCTAssertEqual(try Data(contentsOf: target), f.original)
        XCTAssertEqual(try Data(contentsOf: f.file), f.original)
        XCTAssertFalse(f.reader.hasDocument)
        XCTAssertFalse(f.reader.fileSaving)
        XCTAssertNil(f.reader.discussionExportResult)
    }

    func testNativeMarkdownShareProvidesTheFrozenEncodedFileWithoutDrafts() async throws {
        let f = try await fixture(withThread: true)
        let encoded = Data([0xff, 0xfe]) + (try MarkdownSource.decode(f.original)).data(using: .utf16LittleEndian)!
        try encoded.write(to: f.file, options: .atomic)
        await f.reader.refresh(); await f.reader.waitForRendering()
        f.reader.discussions.setDraft("Private unposted reply.", for: .thread("t-mobile"))
        f.reader.requestMarkdownShare(); await f.reader.waitForSaving()
        XCTAssertNotNil(f.reader.discussionShare, "Share must stage a Markdown file without asking for an export folder")
        guard let share = f.reader.discussionShare else { return }
        let metadata = share.configuration.perItemMetadataProvider?(0, .linkPresentationMetadata) as? LPLinkMetadata
        XCTAssertNotNil(metadata, "The system share header must identify the Markdown file being shared")
        guard let metadata else { return }
        XCTAssertEqual(metadata.title, f.file.lastPathComponent)
        let presented = await poll { self.activityController(in: f.host) != nil }; XCTAssertTrue(presented)
        let activity = try XCTUnwrap(activityController(in: f.host))
        // The inherited responder configuration is independent of the input to
        // UIActivityViewController's initializer, including on plain UIKit controls.
        let provider = try XCTUnwrap(share.configuration.itemProvidersForActivityItemsConfiguration.first)
        XCTAssertTrue(provider.hasItemConformingToTypeIdentifier("net.daringfireball.markdown"))
        let newer = Data("# A newer original\n\nKeep this agent update.\n".utf8)
        try newer.write(to: f.file, options: .atomic)
        await f.reader.refresh(); await f.reader.waitForRendering()
        let bytes = try await sharedData(from: provider)
        XCTAssertEqual(bytes, encoded, "The real native activity provider must keep the version chosen for sharing")
        XCTAssertTrue(try MarkdownSource.decode(bytes).contains("A portable note."))
        XCTAssertFalse(try MarkdownSource.decode(bytes).contains("Private unposted reply."))
        XCTAssertEqual(try Data(contentsOf: f.file), newer)
        XCTAssertEqual(f.reader.discussions.drafts[.thread("t-mobile")]?.body, "Private unposted reply.")
        activity.completionWithItemsHandler?(nil, false, nil, nil)
        let finished = await poll { f.reader.discussionShare == nil }; XCTAssertTrue(finished)
        XCTAssertTrue(FileManager.default.fileExists(atPath: share.url.path), "An activity provider still holding the file must keep it readable")
    }

    func testSharedTemporaryFileLivesUntilTheLastProviderReleasesIt() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".md")
        let data = Data("# Share safely\n\nThe original stays unchanged.\n".utf8); try data.write(to: file)
        let reader = MobileReaderState(defaults: UserDefaults(suiteName: "MobileShare-\(UUID().uuidString)")!)
        addTeardownBlock { @MainActor in await reader.close(); try? FileManager.default.removeItem(at: file) }
        await reader.open(url: file); await reader.waitForRendering()
        reader.requestMarkdownShare(); await reader.waitForSaving()
        XCTAssertNotNil(reader.discussionShare)
        var share: MobileDiscussionShare? = reader.discussionShare
        guard share != nil else { return }
        let url = try XCTUnwrap(share?.url), id = try XCTUnwrap(share?.id)
        var provider = share?.configuration.itemProvidersForActivityItemsConfiguration.first
        reader.finishDiscussionShare(id); share = nil
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        let bytes = try await sharedData(from: XCTUnwrap(provider)); XCTAssertEqual(bytes, data)
        provider = nil
        let cleaned = await poll { !FileManager.default.fileExists(atPath: url.path) }; XCTAssertTrue(cleaned)
        XCTAssertEqual(try Data(contentsOf: file), data)
    }

    func testOldActivityCompletionCannotDismissTheNextDocumentsShare() async throws {
        let f = try await fixture(withThread: true)
        f.reader.requestMarkdownShare(); await f.reader.waitForSaving()
        XCTAssertNotNil(f.reader.discussionShare)
        guard let first = f.reader.discussionShare else { return }
        let mounted = await poll { self.activityController(in: f.host) != nil }; XCTAssertTrue(mounted)
        let activity = try XCTUnwrap(activityController(in: f.host))
        let completion = try XCTUnwrap(activity.completionWithItemsHandler)
        let second = f.file.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".md")
        try f.original.write(to: second); defer { try? FileManager.default.removeItem(at: second) }
        await f.reader.open(url: second); await f.reader.waitForRendering()
        let dismissed = await poll { f.host.presentedViewController == nil }; XCTAssertTrue(dismissed)
        f.reader.requestMarkdownShare(); await f.reader.waitForSaving()
        let current = try XCTUnwrap(f.reader.discussionShare)
        completion(nil, false, nil, nil)
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        f.reader.finishDiscussionShare(first.id)
        let stillCurrent = await poll { f.reader.discussionShare?.id == current.id }; XCTAssertTrue(stillCurrent)
        XCTAssertEqual(f.reader.discussionShare?.id, current.id)
        XCTAssertEqual(try Data(contentsOf: current.url), f.original)
        XCTAssertEqual(try Data(contentsOf: second), f.original)
        f.reader.finishDiscussionShare(current.id)
    }

    private func activityController(in controller: UIViewController) -> UIActivityViewController? {
        if let activity = controller as? UIActivityViewController { return activity }
        if let presented = controller.presentedViewController, let activity = activityController(in: presented) { return activity }
        return controller.children.lazy.compactMap { self.activityController(in: $0) }.first
    }
    private func sharedData(from provider: NSItemProvider) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadFileRepresentation(forTypeIdentifier: "net.daringfireball.markdown") { url, error in
                do {
                    if let error { throw error }
                    guard let url else { throw CocoaError(.fileReadNoSuchFile) }
                    continuation.resume(returning: try Data(contentsOf: url))
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    private func incomingCopy(_ data: Data, conflict: Bool) throws -> Data {
        let source = try MarkdownSource.decode(data).replacingOccurrences(of: "# Plan\n", with: "# Other copy prose\n")
        if conflict { return Data(source.replacingOccurrences(of: "A portable note.", with: "Incoming conflicting comment.").utf8) }
        let document = try DiscussionCodec.parse(source)
        let message = DiscussionMessage(id: "m-incoming", author: "Guest", created: "2026-10-24T10:00:00Z", body: "A reply from another copy.", inReplyTo: "m-mobile")
        return try MarkdownSourceEdits.apply(DiscussionEdits.splices(for: .reply(threadID: "t-mobile", message: message, reopenResolved: false), in: document), to: Data(source.utf8), expectedSource: source)
    }
    private func documentPicker(in controller: UIViewController) -> UIDocumentPickerViewController? {
        if let picker = controller as? UIDocumentPickerViewController { return picker }
        if let presented = controller.presentedViewController, let picker = documentPicker(in: presented) { return picker }
        return controller.children.lazy.compactMap { self.documentPicker(in: $0) }.first
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
