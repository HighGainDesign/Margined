import Foundation
import XCTest
#if os(iOS)
@testable import MarginediOS
private typealias ResponseTestReader = MobileReaderState
#else
@testable import Margined
private typealias ResponseTestReader = ReaderState
#endif

@MainActor
final class ResponseStateTests: XCTestCase {
    func testCancelAndExplicitSaveDoNotEnableAutosaveAndFileUndoIsOneOperation() async throws {
        let original = "**Notes (short answer):** A **bold** observation.\n\n- [X] Independent\n"
        let (reader, url) = try await makeReader(Data(original.utf8))
        XCTAssertTrue(reader.beginAnswer(0))
        let cancelled = try XCTUnwrap(reader.answerDraft)
        cancelled.text = "Discard this draft"
        reader.cancelAnswer()
        XCTAssertNil(reader.answerDraft)
        XCTAssertEqual(try Data(contentsOf: url), Data(original.utf8))
        XCTAssertTrue(reader.beginAnswer(0))
        let draft = try XCTUnwrap(reader.answerDraft)
        let text = "New **literal** text, Café 日本語"
        draft.text = text
        XCTAssertTrue(reader.canSaveAnswer)
        XCTAssertFalse(reader.requestTaskChecked(0, checked: false), "A native answer editor owns the edit session")
        reader.saveAnswer(); try await settle(reader)
        let saved = try Data(contentsOf: url)
        XCTAssertNil(reader.answerDraft)
        XCTAssertFalse(reader.checklistMode)
        XCTAssertFalse(reader.showChecklistConfirmation)
        XCTAssertEqual(reader.rendered?.responses.answers.first?.plainValue, text, reader.rendered?.html ?? "No render")
        XCTAssertTrue(try MarkdownSource.decode(saved).contains("- [X] Independent"))
        XCTAssertTrue(reader.canUndoChecklist)
        reader.undoChecklist(); try await settle(reader)
        XCTAssertEqual(try Data(contentsOf: url), Data(original.utf8))
        reader.redoChecklist(); try await settle(reader)
        XCTAssertEqual(try Data(contentsOf: url), saved)
    }

    func testUnchangedFormattedAndOversizedImportedAnswersAreByteExactNoOps() async throws {
        for value in ["Read [the reference](https://example.com/) and **bold** text.", String(repeating: "é", count: 1001)] {
            let bytes = Data("**Notes (short answer):** \(value)\r\n".utf8)
            let (reader, url) = try await makeReader(bytes)
            XCTAssertTrue(reader.beginAnswer(0))
            let draft = try XCTUnwrap(reader.answerDraft)
            if value.count > 1000 { XCTAssertEqual(draft.text.count, 1001, "An imported answer is never truncated") }
            XCTAssertTrue(reader.canSaveAnswer)
            reader.saveAnswer(); try await settle(reader)
            XCTAssertNil(reader.answerDraft)
            XCTAssertEqual(try Data(contentsOf: url), bytes)
            XCTAssertFalse(reader.checklistMode)
            XCTAssertFalse(reader.canUndoChecklist)
        }
    }

    func testValidationKeepsDraftAndEmptySaveRestoresPlaceholder() async throws {
        let original = Data("**Notes (short answer):** Existing answer\n".utf8)
        let (reader, url) = try await makeReader(original)
        XCTAssertTrue(reader.beginAnswer(0))
        let draft = try XCTUnwrap(reader.answerDraft)
        for invalid in ["line\nbreak", String(repeating: "🐈", count: 1001), "nul\u{0}text"] {
            draft.text = invalid
            XCTAssertFalse(reader.canSaveAnswer)
            reader.saveAnswer(); try await settle(reader)
            XCTAssertEqual(draft.text, invalid)
            XCTAssertEqual(try Data(contentsOf: url), original)
        }
        draft.text = "_Not answered_"
        XCTAssertTrue(reader.canSaveAnswer)
        reader.saveAnswer(); try await settle(reader)
        XCTAssertEqual(try Data(contentsOf: url), Data("**Notes (short answer):** _Not answered_\n".utf8))
    }

    func testTextSavesAndUndoPreserveAllSupportedEncodingsAndLineEndings() async throws {
        let source = "# café 🐈\r\n\r\n**Notes (short answer):** _Not answered_\r\n\r\nUntouched.\r\n"
        let changed = source.replacingOccurrences(of: "_Not answered_", with: "New answer")
        let samples: [(Data, Data)] = [
            (Data(source.utf8), Data(changed.utf8)),
            (Data([239,187,191]) + Data(source.utf8), Data([239,187,191]) + Data(changed.utf8)),
            (Data([255,254]) + source.data(using: .utf16LittleEndian)!, Data([255,254]) + changed.data(using: .utf16LittleEndian)!),
            (Data([254,255]) + source.data(using: .utf16BigEndian)!, Data([254,255]) + changed.data(using: .utf16BigEndian)!)
        ]
        for (original, expected) in samples {
            let (reader, url) = try await makeReader(original)
            XCTAssertTrue(reader.beginAnswer(0))
            try XCTUnwrap(reader.answerDraft).text = "New answer"
            reader.saveAnswer(); try await settle(reader)
            XCTAssertEqual(try Data(contentsOf: url), expected)
            reader.undoChecklist(); try await settle(reader)
            XCTAssertEqual(try Data(contentsOf: url), original)
        }
    }

