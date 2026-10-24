import AppKit
import SwiftUI
import WebKit
import XCTest
@testable import Margined

@MainActor final class DiscussionInteractionTests: XCTestCase {
    func testAddWithoutSelectionOffersNativePassagesAndCreatesOnlyAnUnpostedDraft() async throws {
        let f = try await makeFixture(); defer { clean(f) }
        let reader = f.reader, web = try XCTUnwrap(findWebView(f.controller.view))
        _ = try await web.evaluateJavaScript("window.passagePickerDocument=document;getSelection().removeAllRanges();true")
        reader.requestAddDiscussion()
        try await waitUntil { reader.discussionSelectionRequest == nil }
        let picker = try XCTUnwrap(reader.discussionPassagePicker)
        try await waitUntil { f.window.attachedSheet != nil }
        let unit = try XCTUnwrap(picker.projection.units.first { $0.text == "Café bold passage." })
        XCTAssertTrue(reader.discussions.drafts.isEmpty)
        reader.confirmDiscussionPassage(unit.id)
        try await waitUntil { f.window.attachedSheet == nil }
        let key = try XCTUnwrap(reader.discussions.selection)
        XCTAssertEqual(reader.discussions.drafts[key]?.target?.exact, "Café bold passage.")
        XCTAssertEqual(reader.discussions.drafts[key]?.body, "")
        XCTAssertTrue(reader.showDiscussions)
        XCTAssertNil(reader.discussionPassagePicker)
        XCTAssertEqual(try Data(contentsOf: f.file), f.data)
        let samePage = try await web.evaluateJavaScript("window.passagePickerDocument===document") as? Bool
        XCTAssertEqual(samePage, true)
    }

    func testCancellingPassageChoiceKeepsAnExistingReplyAndSource() async throws {
        let f = try await makeFixture(source: try discussionSource()); defer { clean(f) }
        let reader = f.reader
        reader.openDiscussion("t1"); reader.discussions.setDraft("Keep this reply.", for: .thread("t1"))
        reader.requestAddDiscussion(); reader.acceptNewDiscussionSelection(nil)
        _ = try XCTUnwrap(reader.discussionPassagePicker)
        try await waitUntil { f.window.attachedSheet != nil }
        reader.cancelDiscussionPassage()
        try await waitUntil { f.window.attachedSheet == nil }
        XCTAssertNil(reader.discussionPassagePicker)
        XCTAssertEqual(reader.discussions.selection, .thread("t1"))
        XCTAssertEqual(reader.discussions.drafts[.thread("t1")]?.body, "Keep this reply.")
        XCTAssertEqual(reader.discussions.drafts.count, 1)
        XCTAssertEqual(try Data(contentsOf: f.file), f.data)
    }

    func testPassageChooserRefusesItsOldSnapshotAfterExternalRefresh() async throws {
        let f = try await makeFixture(source: try discussionSource()); defer { clean(f) }
        let reader = f.reader
        reader.openDiscussion("t1"); reader.discussions.setDraft("Keep the unsent reply.", for: .thread("t1"))
        reader.requestAddDiscussion(); reader.acceptNewDiscussionSelection(nil)
        let picker = try XCTUnwrap(reader.discussionPassagePicker)
        let unit = try XCTUnwrap(picker.projection.units.first { $0.text == "Before." })
        let updated = f.data + Data("\nAn external addition.\n".utf8)
        try updated.write(to: f.file, options: .atomic); reader.reload()
        try await waitUntil { !reader.isRendering && reader.source.hasSuffix("An external addition.\n") }
        reader.confirmDiscussionPassage(unit.id)
        XCTAssertNotNil(reader.discussionError)
        XCTAssertEqual(reader.discussions.selection, .thread("t1"))
        XCTAssertEqual(reader.discussions.drafts[.thread("t1")]?.body, "Keep the unsent reply.")
        XCTAssertEqual(reader.discussions.drafts.count, 1)
        XCTAssertEqual(try Data(contentsOf: f.file), updated)
    }

    func testReattachWithoutSelectionOffersPassagesBeforeTheExistingComparison() async throws {
        let f = try await makeFixture(source: try discussionSource()); defer { clean(f) }
        let reader = f.reader
        reader.openDiscussion("t1"); reader.discussions.setDraft("Retain the reply.", for: .thread("t1"))
        reader.requestReattachDiscussion("t1"); reader.acceptNewDiscussionSelection(nil)
        let picker = try XCTUnwrap(reader.discussionPassagePicker)
        let unit = try XCTUnwrap(picker.projection.units.first { $0.text == "After." })
        reader.confirmDiscussionPassage(unit.id)
        XCTAssertEqual(reader.discussionReattachment?.originalTarget.exact, "Café bold passage.")
        XCTAssertEqual(reader.discussionReattachment?.selection.target.exact, "After.")
        XCTAssertEqual(reader.discussions.selection, .thread("t1"))
        XCTAssertEqual(reader.discussions.drafts[.thread("t1")]?.body, "Retain the reply.")
        XCTAssertEqual(try Data(contentsOf: f.file), f.data)
    }

