import Foundation
import SwiftSoup
import XCTest
#if os(iOS)
@testable import MarginediOS
#else
@testable import Margined
#endif

final class MarkdownResponseTests: XCTestCase {
    func testExplicitTopLevelQuestionsMapToTheirOwnControls() async throws {
        let source = """
        **Result (choose one):**

        - [ ] Accepted
        - [X] Changes required

        **Device and OS (short answer):** _Not answered_

        **Notes (short answer):** A **bold** observation with `code`.

        - [ ] Independent
        """
        let output = try await MarkdownRenderer.shared.render(source, mapTasks: true)
        let document = try SwiftSoup.parse(output.html)
        XCTAssertEqual(try document.select("ul[data-margined-choice]").size(), 1)
        XCTAssertEqual(try document.select("input[data-margined-choice]").size(), 2)
        XCTAssertEqual(try document.select("p[data-margined-answer]").size(), 2)
        XCTAssertEqual(output.tasks.count, 3)
        XCTAssertEqual(try document.select("ul[data-margined-choice]").attr("aria-label"), "Result (choose one)")
    }

    func testConflictingImportedChoicesAreMarkedWithoutChangingTheirState() async throws {
        let source = "**Result (choose one):**\n\n- [x] A\n- [X] B\n"
        let output = try await MarkdownRenderer.shared.render(source, mapTasks: true)
        let document = try SwiftSoup.parse(output.html)
        XCTAssertEqual(try document.select("ul[data-margined-choice][aria-invalid=true]").size(), 1)
        XCTAssertEqual(output.tasks.map(\.marker), [120, 88])
        XCTAssertEqual(output.taskSource, source)
    }

    func testOrdinaryAndUnsupportedSourceNeverOptsIn() async throws {
        let sources = [
            "**Result:**\n\n- [ ] A\n- [ ] B\n",
            "**Result (Choose one):**\n\n- [ ] A\n- [ ] B\n",
            "**Result (choose one):**\n\nIntervening prose.\n\n- [ ] A\n- [ ] B\n",
            "**Result (choose one):**\n\n- [ ] A\n- Ordinary\n",
            "**Result (choose one):**\n\n1. [ ] A\n2. [ ] B\n",
            "**Result (choose one):**\n\n- [ ] A\n  - [ ] Nested\n- [ ] B\n",
            "> **Result (choose one):**\n>\n> - [ ] A\n> - [ ] B\n",
            "```markdown\n**Result (choose one):**\n\n- [ ] A\n- [ ] B\n\n**Notes (short answer):** Value\n```\n",
            "**Ordinary label:** Value\n",
            "**Notes (short answer):** A value\non another line\n",
            "> **Notes (short answer):** Value\n",
            "- **Notes (short answer):** Value\n",
            "<div>\n\n**Notes (short answer):** Value\n\n</div>\n",
            "| Question | Answer |\n| --- | --- |\n| **Notes (short answer):** Value | Other |\n"
        ]
        for source in sources {
            let output = try await MarkdownRenderer.shared.render(source, mapTasks: true)
            let document = try SwiftSoup.parse(output.html)
            XCTAssertEqual(try document.select("[data-margined-choice], [data-margined-answer]").size(), 0, source)
        }
    }

    func testReadOnlyOutputDoesNotGainResponseControls() async throws {
        let source = "**Result (choose one):**\n\n- [x] A\n- [x] B\n\n**Notes (short answer):** Value\n"
        let output = try await MarkdownRenderer.shared.render(source)
        let document = try SwiftSoup.parse(output.html)
        XCTAssertEqual(try document.select("[data-margined-choice], [data-margined-answer]").size(), 0)
        XCTAssertTrue(try document.text().contains("Notes (short answer): Value"))
    }

    func testPlainPunctuationLabelsAndDuplicateQuestionsHaveDistinctMappings() async throws {
        for label in ["Device_OS [test]", "Device  OS"] {
            let source = "**\(label) (short answer):** One\n\n**\(label) (short answer):** One\n"
            let output = try await MarkdownRenderer.shared.render(source, mapTasks: true)
            XCTAssertEqual(output.responses.answers.count, 2, label)
            XCTAssertEqual(Set(output.responses.answers.map(\.range)).count, 2)
            XCTAssertEqual(output.responses.answers.map(\.plainValue), ["One", "One"])
        }
        let styled = try await MarkdownRenderer.shared.render("**A *styled* label (short answer):** One\n", mapTasks: true)
        XCTAssertTrue(styled.responses.answers.isEmpty)
    }

    func testAuthorHTMLLookalikeCannotStealATextField() async throws {
        let source = "<p><strong>Notes (short answer):</strong> Value</p>\n\n**Notes (short answer):** Value\n"
        let output = try await MarkdownRenderer.shared.render(source, mapTasks: true)
        XCTAssertTrue(output.responses.answers.isEmpty)
    }