    func testExternalChangesRefuseStaleSaveAndRetainTypedAnswer() async throws {
        let source = "**Notes (short answer):** _Not answered_\n"
        let (reader, url) = try await makeReader(Data(source.utf8))
        XCTAssertTrue(reader.beginAnswer(0))
        let draft = try XCTUnwrap(reader.answerDraft)
        draft.text = "Keep my unfinished answer"
        let external = Data((source + "\nAgent addition.\n").utf8)
        try external.write(to: url, options: .atomic)
        reader.saveAnswer(); try await settle(reader)
        try await waitUntil { !reader.canSaveAnswer }
        XCTAssertEqual(try Data(contentsOf: url), external)
        XCTAssertTrue(reader.answerDraft === draft)
        XCTAssertEqual(draft.text, "Keep my unfinished answer")
        XCTAssertNotNil(draft.error)
        XCTAssertFalse(reader.canSaveAnswer)
    }

    func testIdenticalReplacementAndEncodingOnlyChangeCannotAcceptAnOldDraft() async throws {
        let source = "**Notes (short answer):** _Not answered_\n"
        for replacement in [Data(source.utf8), Data([255,254]) + source.data(using: .utf16LittleEndian)!] {
            let (reader, url) = try await makeReader(Data(source.utf8))
            XCTAssertTrue(reader.beginAnswer(0))
            let draft = try XCTUnwrap(reader.answerDraft)
            draft.text = "Keep this draft"
            try replacement.write(to: url, options: .atomic)
            reader.saveAnswer(); try await settle(reader)
            try await waitUntil { !reader.canSaveAnswer }
            XCTAssertEqual(try Data(contentsOf: url), replacement)
            XCTAssertEqual(reader.answerDraft?.text, "Keep this draft")
            XCTAssertFalse(reader.canSaveAnswer)
        }
    }

    func testAnswerUndoRestoresOffsetsBeforeUndoingAnEarlierCheckbox() async throws {
        let source = "**Notes (short answer):** Original\n\n- [ ] Independent\n"
        let (reader, url) = try await makeReader(Data(source.utf8))
        reader.checklistMode = true
        XCTAssertTrue(reader.requestTaskChecked(0, checked: true)); try await settle(reader)
        let checked = try Data(contentsOf: url)
        XCTAssertTrue(reader.beginAnswer(0))
        XCTAssertFalse(reader.canUndoChecklist, "The native editor owns typing Undo until dismissed")
        try XCTUnwrap(reader.answerDraft).text = "A considerably longer new answer"
        reader.saveAnswer(); try await settle(reader)
        reader.undoChecklist(); try await settle(reader)
        XCTAssertEqual(try Data(contentsOf: url), checked)
        reader.undoChecklist(); try await settle(reader)
        XCTAssertEqual(try Data(contentsOf: url), Data(source.utf8))
    }

    func testClosedReaderRetainsStaleDraftButCannotSaveIt() async throws {
        let source = Data("**Notes (short answer):** _Not answered_\n".utf8)
        let (reader, url) = try await makeReader(source)
        XCTAssertTrue(reader.beginAnswer(0))
        try XCTUnwrap(reader.answerDraft).text = "Retain for recovery"
        #if os(iOS)
        await reader.close()
        #else
        reader.stop()
        #endif
        XCTAssertFalse(reader.canSaveAnswer)
        reader.saveAnswer(); try await settle(reader)
        XCTAssertEqual(try Data(contentsOf: url), source)
        XCTAssertEqual(reader.answerDraft?.text, "Retain for recovery")
    }

    func testReturningToOriginalBytesDoesNotReauthorizeAStaleDraft() async throws {
        let original = Data("**Notes (short answer):** _Not answered_\n".utf8)
        let (reader, url) = try await makeReader(original)
        XCTAssertTrue(reader.beginAnswer(0))
        try XCTUnwrap(reader.answerDraft).text = "Keep this text"
        let external = Data("**Notes (short answer):** Agent answer\n".utf8)
        try external.write(to: url)
        #if os(iOS)
        await reader.refresh()
        #else
        reader.reload()
        #endif
        try await waitUntil { reader.source == String(decoding: external, as: UTF8.self) }
        XCTAssertFalse(reader.canSaveAnswer)
        try original.write(to: url)
        #if os(iOS)
        await reader.refresh()
        #else
        reader.reload()
        #endif
        try await waitUntil { reader.source == String(decoding: original, as: UTF8.self) }
        XCTAssertFalse(reader.canSaveAnswer)
        reader.saveAnswer(); try await settle(reader)
        XCTAssertEqual(try Data(contentsOf: url), original)
        XCTAssertEqual(reader.answerDraft?.text, "Keep this text")
    }

