import XCTest
import SwiftSoup
@testable import Margined

final class SpeechDocumentTests: XCTestCase {
    func testNestedTasksAreSpokenOnceInOrderWithTheirStates() async throws {
        let output = try await MarkdownRenderer.shared.render("# Plan\n\n- [ ] Parent\n  - Nested\n- [x] Done\n", prepareSpeech: true)
        let speech = try XCTUnwrap(output.speech)
        XCTAssertEqual(speech.segments.map(\.text), ["Plan", "Unchecked: Parent", "Nested", "Checked: Done"])
        XCTAssertEqual(speech.sections.map(\.title), ["Plan"])
        let dom = try SwiftSoup.parse(output.html)
        for segment in speech.segments {
            XCTAssertEqual(try dom.select("[data-margined-speech='\(segment.elementID)']").size(), 1)
        }
    }

    func testTablesReadColumnNamesAndValuesWithoutDuplicatingHeaders() async throws {
        let output = try await MarkdownRenderer.shared.render("| Item | Status |\n| --- | --- |\n| Alpha | Ready |\n| Beta | Waiting |\n", prepareSpeech: true)
        XCTAssertEqual(output.speech?.segments.map(\.text), ["Item: Alpha; Status: Ready", "Item: Beta; Status: Waiting"])
    }

    func testDefaultSpeechUsesVisibleLinksAndImageAlternativesAndSkipsCode() async throws {
        let source = "[Project](https://example.org/private) and ![A diagram](chart.png)\n\n```swift\nsecretImplementation()\n```\n"
        let output = try await MarkdownRenderer.shared.render(source, prepareSpeech: true)
        let spoken = try XCTUnwrap(output.speech).segments.map(\.text).joined(separator: " ")
        XCTAssertTrue(spoken.contains("Project and A diagram"))
        XCTAssertTrue(spoken.contains("Code block omitted"))
        XCTAssertFalse(spoken.contains("example.org"))
        XCTAssertFalse(spoken.contains("chart.png"))
        XCTAssertFalse(spoken.contains("secretImplementation"))
        let included = try await MarkdownRenderer.shared.render(source, prepareSpeech: true,
            speechOptions: SpeechOptions(includeCode: true, includeLinkDestinations: true))
        let full = try XCTUnwrap(included.speech).segments.map(\.text).joined(separator: " ")
        XCTAssertTrue(full.contains("https://example.org/private"))
        XCTAssertTrue(full.contains("secretImplementation()"))
    }