    func testNextPreviousDiscussionWrapWithinTheFilterWithoutMovingProseOrDroppingDrafts() async throws {
        let source = try discussionSource().replacingOccurrences(of: "# Plan\n\n",
            with: "# Plan\n\n" + String(repeating: "Padding paragraph.\n\n", count: 30))
        let f = try await makeFixture(source: source); defer { clean(f) }
        let reader = f.reader, web = try XCTUnwrap(findWebView(f.controller.view))
        let canScroll = try await web.evaluateJavaScript("window.discussionNavigationDocument=document;document.documentElement.scrollHeight>innerHeight") as? Bool
        XCTAssertEqual(canScroll, true, "Offscreen passages must expose accidental Go to Passage behavior")
        reader.discussions.filter = .all; reader.openDiscussion("t1")
        reader.discussions.setDraft("A retained draft.", for: .thread("t1"))
        reader.showDiscussions = false
        let scroll = try await web.evaluateJavaScript("window.scrollY") as? Double
        reader.selectNextDiscussion()
        XCTAssertEqual(reader.discussions.selection, .thread("t2"))
        XCTAssertTrue(reader.showDiscussions)
        reader.selectNextDiscussion()
        XCTAssertEqual(reader.discussions.selection, .thread("t1"))
        reader.selectNextDiscussion(backwards: true)
        XCTAssertEqual(reader.discussions.selection, .thread("t2"))
        reader.discussions.filter = .open
        reader.selectNextDiscussion()
        XCTAssertEqual(reader.discussions.selection, .thread("t1"))
        reader.selectNextDiscussion(backwards: true)
        XCTAssertEqual(reader.discussions.selection, .thread("t1"))
        let config = WKSnapshotConfiguration(); config.afterScreenUpdates = true
        _ = try await web.takeSnapshot(configuration: config)
        let finalScroll = try await web.evaluateJavaScript("window.scrollY") as? Double
        let samePage = try await web.evaluateJavaScript("window.discussionNavigationDocument===document") as? Bool
        XCTAssertEqual(finalScroll, scroll)
        XCTAssertEqual(samePage, true)
        XCTAssertEqual(reader.discussions.drafts[.thread("t1")]?.body, "A retained draft.")
        XCTAssertEqual(try Data(contentsOf: f.file), f.data)
    }

    func testGoToPassageCanReturnToTheSameDiscussionAndRetainedReply() async throws {
        let f = try await makeFixture(source: try discussionSource()); defer { clean(f) }
        let reader = f.reader, web = try XCTUnwrap(findWebView(f.controller.view))
        _ = try await web.evaluateJavaScript("window.returnDiscussionDocument=document;true")
        reader.openDiscussion("t1"); reader.discussions.setDraft("Continue this reply.", for: .thread("t1"))
        reader.goToDiscussion("t1")
        XCTAssertEqual(reader.navigationReturnTarget, .discussion("t1"))
        reader.openDiscussion("t2"); reader.showDiscussions = false
        let generation = reader.returnFocusGeneration
        reader.returnToNavigation()
        XCTAssertTrue(reader.showDiscussions)
        XCTAssertEqual(reader.discussions.selection, .thread("t1"))
        XCTAssertGreaterThan(reader.returnFocusGeneration, generation)
        try await waitUntil { self.findEditor(f.controller.view)?.string == "Continue this reply." }
        XCTAssertTrue(findWebView(f.controller.view) === web)
        XCTAssertEqual(reader.discussions.drafts[.thread("t1")]?.body, "Continue this reply.")
        let samePage = try await web.evaluateJavaScript("window.returnDiscussionDocument===document") as? Bool
        XCTAssertEqual(samePage, true)
        XCTAssertEqual(try Data(contentsOf: f.file), f.data)
    }