    func testGroupSwitchClearAndConflictResolutionAreOneReversibleEdit() async throws {
        let source = "**Result (choose one):**\n\n- [X] A\n- [ ] B\n"
        let output = try await MarkdownRenderer.shared.render(source, mapTasks: true)
        let group = try XCTUnwrap(output.responses.choices.first)
        let edit = try MarkdownResponses.choiceEdit(source: source, group: group, taskID: 1, checked: true)
        let changed = "**Result (choose one):**\n\n- [ ] A\n- [x] B\n"
        XCTAssertEqual(try edit.apply(to: Data(source.utf8)), Data(changed.utf8))
        XCTAssertEqual(try edit.inverse().apply(to: Data(changed.utf8)), Data(source.utf8))
        let updated = try await MarkdownRenderer.shared.render(changed, mapTasks: true)
        let clear = try MarkdownResponses.choiceEdit(source: changed, group: XCTUnwrap(updated.responses.choices.first), taskID: 1, checked: false)
        XCTAssertEqual(try clear.apply(to: Data(changed.utf8)), Data(changed.replacingOccurrences(of: "[x]", with: "[ ]").utf8))
        let conflict = source.replacingOccurrences(of: "[ ] B", with: "[x] B")
        let imported = try await MarkdownRenderer.shared.render(conflict, mapTasks: true)
        let resolve = try MarkdownResponses.choiceEdit(source: conflict, group: XCTUnwrap(imported.responses.choices.first), taskID: 0, checked: false)
        XCTAssertEqual(try resolve.apply(to: Data(conflict.utf8)), Data(source.utf8), "Clicking a checked conflicting choice selects it alone")
        XCTAssertEqual(try resolve.inverse().apply(to: Data(source.utf8)), Data(conflict.utf8))
        XCTAssertThrowsError(try MarkdownResponses.choiceEdit(source: source, group: group, taskID: 999, checked: true))
    }

    func testTextReplacementEscapesMarkdownAndRoundTripsLiteralUnicode() async throws {
        let source = "**Notes (short answer):** _Not answered_\n"
        let output = try await MarkdownRenderer.shared.render(source, mapTasks: true)
        let field = try XCTUnwrap(output.responses.answers.first)
        let text = "Café 日本語 🐈 — `a | b`, <script>text</script>, [link](https://example.com), **bold**, &copy;, $x$, ~~no~~, user@example.com"
        let edit = try MarkdownResponses.answerEdit(source: source, field: field, text: text)
        let changed = try edit.apply(to: Data(source.utf8))
        let rendered = try await MarkdownRenderer.shared.render(MarkdownSource.decode(changed), mapTasks: true)
        XCTAssertEqual(rendered.responses.answers.first?.plainValue, text, String(decoding: changed, as: UTF8.self) + "\n" + rendered.html)
        let doc = try SwiftSoup.parse(rendered.html)
        let unexpected = try doc.select("a, script, del, code")
        let unexpectedHTML = try unexpected.outerHtml()
        XCTAssertEqual(unexpected.size(), 0, unexpectedHTML)
        XCTAssertEqual(try edit.inverse().apply(to: changed), Data(source.utf8))
    }

    func testAnswerNoOpPreservesFormattingAndEmptyRestoresPlaceholder() async throws {
        let source = "**Notes (short answer):** A **bold** observation with `code`.\n"
        let output = try await MarkdownRenderer.shared.render(source, mapTasks: true)
        let field = try XCTUnwrap(output.responses.answers.first)
        let unchanged = try MarkdownResponses.answerEdit(source: source, field: field, text: field.plainValue)
        XCTAssertEqual(try unchanged.apply(to: Data(source.utf8)), Data(source.utf8))
        let empty = try MarkdownResponses.answerEdit(source: source, field: field, text: "   ")
        XCTAssertEqual(try empty.apply(to: Data(source.utf8)), Data("**Notes (short answer):** _Not answered_\n".utf8))
        for text in ["line\nbreak", "line\rbreak", "line\u{2028}break", "nul\u{0}text", "bell\u{7}text", String(repeating: "é", count: 1001)] {
            XCTAssertThrowsError(try MarkdownResponses.answerEdit(source: source, field: field, text: text), text)
        }
        let maximum = try MarkdownResponses.answerEdit(source: source, field: field, text: String(repeating: "🐈", count: 1000))
        XCTAssertFalse(try maximum.apply(to: Data(source.utf8)).isEmpty)
    }