    func testUtteranceBoundaryKeepsExactTextAndOffsets() async throws {
        for length in [1_199, 1_200, 1_201] {
            let text = String(repeating: "a", count: length)
            let output = try await MarkdownRenderer.shared.render(text, documentLanguage: "en", prepareSpeech: true)
            let segments = try XCTUnwrap(output.speech).segments
            XCTAssertEqual(segments.map(\.text).joined(), text)
            XCTAssertEqual(segments.count, length <= 1_200 ? 1 : 2)
            XCTAssertEqual(segments.first?.elementOffset, 0)
            if segments.count == 2 { XCTAssertEqual(segments[1].elementOffset, 1_200) }
        }
        let unicode = String(repeating: "Café 👩🏽‍💻 漢字 ", count: 20).trimmingCharacters(in: .whitespaces)
        let output = try await MarkdownRenderer.shared.render(unicode, documentLanguage: "en", prepareSpeech: true)
        let segments = try XCTUnwrap(output.speech).segments
        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments.first?.text, unicode)
        XCTAssertEqual(segments.first?.elementOffset, 0)
    }

    func testLongUnicodeBlocksStayBoundedWithoutLosingCharacters() async throws {
        let text = String(repeating: "書👩🏽‍💻読", count: 1000)
        let output = try await MarkdownRenderer.shared.render(text, prepareSpeech: true)
        let speech = try XCTUnwrap(output.speech)
        XCTAssertGreaterThan(speech.segments.count, 1)
        XCTAssertTrue(speech.segments.allSatisfy { $0.text.utf16.count <= 1200 })
        XCTAssertEqual(speech.segments.map(\.text).joined(), text)
    }

    func testSpeechMetadataIsOptionalAndCannotContainActiveHTML() async throws {
        let normal = try await MarkdownRenderer.shared.render("Plain")
        XCTAssertNil(normal.speech, "Quick Look should not prepare a playback document")
        let source = "# Safe\n\n<script>alert('hidden')</script>\n\nVisible.\n"
        let output = try await MarkdownRenderer.shared.render(source, prepareSpeech: true)
        XCTAssertEqual(output.speech?.segments.map(\.text), ["Safe", "Visible."])
        XCTAssertFalse(output.html.contains("<script>"))
    }

    func testContentFingerprintChangesWithSourceButNotAppearance() async throws {
        let first = try await MarkdownRenderer.shared.render("Text", prepareSpeech: true)
        let dark = try await MarkdownRenderer.shared.render("Text", appearance: .dark, prepareSpeech: true)
        let edit = try await MarkdownRenderer.shared.render("Edited", prepareSpeech: true)
        XCTAssertEqual(first.speech?.fingerprint, dark.speech?.fingerprint)
        XCTAssertNotEqual(first.speech?.fingerprint, edit.speech?.fingerprint)
    }
    func testSpeechMetadataNeverCreatesReviewChanges() async throws {
        let source = "# Notes\n\n- Parent\n  - Nested\n\n| A | B |\n| --- | --- |\n| one | two |\n"
        let output = try await MarkdownRenderer.shared.render(source, baseline: source, prepareSpeech: true)
        XCTAssertEqual(output.changes.count, 0, String(reflecting: output.changes))
    }

    func testNestedParagraphsAndFootnotesAreNotReadTwice() async throws {
        let source = "A reference[^1].\n\n[^1]: Footnote content.\n\n> Quoted text.\n"
        let output = try await MarkdownRenderer.shared.render(source, prepareSpeech: true)
        let spoken = try XCTUnwrap(output.speech).segments.map(\.text).joined(separator: " ")
        XCTAssertEqual(spoken.components(separatedBy: "Footnote content.").count - 1, 1)
        XCTAssertEqual(spoken.components(separatedBy: "Quoted text.").count - 1, 1)
        XCTAssertFalse(spoken.contains("↩"))
    }

    func testLongProseUsesSentenceBoundariesBeforeSplittingWords() async throws {
        let text = String(repeating: "A simple sentence. ", count: 120).trimmingCharacters(in: .whitespaces)
        let output = try await MarkdownRenderer.shared.render(text, prepareSpeech: true)
        let segments = try XCTUnwrap(output.speech).segments
        XCTAssertGreaterThan(segments.count, 1)
        XCTAssertTrue(segments.allSatisfy { $0.text.trimmingCharacters(in: .whitespaces).hasSuffix(".") })
        XCTAssertEqual(segments.map(\.text).joined(), text)
    }

    func testChineseSemanticCuesFollowDocumentScript() async throws {
        let source = "- [ ] 閱讀\n\n```\ncode\n```\n"
        let output = try await MarkdownRenderer.shared.render(source, documentLanguage: "zh-Hant", prepareSpeech: true)
        XCTAssertTrue(output.speech!.segments.map(\.text).joined().contains("略過程式碼區塊"))
    }
    func testNestedBlocksPreserveOrderAndSpeechOptions() async throws {
        let source = "- [ ] Parent\n\n  ```swift\n  secretCode()\n  ```\n\n  - Child\n\n  After child.\n\n  | Item | State |\n  | --- | --- |\n  | Alpha | Ready |\n"
        let output = try await MarkdownRenderer.shared.render(source, prepareSpeech: true)
        let segments = output.speech!.segments.map(\.text)
        let spoken = segments.joined(separator: " ")
        XCTAssertEqual(segments.first, "Unchecked: Parent")
        XCTAssertFalse(spoken.contains("secretCode"))
        XCTAssertTrue(spoken.contains("Code block omitted"))
        XCTAssertTrue(segments.contains("Item: Alpha; State: Ready"), spoken)
        XCTAssertLessThan(try XCTUnwrap(spoken.range(of: "Child")?.lowerBound), try XCTUnwrap(spoken.range(of: "After child")?.lowerBound))
        let included = try await MarkdownRenderer.shared.render(source, prepareSpeech: true, speechOptions: SpeechOptions(includeCode: true))
        XCTAssertTrue(included.speech!.segments.map(\.text).joined().contains("secretCode()"))
    }

}
