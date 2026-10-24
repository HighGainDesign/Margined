import AppKit
import XCTest
@testable import Margined

@MainActor final class DiscussionCopyFlowTests: XCTestCase {
    func testEncodedCopyOpensIndependentDocumentAndKeepsDraftUntilExplicitPost() async throws {
        let f = try await fixture(encoded: true)
        defer { cleanup(f) }
        let key = try draft(in: f.reader, body: "Post only in the saved copy.")
        guard let copy = await makeCopy(f.reader, to: f.destination) else { return }
        defer { close(copy) }
        copy.makeWindowControllers(); copy.showWindows(); try await settle(copy.reader)
        XCTAssertEqual(try Data(contentsOf: f.destination), f.data)
        XCTAssertEqual(copy.fileURL, f.destination)
        XCTAssertEqual(copy.reader.fileURL, f.destination)
        XCTAssertTrue(copy.reader !== f.reader)
        XCTAssertEqual(copy.reader.discussions.selection, key)
        XCTAssertEqual(copy.reader.discussions.displayName, "Reviewer")
        XCTAssertEqual(copy.reader.discussions.drafts[key]?.body, "Post only in the saved copy.")
        XCTAssertFalse(copy.reader.canUndoDiscussion)
        copy.reader.postDiscussion(); try await settle(copy.reader)
        XCTAssertEqual(copy.reader.rendered?.discussions?.threads.first?.messages.first?.body, "Post only in the saved copy.")
        XCTAssertNil(copy.reader.discussions.drafts[key])
        XCTAssertEqual(try Data(contentsOf: f.file), f.data)
        XCTAssertEqual(f.reader.discussions.drafts[key]?.body, "Post only in the saved copy.")
        XCTAssertEqual(Array(try Data(contentsOf: f.destination).prefix(2)), [0xff, 0xfe])
    }

    func testSnapshotsAndStreamsCopyIntoOrdinaryFilesWithoutWritingBack() async throws {
        for streaming in [false, true] {
            let f = try await fixture()
            defer { cleanup(f) }
            f.reader.fileURL = nil; f.reader.isStreamingPreview = streaming
            f.reader.render(); try await settle(f.reader)
            let key = try draft(in: f.reader, body: "Continue in a real file.")
            guard let copy = await makeCopy(f.reader, to: f.destination) else { continue }
            defer { close(copy) }
            copy.makeWindowControllers(); copy.showWindows(); try await settle(copy.reader)
            XCTAssertFalse(copy.reader.isStreamingPreview)
            XCTAssertEqual(copy.reader.fileURL, f.destination)
            XCTAssertEqual(copy.reader.discussions.drafts[key]?.body, "Continue in a real file.")
            copy.reader.postDiscussion(); try await settle(copy.reader)
            XCTAssertEqual(copy.reader.rendered?.discussions?.threads.first?.messages.first?.body, "Continue in a real file.")
            XCTAssertNil(f.reader.fileURL)
            XCTAssertEqual(f.reader.isStreamingPreview, streaming)
            XCTAssertEqual(try Data(contentsOf: f.file), f.data)
            XCTAssertEqual(f.reader.discussions.drafts[key]?.body, "Continue in a real file.")
        }
    }

    func testCopyRefusesExistingDestinationAndOriginalFile() async throws {
        let f = try await fixture()
        defer { cleanup(f) }
        let other = Data("Keep this unrelated document.\n".utf8)
        try other.write(to: f.destination)
        for destination in [f.destination, f.file] {
            do {
                let copy = try await ReaderDiscussionFiles.makeCopy(from: f.reader, to: destination)
                close(copy)
                XCTFail("Saving a copy must not replace an existing file")
            } catch {}
        }
        XCTAssertEqual(try Data(contentsOf: f.destination), other)
        XCTAssertEqual(try Data(contentsOf: f.file), f.data)
    }