    func testExternalResolveKeepsTheUnpostedReplyVisibleOutsideTheCurrentFilter() async throws {
        let f = try await makeFixture(source: try discussionSource()); defer { clean(f) }
        let reader = f.reader, web = try XCTUnwrap(findWebView(f.controller.view))
        reader.discussions.filter = .open; reader.openDiscussion("t1")
        reader.discussions.setDraft("Keep this visible after external resolution.", for: .thread("t1"))
        try await waitUntil { self.findEditor(f.controller.view)?.string == "Keep this visible after external resolution." }
        let parsed = try DiscussionCodec.parse(reader.source)
        let updated = try MarkdownSourceEdits.apply(DiscussionEdits.splices(for:
            .resolve(threadID: "t1", author: "Another", created: "2026-10-23T12:00:00Z"), in: parsed),
            to: f.data, expectedSource: reader.source)
        try updated.write(to: f.file, options: .atomic); reader.reload()
        try await waitUntil { !reader.isRendering && reader.rendered?.discussions?.threads.first?.state == .resolved }
        f.controller.view.layoutSubtreeIfNeeded()
        let config = WKSnapshotConfiguration(); config.afterScreenUpdates = true
        _ = try await web.takeSnapshot(configuration: config)
        XCTAssertEqual(reader.discussions.filter, .open)
        XCTAssertTrue(reader.filteredDiscussionThreads.isEmpty)
        XCTAssertEqual(reader.inspectorDiscussionThreads.map(\.id), ["t1"])
        XCTAssertEqual(reader.discussions.selection, .thread("t1"))
        XCTAssertEqual(findEditor(f.controller.view)?.string, "Keep this visible after external resolution.")
        XCTAssertTrue(findWebView(f.controller.view) === web)
        XCTAssertEqual(try Data(contentsOf: f.file), updated)
    }

    func testNativeDiscussionMenuCommandsHaveDistinctDiscoverableKeyboardBindings() throws {
        let previousMenu = NSApp.mainMenu, previousWindows = NSApp.windowsMenu, previousServices = NSApp.servicesMenu
        defer { NSApp.mainMenu = previousMenu; NSApp.windowsMenu = previousWindows; NSApp.servicesMenu = previousServices }
        let delegate = AppDelegate()
        delegate.applicationWillFinishLaunching(Notification(name: NSApplication.willFinishLaunchingNotification))
        let menu = try XCTUnwrap(NSApp.mainMenu)
        func items(_ menu: NSMenu) -> [NSMenuItem] {
            menu.items.flatMap { item in [item] + (item.submenu.map(items) ?? []) }
        }
        let all = items(menu)
        for action in ["addDiscussion:", "toggleDiscussions:", "nextDiscussion:", "previousDiscussion:", "goToDiscussion:"] {
            let item = try XCTUnwrap(all.first { $0.action == NSSelectorFromString(action) }, action)
            XCTAssertTrue(item.target === delegate)
            XCTAssertFalse(item.keyEquivalent.isEmpty)
        }
        var used: Set<String> = []
        for item in all where !item.keyEquivalent.isEmpty {
            let key = "\(item.keyEquivalentModifierMask.rawValue):\(item.keyEquivalent.lowercased())"
            XCTAssertTrue(used.insert(key).inserted, "Duplicate menu shortcut: \(item.title)")
        }
    }

    private func clean(_ f: Fixture) {
        f.reader.cancelDiscussionPassage()
        if let sheet = f.window.attachedSheet { f.window.endSheet(sheet, returnCode: .cancel) }
        f.reader.discussions.discardDrafts(); f.reader.stop(); f.window.close()
        try? FileManager.default.removeItem(at: f.file)
    }
    private func waitUntil(_ predicate: () -> Bool) async throws {
        for _ in 0..<150 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Native discussion state did not settle")
    }