    func testUnansweredGroupStaysUnansweredAndSelectedChoiceCanBeCleared() async throws {
        let source = Data("**Result (choose one):**\n\n- [ ] A\n- [ ] B\n".utf8)
        let (reader, url) = try await makeReader(source)
        XCTAssertEqual(try Data(contentsOf: url), source)
        XCTAssertTrue(reader.requestTaskChecked(0, checked: true))
        reader.confirmChecklistSaving(); try await settle(reader)
        let selected = try Data(contentsOf: url)
        XCTAssertNotEqual(selected, source)
        XCTAssertTrue(reader.requestTaskChecked(0, checked: false)); try await settle(reader)
        XCTAssertEqual(try Data(contentsOf: url), source)
        reader.undoChecklist(); try await settle(reader)
        XCTAssertEqual(try Data(contentsOf: url), selected)
        reader.redoChecklist(); try await settle(reader)
        XCTAssertEqual(try Data(contentsOf: url), source)
    }

    func testReadOnlyPreviewCannotOpenAnAnswerEditor() async throws {
        let original = Data("**Notes (short answer):** _Not answered_\n".utf8)
        let (reader, url) = try await makeReader(original)
        #if os(iOS)
        var preview = URLComponents(string: "margined://preview")!
        preview.queryItems = [.init(name: "text", value: String(decoding: original, as: UTF8.self))]
        await reader.openPreview(url: preview.url!)
        #else
        reader.fileURL = nil; reader.source = String(decoding: original, as: UTF8.self); reader.render()
        #endif
        try await settle(reader)
        XCTAssertFalse(reader.beginAnswer(0))
        XCTAssertNil(reader.answerDraft)
        XCTAssertFalse(reader.canSaveAnswer)
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    func testAnswerEditPreservesPostedDiscussionAndUsesItsOwnUndoHistory() async throws {
        let source = Data("**Notes (short answer):** Original\n\nPassage.\n".utf8)
        let (reader, url) = try await makeReader(source)
        reader.discussions.displayName = "Reviewer"
        let projection = try XCTUnwrap(reader.rendered?.discussionText)
        let selection = try XCTUnwrap(projection.selection((projection.text as NSString).range(of: "Passage."), renderID: "answer-history"))
        let key = try reader.discussions.beginDraft(selection, in: projection)
        reader.discussions.setDraft("Keep this saved discussion.", for: key)
        reader.postDiscussion(); try await settle(reader)
        let posted = try Data(contentsOf: url)
        let threads = try DiscussionCodec.parse(MarkdownSource.decode(posted)).threads
        XCTAssertEqual(threads.count, 1)
        XCTAssertTrue(reader.canUndoDiscussion)
        XCTAssertTrue(reader.beginAnswer(0))
        XCTAssertFalse(reader.canUndoDiscussion)
        try XCTUnwrap(reader.answerDraft).text = "Updated answer"
        reader.saveAnswer(); try await settle(reader)
        XCTAssertEqual(try DiscussionCodec.parse(MarkdownSource.decode(Data(contentsOf: url))).threads, threads)
        XCTAssertFalse(reader.canUndoDiscussion, "A response save invalidates the prior discussion write's snapshot")
        XCTAssertTrue(reader.canUndoChecklist)
        reader.undoChecklist(); try await settle(reader)
        XCTAssertEqual(try Data(contentsOf: url), posted)
    }

    private func makeReader(_ data: Data) async throws -> (ResponseTestReader, URL) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".md")
        try data.write(to: url)
        let reader = ResponseTestReader()
        #if os(iOS)
        await reader.open(url: url)
        #else
        reader.fileURL = url; reader.source = try MarkdownSource.decode(data); reader.render()
        #endif
        addTeardownBlock {
            #if os(iOS)
            await reader.close()
            #else
            await reader.stop()
            #endif
            try? FileManager.default.removeItem(at: url)
        }
        try await settle(reader)
        return (reader, url)
    }

    private func settle(_ reader: ResponseTestReader) async throws {
        #if os(iOS)
        await reader.waitForSaving(); await reader.waitForRendering()
        #endif
        try await waitUntil { !reader.fileSaving && !reader.isRendering }
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<400 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Reader state did not settle")
    }
}