    func testCopyCarriesPostedDraftContinuationWithoutCopyingUndo() async throws {
        let f = try await fixture()
        defer { cleanup(f) }
        let key = try draft(in: f.reader, body: "First saved message.")
        f.reader.postDiscussion()
        f.reader.discussions.setDraft("Later reply.", for: key)
        try await settle(f.reader)
        XCTAssertTrue(f.reader.canUndoDiscussion)
        let original = try Data(contentsOf: f.file)
        guard let copy = await makeCopy(f.reader, to: f.destination) else { return }
        defer { close(copy) }
        copy.makeWindowControllers(); copy.showWindows(); try await settle(copy.reader)
        XCTAssertFalse(copy.reader.canUndoDiscussion)
        XCTAssertEqual(copy.reader.discussions.selection, key)
        XCTAssertEqual(copy.reader.discussions.drafts[key]?.body, "Later reply.")
        copy.reader.postDiscussion(); try await settle(copy.reader)
        XCTAssertEqual(copy.reader.rendered?.discussions?.threads.count, 1)
        XCTAssertEqual(copy.reader.rendered?.discussions?.threads.first?.messages.map(\.body), ["First saved message.", "Later reply."])
        XCTAssertEqual(try Data(contentsOf: f.file), original)
        XCTAssertEqual(f.reader.discussions.drafts[key]?.body, "Later reply.")
    }