    func testEncodedAnswerAndGroupEditsPreserveDiscussionMetadataAndExactInverse() async throws {
        let prose = "# café 🐈\n\n**Result (choose one):**\n\n- [X] A\n- [ ] B\n\n**Notes (short answer):** _Not answered_\n\nPassage.\n"
        let thread = DiscussionThread(id: "t-response-preserve", state: .open,
            target: .init(type: "TextQuoteSelector", exact: "Passage.", prefix: "", suffix: "", section: ""),
            messages: [.init(id: "m-response-preserve", author: "Reviewer", created: "2026-11-06T00:00:00Z", body: "Keep this discussion.", inReplyTo: nil)],
            resolvedBy: nil, resolved: nil, attachmentHistory: [])
        let bytes = try MarkdownSourceEdits.apply(DiscussionEdits.splices(for: .newThread(thread), in: DiscussionCodec.parse(prose)), to: Data(prose.utf8), expectedSource: prose)
        let source = try MarkdownSource.decode(bytes).replacingOccurrences(of: "\n", with: "\r\n")
        let output = try await MarkdownRenderer.shared.render(source, mapTasks: true)
        let groupEdit = try MarkdownResponses.choiceEdit(source: source, group: XCTUnwrap(output.responses.choices.first), taskID: 1, checked: true)
        let answerEdit = try MarkdownResponses.answerEdit(source: source, field: XCTUnwrap(output.responses.answers.first), text: "日本語 answer")
        let originals = [Data(source.utf8), Data([239, 187, 191]) + Data(source.utf8),
                         Data([255, 254]) + source.data(using: .utf16LittleEndian)!,
                         Data([254, 255]) + source.data(using: .utf16BigEndian)!]
        for original in originals {
            for edit in [groupEdit, answerEdit] {
                let changed = try edit.apply(to: original)
                XCTAssertNotEqual(changed, original)
                XCTAssertEqual(try edit.inverse().apply(to: changed), original)
                XCTAssertEqual(try DiscussionCodec.parse(MarkdownSource.decode(changed)).threads, [thread])
            }
        }
        XCTAssertThrowsError(try answerEdit.apply(to: Data(source.replacingOccurrences(of: "Passage.", with: "New passage.").utf8)))
        XCTAssertThrowsError(try answerEdit.apply(to: Data(source.replacingOccurrences(of: "café", with: "cafe\u{301}").utf8)))
    }

    func testLiteralAnswersRetainInternalWhitespaceAndDecomposedUnicode() async throws {
        let source = "**Notes (short answer):** _Not answered_\n"
        let output = try await MarkdownRenderer.shared.render(source, mapTasks: true)
        let field = try XCTUnwrap(output.responses.answers.first)
        let text = "Two  spaces\tand cafe\u{301} :smile: www.example.com __literal__ ++plus++ ==equals== ^up^"
        let edit = try MarkdownResponses.answerEdit(source: source, field: field, text: text)
        let changed = try edit.apply(to: Data(source.utf8))
        for editable in [false, true] {
            let rendered = try await MarkdownRenderer.shared.render(MarkdownSource.decode(changed), mapTasks: editable)
            let doc = try SwiftSoup.parse(rendered.html)
            XCTAssertEqual(try doc.select("a, em, del, code, sup, sub, ins, mark").size(), 0, rendered.html)
            if editable {
                let value = try XCTUnwrap(rendered.responses.answers.first?.plainValue)
                XCTAssertEqual(Array(value.utf8), Array(text.utf8))
            }
        }
    }

    func testExplicitExternalLinkFormattingRemainsReadableAndAnUnchangedSaveIsExact() async throws {
        let source = "**Notes (short answer):** Read [the reference](https://example.com/).\n"
        let output = try await MarkdownRenderer.shared.render(source, mapTasks: true)
        XCTAssertEqual(try SwiftSoup.parse(output.html).select("a").size(), 1)
        let field = try XCTUnwrap(output.responses.answers.first)
        let edit = try MarkdownResponses.answerEdit(source: source, field: field, text: field.plainValue)
        XCTAssertEqual(try edit.apply(to: Data(source.utf8)), Data(source.utf8))
    }

    func testManyDuplicateQuestionsRetainDistinctExactMappings() async throws {
        let source = (0..<100).map { _ in "**Result (choose one):**\n\n- [ ] A\n- [ ] B\n\n" }.joined()
        let output = try await MarkdownRenderer.shared.render(source, mapTasks: true)
        XCTAssertEqual(output.responses.choices.count, 100)
        XCTAssertEqual(output.responses.choices.flatMap(\.tasks).map(\.id), Array(0..<200))
    }

    func testChangedAnswerRemainsMappedThroughWordReviewAndSpeechMarkers() async throws {
        let before = "**Notes (short answer):** A **bold** observation.\n"
        let initial = try await MarkdownRenderer.shared.render(before, mapTasks: true)
        let field = try XCTUnwrap(initial.responses.answers.first)
        let text = "New **literal** text, Café 日本語"
        let edit = try MarkdownResponses.answerEdit(source: before, field: field, text: text)
        let source = try MarkdownSource.decode(edit.apply(to: Data(before.utf8)))
        let output = try await MarkdownRenderer.shared.render(source, baseline: before, mapTasks: true, prepareSpeech: true)
        XCTAssertEqual(output.responses.answers.first?.plainValue, text)
        XCTAssertEqual(output.changes.count, 1)
    }
}