    func testAddReadsTheActualFormattedSelectionWithoutSavingUntilPost() async throws {
        let fixture = try await makeFixture()
        defer { fixture.reader.discussions.discardDrafts(); fixture.reader.stop(); fixture.window.close(); try? FileManager.default.removeItem(at: fixture.file) }
        let web = try XCTUnwrap(findWebView(fixture.controller.view))
        _ = try await web.callAsyncJavaScript("""
        const paragraph=Array.from(document.querySelectorAll('main p')).find(p=>p.textContent.includes('bold'));
        const range=document.createRange();range.selectNodeContents(paragraph);
        getSelection().removeAllRanges();getSelection().addRange(range);return true;
        """, arguments: [:], in: nil, contentWorld: WKContentWorld.world(name: "DiscussionInteractionTests"))
        fixture.reader.requestAddDiscussion()
        for _ in 0..<100 {
            if fixture.reader.discussions.selection != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(fixture.reader.showDiscussions)
        XCTAssertNotNil(fixture.reader.discussions.selection)
        if let key = fixture.reader.discussions.selection {
            XCTAssertEqual(fixture.reader.discussions.drafts[key]?.target?.exact, "Café bold passage.")
            fixture.reader.discussions.setDraft("Keep this text while changing inspectors.", for: key)
            fixture.reader.showChanges = true
            XCTAssertFalse(fixture.reader.showDiscussions)
            fixture.reader.showDiscussions = true
            XCTAssertFalse(fixture.reader.showChanges)
            XCTAssertEqual(fixture.reader.discussions.drafts[key]?.body, "Keep this text while changing inspectors.")
        }
        XCTAssertEqual(try Data(contentsOf: fixture.file), fixture.data)
    }

    func testFirstPostRequestsAnAuthorWithoutWritingOrDiscardingTheDraft() async throws {
        let fixture = try await makeFixture()
        defer { fixture.reader.discussions.discardDrafts(); fixture.reader.stop(); fixture.window.close(); try? FileManager.default.removeItem(at: fixture.file) }
        let reader = fixture.reader, key = DiscussionSession.DraftKey.new(UUID())
        reader.discussions.displayName = ""; reader.discussions.selection = key
        reader.discussions.setDraft("A first comment.", for: key,
            target: .init(type: "TextQuoteSelector", exact: "Before.", prefix: "Plan", suffix: "Café", section: nil))
        reader.postDiscussion()
        XCTAssertTrue(reader.showDiscussionAuthorPrompt)
        XCTAssertEqual(try Data(contentsOf: fixture.file), fixture.data)
        XCTAssertEqual(reader.discussions.drafts[key]?.body, "A first comment.")
        XCTAssertNil(reader.discussions.pending)
    }

    func testDiscussionComposerUsesTheSharedInspectorWithoutRecreatingTheWebView() async throws {
        let fixture = try await makeFixture()
        defer { fixture.reader.discussions.discardDrafts(); fixture.reader.stop(); fixture.window.close(); try? FileManager.default.removeItem(at: fixture.file) }
        let reader = fixture.reader, web = try XCTUnwrap(findWebView(fixture.controller.view))
        _ = try await web.evaluateJavaScript("window.marginedDiscussionDocument=document;true")
        let key = DiscussionSession.DraftKey.new(UUID())
        reader.discussions.selection = key
        reader.discussions.setDraft("A native composer beside the document.", for: key,
            target: .init(type: "TextQuoteSelector", exact: "Before.", prefix: "Plan", suffix: "Café", section: nil))
        reader.showChanges = true
        try await Task.sleep(for: .milliseconds(150))
        reader.showDiscussions = true
        for _ in 0..<100 {
            fixture.controller.view.layoutSubtreeIfNeeded()
            if let editor = findEditor(fixture.controller.view), !frameInWindow(web).intersects(frameInWindow(editor)) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(reader.showChanges)
        let editor = findEditor(fixture.controller.view)
        XCTAssertNotNil(editor, "The native discussion composer must be present in the reserved inspector")
        if let editor {
            XCTAssertEqual(editor.string, "A native composer beside the document.")
            let documentFrame = frameInWindow(web), editorFrame = frameInWindow(editor)
            XCTAssertGreaterThan(documentFrame.width, 420)
            XCTAssertFalse(documentFrame.intersects(editorFrame), "document \(documentFrame), editor \(editorFrame), window \(fixture.window.frame), content \(fixture.controller.view.frame)")
            XCTAssertGreaterThanOrEqual(editorFrame.minX, documentFrame.maxX)
        }
        reader.showChanges = true
        try await Task.sleep(for: .milliseconds(100))
        reader.showDiscussions = true
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(findWebView(fixture.controller.view) === web)
        let retained = try await web.evaluateJavaScript("window.marginedDiscussionDocument===document") as? Bool
        XCTAssertEqual(retained, true)
        XCTAssertEqual(reader.discussions.drafts[key]?.body, "A native composer beside the document.")
        XCTAssertEqual(try Data(contentsOf: fixture.file), fixture.data)
    }

    func testReaderMarkersAndExplicitPassageNavigationUseCurrentGeometryWithoutWriting() async throws {
        var source = "# Plan\n\n" + String(repeating: "Padding paragraph.\n\n", count: 12)
        source += "Before.\n\nCafe\u{301} **bold** passage.\n\nAfter.\n\n" + String(repeating: "Tail paragraph.\n\n", count: 30)
        for id in ["t1", "t2"] {
            let thread = DiscussionThread(id: id, state: .open,
                target: .init(type: "TextQuoteSelector", exact: "Café bold passage.", prefix: "Before.", suffix: "After.", section: "Plan"),
                messages: [.init(id: "m-" + id, author: "Reviewer", created: "2026-10-23T10:00:00Z", body: "A note.", inReplyTo: nil)],
                resolvedBy: nil, resolved: nil, attachmentHistory: [])
            let document = try DiscussionCodec.parse(source)
            source = try MarkdownSource.decode(MarkdownSourceEdits.apply(DiscussionEdits.splices(for: .newThread(thread), in: document), to: Data(source.utf8), expectedSource: source))
        }
        let fixture = try await makeFixture(source: source)
        defer { fixture.reader.discussions.discardDrafts(); fixture.reader.stop(); fixture.window.close(); try? FileManager.default.removeItem(at: fixture.file) }
        let reader = fixture.reader, web = try XCTUnwrap(findWebView(fixture.controller.view))
        let initialScroll = try await web.evaluateJavaScript("window.scrollY") as? Double
        reader.showDiscussions = true
        for _ in 0..<150 {
            if reader.discussionMargin?.anchors.count == 2 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(reader.discussionMargin?.anchors.map(\.id), ["t1", "t2"])
        XCTAssertEqual(reader.discussionMargin?.bodyFont, 16)
        let markers = try await web.evaluateJavaScript("document.querySelectorAll('[data-margined-thread]').length") as? Int
        XCTAssertEqual(markers, 1)
        reader.openDiscussion("t2")
        try await Task.sleep(for: .milliseconds(100))
        let openedScroll = try await web.evaluateJavaScript("window.scrollY") as? Double
        XCTAssertEqual(openedScroll, initialScroll)
        reader.goToDiscussion("t2")
        for _ in 0..<100 {
            if let position = try await web.evaluateJavaScript("window.scrollY") as? Double, position > (initialScroll ?? 0) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let movedScroll = try await web.evaluateJavaScript("window.scrollY") as? Double
        XCTAssertGreaterThan(movedScroll ?? 0, initialScroll ?? 0)
        let focused = try await web.evaluateJavaScript("document.activeElement.textContent.normalize('NFC')") as? String
        XCTAssertEqual(focused, "Café bold passage.")
        reader.showDiscussions = false
        for _ in 0..<100 {
            if try await web.evaluateJavaScript("document.querySelectorAll('[data-margined-thread]').length") as? Int == 0 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let hidden = try await web.evaluateJavaScript("document.querySelectorAll('[data-margined-thread]').length") as? Int
        XCTAssertEqual(hidden, 0)
        XCTAssertEqual(try Data(contentsOf: fixture.file), fixture.data)
    }

    func testReattachUsesActualSelectionWithoutStartingAnotherDraftOrSaving() async throws {
        let fixture = try await makeFixture(source: try discussionSource())
        defer { fixture.reader.discussions.discardDrafts(); fixture.reader.stop(); fixture.window.close(); try? FileManager.default.removeItem(at: fixture.file) }
        let reader = fixture.reader, web = try XCTUnwrap(findWebView(fixture.controller.view))
        reader.openDiscussion("t1")
        reader.discussions.setDraft("Retain this reply.", for: .thread("t1"))
        try await Task.sleep(for: .milliseconds(150))
        _ = try await web.callAsyncJavaScript("""
        const paragraph=Array.from(document.querySelectorAll('main p')).find(p=>p.textContent==='After.');
        const range=document.createRange();range.selectNodeContents(paragraph);
        getSelection().removeAllRanges();getSelection().addRange(range);return true;
        """, arguments: [:], in: nil, contentWorld: WKContentWorld.world(name: "DiscussionInteractionTests"))
        reader.requestReattachDiscussion("t1")
        for _ in 0..<100 {
            if reader.discussionReattachment != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(reader.discussionReattachment?.originalTarget.exact, "Café bold passage.")
        XCTAssertEqual(reader.discussionReattachment?.selection.target.exact, "After.")
        XCTAssertEqual(reader.discussions.selection, .thread("t1"))
        XCTAssertEqual(reader.discussions.drafts.count, 1)
        XCTAssertEqual(reader.discussions.drafts[.thread("t1")]?.body, "Retain this reply.")
        XCTAssertEqual(try Data(contentsOf: fixture.file), fixture.data)
    }

    func testDiscussionFiltersAlsoFilterTheActualPassageMarkers() async throws {
        let fixture = try await makeFixture(source: try discussionSource())
        defer { fixture.reader.discussions.discardDrafts(); fixture.reader.stop(); fixture.window.close(); try? FileManager.default.removeItem(at: fixture.file) }
        let reader = fixture.reader, web = try XCTUnwrap(findWebView(fixture.controller.view))
        reader.showDiscussions = true
        for (filter, expected) in [(DiscussionSession.Filter.open, ["t1"]), (.all, ["t1", "t2"]), (.resolved, ["t2"]), (.unattached, [])] {
            reader.discussions.filter = filter
            var actual: [String] = []
            for _ in 0..<100 {
                actual = try await web.evaluateJavaScript("Array.from(document.querySelectorAll('[data-margined-thread]'), e=>e.dataset.marginedThread).sort()") as? [String] ?? []
                if actual == expected { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertEqual(actual, expected, "Filter: \(filter)")
        }
        XCTAssertEqual(try Data(contentsOf: fixture.file), fixture.data)
    }


    func testNativeHistoryRendersFormattedBodiesAndLocalImagesWithReadOnlyTasks() async throws {
        let f = try await makeFixture(source: try discussionSource()); defer { clean(f) }
        let document = try XCTUnwrap(findWebView(f.controller.view))
        let image = f.file.deletingPathExtension().appendingPathExtension("png")
        try historyPixel.write(to: image); defer { try? FileManager.default.removeItem(at: image) }
        let body = "**Formatted history.**\n\n| Item | State |\n| --- | --- |\n| Reader | Ready |\n\n- [ ] Comment task\n\n![History](\(image.lastPathComponent))\n\n![Remote](https://127.0.0.1:9/history.png)"
        let bytes = try appendHistoryReply(body, id: "m-rich", file: f.file, threadID: "t1")
        f.reader.reload(); try await waitUntil { !f.reader.isRendering }; f.reader.openDiscussion("t1")
        let mounted = await poll { self.history(in: f.controller.view, excluding: document) != nil }
        XCTAssertTrue(mounted, "Saved discussion bodies must use a native rendered history, separate from the composer")
        guard mounted, let history = history(in: f.controller.view, excluding: document) else { return }
        let ready = await pollAsync {
            try await history.evaluateJavaScript("document.querySelector('article[data-message-id=m-rich] strong')?.textContent==='Formatted history.' && document.querySelector('img[alt=History]')?.naturalWidth===1") as? Bool == true
        }; XCTAssertTrue(ready)
        let duplicateQuoteCount = try await history.evaluateJavaScript("document.querySelectorAll('main > blockquote').length") as? Int
        XCTAssertEqual(duplicateQuoteCount, 0, "The surrounding native thread already displays its quoted context")
        let historyValue0 = try await history.evaluateJavaScript("document.querySelector('td')?.textContent") as? String
        XCTAssertEqual(historyValue0, "Reader")
        let historyValue1 = try await history.evaluateJavaScript("document.querySelector('input').disabled") as? Bool
        XCTAssertEqual(historyValue1, true)
        let historyValue2 = try await history.evaluateJavaScript("document.querySelector('img[alt=Remote]').getAttribute('src')") as? String
        XCTAssertEqual(historyValue2, nil)
        let historyValue3 = try await history.evaluateJavaScript("document.querySelectorAll('article header time').length") as? Int
        XCTAssertEqual(historyValue3, 2)
        let historyValue4 = try await history.evaluateJavaScript("document.querySelector('article[data-message-id=m-rich] header a')?.textContent") as? String
        XCTAssertEqual(historyValue4, "Reviewer")
        f.reader.loadRemoteImages = true
        let optedIn = await pollAsync {
            try await history.evaluateJavaScript("document.querySelector('img[alt=Remote]')?.getAttribute('src')==='https://127.0.0.1:9/history.png'") as? Bool == true
        }; XCTAssertTrue(optedIn, "The history must follow this document's remote-image choice")
        XCTAssertEqual(try Data(contentsOf: f.file), bytes)
        XCTAssertFalse(f.reader.fileSaving)
    }

    func testNativeHistoryRefreshKeepsItsPageReadingPositionAndFocusedDraft() async throws {
        let f = try await makeFixture(source: try discussionSource()); defer { clean(f) }
        let document = try XCTUnwrap(findWebView(f.controller.view))
        let paragraphs = (0..<45).map { "History paragraph \($0) stays readable." }.joined(separator: "\n\n")
        _ = try appendHistoryReply(paragraphs, id: "m-long", file: f.file, threadID: "t1")
        f.reader.reload(); try await waitUntil { !f.reader.isRendering }; f.reader.openDiscussion("t1")
        f.reader.discussions.setDraft("Keep this focused reply.", for: .thread("t1"))
        let mounted = await poll { self.history(in: f.controller.view, excluding: document) != nil && self.findEditor(f.controller.view)?.string == "Keep this focused reply." }
        XCTAssertTrue(mounted, "The rendered history and native reply editor must coexist")
        guard mounted, let history = history(in: f.controller.view, excluding: document), let editor = findEditor(f.controller.view) else { return }
        let ready = await pollAsync {
            guard !history.isLoading else { return false }
            return try await history.evaluateJavaScript("document.querySelectorAll('article').length===2 && document.documentElement.scrollHeight>innerHeight && document.body.style.fontSize!==''") as? Bool == true
        }
        XCTAssertTrue(ready)
        XCTAssertTrue(f.window.makeFirstResponder(editor))
        _ = try await history.callAsyncJavaScript("""
        await new Promise(requestAnimationFrame); await new Promise(requestAnimationFrame);
        window.scrollTo(0,160);
        await new Promise(requestAnimationFrame); await new Promise(requestAnimationFrame);
        return true;
        """, arguments: [:], in: nil, contentWorld: .defaultClient)
        let scrolled = await pollAsync { try await history.evaluateJavaScript("scrollY>=159 && scrollY<=161") as? Bool == true }
        XCTAssertTrue(scrolled, "Establish an actual scrolled history with its native editor focused before refreshing")
        guard scrolled else { return }
        _ = try await history.evaluateJavaScript("window.historyPage=document;true")
        let before = try await history.evaluateJavaScript("scrollY") as? Double ?? 0
        XCTAssertGreaterThan(before, 0)
        let bytes = try appendHistoryReply("A newly saved reply.", id: "m-new", file: f.file, threadID: "t1")
        f.reader.reload(); try await waitUntil { !f.reader.isRendering }
        let updated = await pollAsync { try await history.evaluateJavaScript("document.querySelectorAll('article').length===3") as? Bool == true }
        XCTAssertTrue(updated)
        XCTAssertTrue(self.history(in: f.controller.view, excluding: document) === history)
        let historyValue5 = try await history.evaluateJavaScript("window.historyPage===document") as? Bool
        XCTAssertEqual(historyValue5, true)
        let historyValue6 = try await history.evaluateJavaScript("scrollY") as? Double ?? 0
        XCTAssertEqual(historyValue6, before, accuracy: 1)
        XCTAssertTrue(self.findEditor(f.controller.view) === editor)
        XCTAssertTrue(f.window.firstResponder === editor)
        XCTAssertEqual(f.reader.discussions.drafts[.thread("t1")]?.body, "Keep this focused reply.")
        XCTAssertEqual(try Data(contentsOf: f.file), bytes)
        _ = f.window.makeFirstResponder(nil)
    }

    func testOldHistoryImageRequestCannotReadOrReportIntoTheNextDocument() async throws {
        let f = try await makeFixture(source: try discussionSource()); defer { clean(f) }
        let document = try XCTUnwrap(findWebView(f.controller.view))
        let image = f.file.deletingPathExtension().appendingPathExtension("png")
        try historyPixel.write(to: image); defer { try? FileManager.default.removeItem(at: image) }
        let bytes = try appendHistoryReply("![History](\(image.lastPathComponent))", id: "m-image", file: f.file, threadID: "t1")
        f.reader.reload(); try await waitUntil { !f.reader.isRendering }; f.reader.openDiscussion("t1")
        let mounted = await poll { self.history(in: f.controller.view, excluding: document) != nil }
        XCTAssertTrue(mounted, "The current conversation must own a native history image context")
        guard mounted, let old = history(in: f.controller.view, excluding: document) else { return }
        let ready = await pollAsync { try await old.evaluateJavaScript("document.querySelector('img[alt=History]')?.naturalWidth===1") as? Bool == true }; XCTAssertTrue(ready)
        let oldAddress = try await old.evaluateJavaScript("document.querySelector('img[alt=History]').src") as? String
        let address = try XCTUnwrap(oldAddress)
        let handler = try XCTUnwrap(old.configuration.urlSchemeHandler(forURLScheme: "margined-resource"))
        let folder = f.file.deletingLastPathComponent().appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let next = folder.appendingPathComponent("Identical.md")
        try bytes.write(to: next); try historyPixel.write(to: folder.appendingPathComponent(image.lastPathComponent))
        f.reader.fileURL = next; f.reader.source = try MarkdownSource.decode(bytes); f.reader.render(); try await waitUntil { !f.reader.isRendering }; f.reader.openDiscussion("t1")
        let replaced = await poll { self.history(in: f.controller.view, excluding: document).map { $0 !== old } == true }; XCTAssertTrue(replaced)
        let request = MacHistoryImageRequest(URLRequest(url: try XCTUnwrap(URL(string: address))))
        handler.webView(old, start: request)
        let finished = await poll { request.failure != nil || !request.data.isEmpty }; XCTAssertTrue(finished)
        XCTAssertEqual((request.failure as? URLError)?.code, .cancelled)
        XCTAssertTrue(request.data.isEmpty)
        XCTAssertNil(f.reader.localImageError)
        XCTAssertEqual(try Data(contentsOf: next), bytes)
        XCTAssertEqual(try Data(contentsOf: f.file), bytes)
    }

    private var historyPixel: Data { Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+j5iQAAAAASUVORK5CYII=")! }
    private func appendHistoryReply(_ body: String, id: String, file: URL, threadID: String) throws -> Data {
        let data = try Data(contentsOf: file), source = try MarkdownSource.decode(data)
        let message = DiscussionMessage(id: id, author: "Guest", created: "2026-10-24T10:00:00Z", body: body,
                                        inReplyTo: "m-t1")
        let bytes = try MarkdownSourceEdits.apply(DiscussionEdits.splices(for:
            .reply(threadID: threadID, message: message, reopenResolved: false), in: DiscussionCodec.parse(source)),
            to: data, expectedSource: source)
        try bytes.write(to: file, options: .atomic); return bytes
    }
    private func history(in view: NSView, excluding document: WKWebView) -> WKWebView? {
        if let web = view as? WKWebView { return web !== document ? web : nil }
        return view.subviews.lazy.compactMap { self.history(in: $0, excluding: document) }.first
    }

    private func poll(_ predicate: () -> Bool) async -> Bool {
        for _ in 0..<500 { if predicate() { return true }; try? await Task.sleep(for: .milliseconds(20)) }
        return false
    }
    private func pollAsync(_ predicate: () async throws -> Bool) async -> Bool {
        for _ in 0..<500 { if (try? await predicate()) == true { return true }; try? await Task.sleep(for: .milliseconds(20)) }
        return false
    }

    private func discussionSource() throws -> String {
        var source = "# Plan\n\nBefore.\n\nCafe\u{301} **bold** passage.\n\nAfter.\n\nTail.\n"
        for (id, state, exact, prefix, suffix) in [
            ("t1", DiscussionThread.State.open, "Café bold passage.", "Before.", "After."),
            ("t2", .resolved, "After.", "Café bold passage.", "Tail.")
        ] {
            let thread = DiscussionThread(id: id, state: state,
                target: .init(type: "TextQuoteSelector", exact: exact, prefix: prefix, suffix: suffix, section: "Plan"),
                messages: [.init(id: "m-" + id, author: "Reviewer", created: "2026-10-23T10:00:00Z", body: "A note.", inReplyTo: nil)],
                resolvedBy: state == .resolved ? "Reviewer" : nil, resolved: state == .resolved ? "2026-10-23T11:00:00Z" : nil, attachmentHistory: [])
            let document = try DiscussionCodec.parse(source)
            source = try MarkdownSource.decode(MarkdownSourceEdits.apply(DiscussionEdits.splices(for: .newThread(thread), in: document), to: Data(source.utf8), expectedSource: source))
        }
        return source
    }

    private struct Fixture {
        let reader: ReaderState
        let controller: NSHostingController<ReaderView>
        let window: NSWindow
        let file: URL
        let data: Data
    }
    private func makeFixture(source customSource: String? = nil) async throws -> Fixture {
        let source = customSource ?? "# Plan\n\nBefore.\n\nCafe\u{301} **bold** passage.\n\nAfter.\n"
        let data = Data(source.utf8), file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".md")
        try data.write(to: file)
        let reader = ReaderState(); reader.fileURL = file; reader.source = source; reader.render()
        let controller = NSHostingController(rootView: ReaderView(reader: reader))
        let window = DiscussionInteractionWindow(contentViewController: controller)
        window.styleMask = [.titled, .closable, .resizable]
        window.setContentSize(NSSize(width: 1_200, height: 780)); window.makeKeyAndOrderFront(nil)
        for _ in 0..<200 {
            if let web = findWebView(controller.view), web.url != nil, !web.isLoading, !reader.isRendering, reader.currentDiscussionVersion.snapshot != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        return .init(reader: reader, controller: controller, window: window, file: file, data: data)
    }
    private func findWebView(_ view: NSView) -> WKWebView? {
        if let web = view as? WKWebView { return web }
        return view.subviews.lazy.compactMap { self.findWebView($0) }.first
    }
    private func findEditor(_ view: NSView) -> NSTextView? {
        if view is WKWebView { return nil }
        if let editor = view as? NSTextView, editor.isEditable { return editor }
        return view.subviews.lazy.compactMap { self.findEditor($0) }.first
    }
    private func frameInWindow(_ view: NSView) -> NSRect { view.convert(view.bounds, to: nil) }
}

@MainActor private final class DiscussionInteractionWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

private final class MacHistoryImageRequest: NSObject, WKURLSchemeTask {
    let request: URLRequest
    var data = Data()
    var failure: (any Error)?
    init(_ request: URLRequest) { self.request = request }
    func didReceive(_ response: URLResponse) {}
    func didReceive(_ data: Data) { self.data.append(data) }
    func didFinish() {}
    func didFailWithError(_ error: any Error) { failure = error }
}