    func testCopyRefusesWhileAFileSaveIsPending() async throws {
        let f = try await fixture()
        defer { cleanup(f) }
        _ = try draft(in: f.reader, body: "Saving now.")
        f.reader.postDiscussion()
        XCTAssertTrue(f.reader.fileSaving)
        do {
            let copy = try await ReaderDiscussionFiles.makeCopy(from: f.reader, to: f.destination)
            close(copy); XCTFail("A copy must not race an accepted source save")
        } catch { XCTAssertEqual(error as? DiscussionSession.Failure, .busy) }
        try await settle(f.reader)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.destination.path))
    }

    func testCopyPanelRequiresANewFilenameForAnExistingDestination() async throws {
        let f = try await fixture()
        defer { cleanup(f) }
        let flow = ReaderDiscussionCopyPanel(reader: f.reader)
        XCTAssertTrue(flow.panel.delegate === flow, "The native panel must use its file validation delegate")
        XCTAssertThrowsError(try flow.panel(flow.panel, validate: f.file),
            "The native panel must require a new filename when the destination already exists")
        XCTAssertEqual(try Data(contentsOf: f.file), f.data)
    }

    func testCancellingTheNativeCopyPanelKeepsTheOriginalAndDraft() async throws {
        let f = try await fixture()
        defer { cleanup(f) }
        let document = try await openDocument(f.file)
        let window = try XCTUnwrap(document.windowControllers.first?.window)
        defer {
            if let panel = window.attachedSheet as? NSSavePanel { panel.cancel(nil) }
            close(document)
        }
        let key = try draft(in: document.reader, body: "Still unposted after Cancel.")
        let count = NSDocumentController.shared.documents.count
        document.reader.saveDiscussionCopy()
        try await waitUntil { window.attachedSheet is NSSavePanel }
        let panel = try XCTUnwrap(window.attachedSheet as? NSSavePanel)
        panel.cancel(nil)
        try await waitUntil { window.attachedSheet == nil }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: f.directory.path), ["Original.md"])
        XCTAssertEqual(try Data(contentsOf: f.file), f.data)
        XCTAssertEqual(document.reader.discussions.drafts[key]?.body, "Still unposted after Cancel.")
        XCTAssertFalse(document.reader.fileSaving)
        XCTAssertEqual(NSDocumentController.shared.documents.count, count)
    }

    func testPendingCopyKeepsCloseWaitingAndPreservesNewerTyping() async throws {
        let f = try await fixture()
        defer { cleanup(f) }
        let document = try await openDocument(f.file)
        let window = try XCTUnwrap(document.windowControllers.first?.window)
        defer {
            if let sheet = window.attachedSheet { window.endSheet(sheet, returnCode: .alertFirstButtonReturn) }
            close(document)
        }
        let reader = document.reader
        let key = try draft(in: reader, body: "Draft at copy confirmation.")
        let hold = HeldCopyDestination(f.destination)
        defer { hold.release() }
        try await waitUntil { hold.isHolding }
        var savedCopy: MarkdownDocument?
        let pending = Task { @MainActor in
            savedCopy = try await ReaderDiscussionFiles.makeCopy(from: reader, to: f.destination)
        }
        do {
            try await waitUntil { reader.discussionCopySaving }
            reader.discussions.setDraft("Newer typing stays in the original.", for: key)
            document.close()
            // Allow the real close task to run while the coordinated destination is held.
            await Task.yield()
            XCTAssertTrue(reader.fileSaving)
            XCTAssertTrue(window.isVisible)
            XCTAssertNil(window.attachedSheet, "Close must wait for the accepted copy before asking about drafts")
            hold.release()
            try await pending.value
            let copy = try XCTUnwrap(savedCopy)
            defer { close(copy) }
            try await waitUntil { hold.isFinished && window.attachedSheet != nil }
            XCTAssertEqual(copy.reader.discussions.drafts[key]?.body, "Draft at copy confirmation.")
            XCTAssertEqual(reader.discussions.drafts[key]?.body, "Newer typing stays in the original.")
            XCTAssertEqual(try Data(contentsOf: f.destination), f.data)
            XCTAssertEqual(try Data(contentsOf: f.file), f.data)
            let sheet = try XCTUnwrap(window.attachedSheet)
            try XCTUnwrap(sheet.defaultButtonCell?.controlView as? NSButton).performClick(nil)
            try await waitUntil { window.attachedSheet == nil }
            XCTAssertTrue(window.isVisible)
            XCTAssertEqual(reader.discussions.drafts[key]?.body, "Newer typing stays in the original.")
        } catch {
            hold.release()
            _ = try? await pending.value
            if let copy = savedCopy { close(copy) }
            throw error
        }
    }

    func testCancellingAnotherCopyPickerKeepsCurrentFileAndUnpostedText() async throws {
        let f = try await fixture()
        defer { cleanup(f) }
        let document = try await openDocument(f.file)
        let window = try XCTUnwrap(document.windowControllers.first?.window)
        defer {
            if let panel = window.attachedSheet as? NSOpenPanel { panel.cancel(nil) }
            close(document)
        }
        let key = try draft(in: document.reader, body: "Keep this comment after cancelling comparison.")
        let count = NSDocumentController.shared.documents.count
        document.reader.chooseDiscussionCopy()
        try await waitUntil { window.attachedSheet is NSOpenPanel }
        let panel = try XCTUnwrap(window.attachedSheet as? NSOpenPanel)
        panel.cancel(nil)
        try await waitUntil { window.attachedSheet == nil }
        XCTAssertEqual(try Data(contentsOf: f.file), f.data)
        XCTAssertEqual(document.reader.fileURL, f.file)
        XCTAssertEqual(document.reader.discussions.drafts[key]?.body, "Keep this comment after cancelling comparison.")
        XCTAssertNil(document.reader.discussionImportPreview)
        XCTAssertFalse(document.reader.fileSaving)
        XCTAssertEqual(NSDocumentController.shared.documents.count, count)
    }

    func testConflictReviewWaitsForExplicitImportAndEscapePreservesTheDraft() async throws {
        let f = try await fixture()
        defer { cleanup(f) }
        func annotated(_ body: String, prose: String) throws -> Data {
            let source = try DiscussionCodec.parse(prose)
            let thread = DiscussionThread(id: "t-review", state: .open,
                target: .init(type: "TextQuoteSelector", exact: "Passage.", prefix: "Before.", suffix: "After.", section: "Plan"),
                messages: [.init(id: "m-review", author: "Reviewer", created: "2026-10-23T10:00:00Z", body: body, inReplyTo: nil)],
                resolvedBy: nil, resolved: nil, attachmentHistory: [])
            return try MarkdownSourceEdits.apply(DiscussionEdits.splices(for: .newThread(thread), in: source),
                to: Data(prose.utf8), expectedSource: prose)
        }
        let original = try annotated("Keep the current note.", prose: "# Plan\n\nBefore.\n\nPassage.\n\nAfter.\n")
        let other = try annotated("Read this incoming variant.", prose: "Other copy prose must not be imported.\n\nPassage.\n")
        try original.write(to: f.file); try other.write(to: f.destination)
        let document = try await openDocument(f.file), reader = document.reader
        let window = try XCTUnwrap(document.windowControllers.first?.window)
        defer {
            reader.discardDiscussionImport()
            if let sheet = window.attachedSheet { window.endSheet(sheet, returnCode: .cancel) }
            close(document)
        }
        let key = try draft(in: reader, body: "Keep this unposted while comparing.")
        reader.showDiscussions = true
        await reader.reviewDiscussionCopy(f.destination)
        for _ in 0..<300 {
            if window.attachedSheet != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        guard let sheet = window.attachedSheet else {
            XCTFail("Reviewing another copy must present a native confirmation sheet before any import")
            return
        }
        // SwiftUI draws these controls without NSButton-backed subviews. Use
        // real keyboard events instead of depending on its private AX tree.
        let enter = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: sheet.windowNumber, context: nil, characters: "\r",
            charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        NSApp.sendEvent(enter)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(window.attachedSheet === sheet, "Return cannot import an unresolved conflict")
        XCTAssertEqual(try Data(contentsOf: f.file), original)
        let escape = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: sheet.windowNumber, context: nil, characters: "\u{1b}",
            charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
        NSApp.sendEvent(escape)
        try await waitUntil { window.attachedSheet == nil }
        XCTAssertNil(reader.discussionImportPreview)
        XCTAssertEqual(try Data(contentsOf: f.file), original)
        XCTAssertEqual(try Data(contentsOf: f.destination), other)
        XCTAssertEqual(reader.discussions.drafts[key]?.body, "Keep this unposted while comparing.")
    }

    func testCleanExportWritesANewEncodedFileWithoutChangingSourceOrDraft() async throws {
        let f = try await fixture(source: exportSource(), encoded: true)
        defer { cleanup(f) }
        let key = try draft(in: f.reader, body: "An unposted comment stays here.")
        let prepared = try ReaderDiscussionFiles.prepareExport(.clean, from: f.reader)
        XCTAssertEqual(prepared.removedBlocks, 1, "The unrelated HTML comment is not a discussion")
        let expected = encoded(exportProse + "\r\n")
        XCTAssertEqual(prepared.data, expected)
        try await saveExport(prepared, from: f.reader, to: f.destination)
        guard FileManager.default.fileExists(atPath: f.destination.path) else {
            XCTFail("Export must create the selected new file"); return
        }
        XCTAssertEqual(try Data(contentsOf: f.destination), expected)
        XCTAssertEqual(try Data(contentsOf: f.file), f.data)
        XCTAssertEqual(f.reader.discussions.drafts[key]?.body, "An unposted comment stays here.")
        XCTAssertEqual(f.reader.fileURL, f.file)
        XCTAssertFalse(f.reader.fileSaving)
    }

    func testConversationExportWritesVisibleMarkdownAndKeepsTheOriginal() async throws {
        let f = try await fixture(source: exportSource(), encoded: true)
        defer { cleanup(f) }
        let key = try draft(in: f.reader, body: "Do not include this unposted comment.")
        let prepared = try ReaderDiscussionFiles.prepareExport(.conversation, from: f.reader)
        try await saveExport(prepared, from: f.reader, to: f.destination)
        guard FileManager.default.fileExists(atPath: f.destination.path) else {
            XCTFail("Conversation export must create a readable Markdown file"); return
        }
        let data = try Data(contentsOf: f.destination)
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(text.hasPrefix("# Discussions\n"))
        XCTAssertTrue(text.contains("> Passage."))
        XCTAssertTrue(text.contains("### Reviewer"))
        XCTAssertTrue(text.contains("### Another"))
        XCTAssertTrue(text.contains("Reply to m-export"))
        XCTAssertTrue(text.contains("Why \\*\\*now\\*\\*?"))
        XCTAssertFalse(text.contains("<!-- margined:thread"))
        XCTAssertFalse(text.contains("Do not include this unposted comment."))
        XCTAssertEqual(try Data(contentsOf: f.file), f.data)
        XCTAssertEqual(f.reader.discussions.drafts[key]?.body, "Do not include this unposted comment.")
    }

    func testPreparedExportKeepsItsOriginalContentsAndCountAcrossARefresh() async throws {
        let f = try await fixture(source: exportSource(), encoded: true)
        defer { cleanup(f) }
        let key = try draft(in: f.reader, body: "Keep typing while a copy is prepared.")
        let prepared = try ReaderDiscussionFiles.prepareExport(.clean, from: f.reader)
        let changed = exportSource().replacingOccurrences(of: "# Plan", with: "# An agent updated the plan")
        let newer = encoded(changed)
        try newer.write(to: f.file, options: .atomic)
        let refreshed = f.reader.lastRefreshed
        f.reader.reload()
        try await waitUntil { f.reader.lastRefreshed != refreshed && !f.reader.isRendering }
        try await saveExport(prepared, from: f.reader, to: f.destination)
        guard FileManager.default.fileExists(atPath: f.destination.path) else {
            XCTFail("A confirmed export must save the version prepared before the picker"); return
        }
        XCTAssertEqual(try Data(contentsOf: f.destination), encoded(exportProse + "\r\n"))
        XCTAssertEqual(prepared.removedBlocks, 1)
        XCTAssertEqual(try Data(contentsOf: f.file), newer)
        XCTAssertEqual(f.reader.discussions.drafts[key]?.body, "Keep typing while a copy is prepared.")
    }

    func testExportRefusesExistingFilesAndAnAcceptedSourceWrite() async throws {
        let f = try await fixture(source: exportSource())
        defer { cleanup(f) }
        let prepared = try ReaderDiscussionFiles.prepareExport(.clean, from: f.reader)
        let other = Data("Keep this existing file.\n".utf8)
        try other.write(to: f.destination)
        for destination in [f.file, f.destination] {
            do {
                try await saveExport(prepared, from: f.reader, to: destination)
                XCTFail("An export must never replace an existing file")
            } catch {}
        }
        XCTAssertEqual(try Data(contentsOf: f.file), f.data)
        XCTAssertEqual(try Data(contentsOf: f.destination), other)
        _ = try draft(in: f.reader, body: "An accepted source write.")
        f.reader.postDiscussion()
        XCTAssertTrue(f.reader.fileSaving)
        let extra = f.directory.appendingPathComponent("No-race.md")
        do {
            let pending = try ReaderDiscussionFiles.beginExport(prepared, from: f.reader, to: extra)
            try await pending.value
            XCTFail("An export must not race an already accepted file operation")
        } catch { XCTAssertEqual(error as? DiscussionSession.Failure, .busy) }
        try await settle(f.reader)
        XCTAssertFalse(FileManager.default.fileExists(atPath: extra.path))
        XCTAssertEqual(try Data(contentsOf: f.destination), other)
    }

    func testCancellingTheNativeCleanExportPanelKeepsTheDocumentAndDraft() async throws {
        let f = try await fixture(source: exportSource(), encoded: true)
        defer { cleanup(f) }
        let document = try await openDocument(f.file)
        let window = try XCTUnwrap(document.windowControllers.first?.window)
        defer {
            if let panel = window.attachedSheet as? NSSavePanel { panel.cancel(nil) }
            close(document)
        }
        let key = try draft(in: document.reader, body: "Keep this draft after cancelling export.")
        let count = NSDocumentController.shared.documents.count
        document.reader.exportDiscussions(.clean)
        for _ in 0..<300 {
            if window.attachedSheet is NSSavePanel { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        guard let panel = window.attachedSheet as? NSSavePanel else {
            XCTFail("Clean Copy must present a native destination picker"); return
        }
        panel.cancel(nil)
        try await waitUntil { window.attachedSheet == nil }
        XCTAssertEqual(try Data(contentsOf: f.file), f.data)
        XCTAssertEqual(document.reader.discussions.drafts[key]?.body, "Keep this draft after cancelling export.")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: f.directory.path), ["Original.md"])
        XCTAssertEqual(NSDocumentController.shared.documents.count, count)
    }

    func testUncertainCleanCopyOffersReadOnlySourceInspectionInsteadOfAFile() async throws {
        var source = exportSource()
        let closing = try XCTUnwrap(source.range(of: "-->\r\n", options: .backwards))
        source.replaceSubrange(closing, with: "Unterminated source tail.\r\n")
        let f = try await fixture(source: source)
        defer { cleanup(f) }
        let document = try await openDocument(f.file)
        let window = try XCTUnwrap(document.windowControllers.first?.window)
        var inspector: NSWindow?
        defer { inspector?.close(); close(document) }
        let key = try draft(in: document.reader, body: "Keep the unposted text after an unsafe clean export.")
        document.reader.exportDiscussions(.clean)
        XCTAssertNil(window.attachedSheet, "An uncertain block cannot be offered as a clean copy")
        XCTAssertNotNil(document.reader.discussionError)
        document.reader.inspectDiscussionSource()
        for _ in 0..<200 {
            inspector = NSApp.windows.first { $0.isVisible && self.sourceText(in: $0.contentView, matching: source) != nil }
            if inspector != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        guard let inspector, let text = sourceText(in: inspector.contentView, matching: source) else {
            XCTFail("Source inspection must expose the complete original source in a native text view"); return
        }
        XCTAssertFalse(text.isEditable)
        XCTAssertTrue(text.isSelectable)
        XCTAssertEqual(text.string, source)
        XCTAssertEqual(try Data(contentsOf: f.file), f.data)
        XCTAssertEqual(document.reader.discussions.drafts[key]?.body, "Keep the unposted text after an unsafe clean export.")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: f.directory.path), ["Original.md"])
    }

    func testAcceptedExportKeepsCloseWaitingAndRetainsNewerDraftTyping() async throws {
        let f = try await fixture(source: exportSource(), encoded: true)
        defer { cleanup(f) }
        let document = try await openDocument(f.file)
        let window = try XCTUnwrap(document.windowControllers.first?.window)
        defer {
            if let sheet = window.attachedSheet { window.endSheet(sheet, returnCode: .alertFirstButtonReturn) }
            close(document)
        }
        let reader = document.reader
        let key = try draft(in: reader, body: "An unposted comment before export.")
        let prepared = try ReaderDiscussionFiles.prepareExport(.clean, from: reader)
        let hold = HeldCopyDestination(f.destination)
        defer { hold.release() }
        try await waitUntil { hold.isHolding }
        let pending = try ReaderDiscussionFiles.beginExport(prepared, from: reader, to: f.destination)
        do {
            guard reader.fileSaving else {
                hold.release(); _ = try? await pending.value
                XCTFail("An accepted export must remain live while its destination is coordinated"); return
            }
            reader.discussions.setDraft("Newer typing stays in the original.", for: key)
            document.close(); await Task.yield()
            XCTAssertTrue(window.isVisible)
            XCTAssertNil(window.attachedSheet)
            hold.release(); try await pending.value
            try await waitUntil { hold.isFinished && window.attachedSheet != nil }
            XCTAssertEqual(try Data(contentsOf: f.destination), encoded(exportProse + "\r\n"))
            XCTAssertEqual(try Data(contentsOf: f.file), f.data)
            XCTAssertEqual(reader.discussions.drafts[key]?.body, "Newer typing stays in the original.")
            let sheet = try XCTUnwrap(window.attachedSheet)
            try XCTUnwrap(sheet.defaultButtonCell?.controlView as? NSButton).performClick(nil)
            try await waitUntil { window.attachedSheet == nil }
            XCTAssertTrue(window.isVisible)
        } catch {
            hold.release(); _ = try? await pending.value; throw error
        }
    }

    private func saveExport(_ prepared: ReaderDiscussionExport, from reader: ReaderState, to destination: URL) async throws {
        let pending = try ReaderDiscussionFiles.beginExport(prepared, from: reader, to: destination)
        try await pending.value
    }

    private var exportProse: String { "# Plan\r\n\r\nBefore.\r\n\r\nPassage.\r\n\r\nAfter.\r\n\r\n<!-- unrelated -->\r\n\r\n" }
    private func exportSource() -> String {
        exportProse + [
            "<!-- margined:thread v1", "id: t-export", "state: open", "opaque: true",
            "target:", "  type: TextQuoteSelector", "  exact: Passage.", "  prefix: Before.", "  suffix: After.", "  section: Plan",
            "messages:", "  - id: m-export", "    author: Reviewer", "    created: \"2026-10-23T10:00:00Z\"", "    body: Why **now**?",
            "  - id: m-reply", "    author: Another", "    created: \"2026-10-23T11:00:00Z\"", "    in-reply-to: m-export", "    body: A reply.", "-->"
        ].joined(separator: "\r\n") + "\r\n"
    }
    private func encoded(_ source: String) -> Data {
        var data = Data([0xff, 0xfe]); data.append(source.data(using: .utf16LittleEndian)!); return data
    }
    private func sourceText(in view: NSView?, matching source: String) -> NSTextView? {
        guard let view else { return nil }
        if let text = view as? NSTextView, text.string == source { return text }
        return view.subviews.lazy.compactMap { self.sourceText(in: $0, matching: source) }.first
    }

    private func openDocument(_ file: URL) async throws -> MarkdownDocument {
        let document = MarkdownDocument()
        try document.read(from: file, ofType: "net.daringfireball.markdown")
        NSDocumentController.shared.addDocument(document)
        document.makeWindowControllers(); document.showWindows()
        NSApp.activate(ignoringOtherApps: true)
        do {
            try await settle(document.reader)
            return document
        } catch { close(document); throw error }
    }
    private func waitUntil(_ predicate: () -> Bool) async throws {
        for _ in 0..<500 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("The native copy operation did not reach the expected state")
        throw CocoaError(.fileWriteUnknown)
    }

    private func makeCopy(_ reader: ReaderState, to url: URL) async -> MarkdownDocument? {
        do { return try await ReaderDiscussionFiles.makeCopy(from: reader, to: url) }
        catch { XCTFail("Expected a new independent Markdown copy: \(error)"); return nil }
    }
    private func draft(in reader: ReaderState, body: String) throws -> DiscussionSession.DraftKey {
        reader.discussions.displayName = "Reviewer"
        let projection = try XCTUnwrap(reader.rendered?.discussionText)
        let selection = try XCTUnwrap(projection.selection((projection.text as NSString).range(of: "Passage."), renderID: "copy-test"))
        let key = try reader.discussions.beginDraft(selection, in: projection)
        reader.discussions.setDraft(body, for: key)
        return key
    }
    private struct Fixture { let reader: ReaderState; let directory: URL; let file: URL; let destination: URL; let data: Data }
    private func fixture(source customSource: String? = nil, encoded: Bool = false) async throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let source = customSource ?? "# Plan\n\nBefore.\n\nPassage.\n\nAfter.\n"
        var data = Data(source.utf8)
        if encoded { data = Data([0xff,0xfe]); data.append(try XCTUnwrap(source.data(using: .utf16LittleEndian))) }
        let file = directory.appendingPathComponent("Original.md"), destination = directory.appendingPathComponent("Copy.md")
        try data.write(to: file)
        let reader = ReaderState(); reader.fileURL = file; reader.source = source
        reader.installLoadedSnapshot(try SourceFileEdit.capture(file)); reader.render(); try await settle(reader)
        return .init(reader: reader, directory: directory, file: file, destination: destination, data: data)
    }
    private func settle(_ reader: ReaderState) async throws {
        for _ in 0..<300 {
            if !reader.fileSaving && !reader.isRendering && reader.rendered != nil { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("The copied document did not become ready")
    }
    private func close(_ document: MarkdownDocument) {
        document.reader.discussions.discardDrafts(); document.reader.stop(); document.close()
    }
    private func cleanup(_ fixture: Fixture) {
        fixture.reader.discussions.discardDrafts(); fixture.reader.stop()
        try? FileManager.default.removeItem(at: fixture.directory)
    }
}

/// Holds a real coordination claim on the new destination, rather than replacing
/// the copy writer with a test-only implementation.
private final class HeldCopyDestination: @unchecked Sendable {
    private let lock = NSLock()
    private let resume = DispatchSemaphore(value: 0)
    private var holding = false
    private var finished = false
    var isHolding: Bool { lock.withLock { holding } }
    var isFinished: Bool { lock.withLock { finished } }

    init(_ url: URL) {
        DispatchQueue.global().async { [self] in
            let coordinator = NSFileCoordinator(filePresenter: nil)
            var error: NSError?
            coordinator.coordinate(writingItemAt: url, options: [], error: &error) { _ in
                lock.withLock { holding = true }
                _ = resume.wait(timeout: .now() + 15)
            }
            lock.withLock { holding = false; finished = true }
        }
    }
    func release() { resume.signal() }
}
