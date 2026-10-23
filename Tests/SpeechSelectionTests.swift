import XCTest
import SwiftSoup
@testable import Margined

final class SpeechSelectionTests: XCTestCase {
    func testSelectionMapsPastTaskStateAndInlineFormatting() async throws {
        try await assertStart("- [ ] A **bold** 👩🏽‍💻 ending\n", selected: "ending", expected: "ending")
    }

    func testSelectionMapsPastInsertedLinkDestinations() async throws {
        try await assertStart("Read [page](https://example.org/private) after.\n", selected: "after.", expected: "after.",
                              options: SpeechOptions(includeLinkDestinations: true))
    }

    func testSelectionInRepeatedTableValueSkipsColumnLabelsAndEarlierCell() async throws {
        try await assertStart("| State | Next |\n| --- | --- |\n| Ready | Ready |\n", selected: "Ready", expected: "Ready", last: true)
    }

    func testSelectionStillMapsThroughReviewHighlightWrappers() async throws {
        try await assertStart("A changed **word** ending.\n", selected: "ending.", expected: "ending.", baseline: "An old **word** ending.\n")
    }

    func testLongEmojiParagraphMapsIntoLaterUtteranceWithValidUTF16() async throws {
        let source = String(repeating: "書👩🏽‍💻読", count: 400) + " ending."
        try await assertStart(source, selected: "ending.", expected: "ending.")
    }

    func testInvalidSelectionCannotCreateAnOutOfBoundsUtterance() async throws {
        let output = try await MarkdownRenderer.shared.render("Text.", prepareSpeech: true)
        let document = try XCTUnwrap(output.speech)
        XCTAssertNil(document.position(elementID: "missing", sourceOffset: 0))
        XCTAssertNil(document.position(elementID: document.segments[0].elementID, sourceOffset: NSNotFound))
        XCTAssertNil(document.position(elementID: document.segments[0].elementID, sourceOffset: -1))
    }

    private func assertStart(_ source: String, selected: String, expected: String, last: Bool = false,
                             options: SpeechOptions = SpeechOptions(), baseline: String? = nil) async throws {
        let output = try await MarkdownRenderer.shared.render(source, baseline: baseline, prepareSpeech: true, speechOptions: options)
        let speech = try XCTUnwrap(output.speech), dom = try SwiftSoup.parse(output.html)
        let elements = try dom.select("[data-margined-speech]").array()
        let element = try XCTUnwrap(try elements.first(where: { try rawText($0).contains(selected) }))
        let raw = rawText(element) as NSString
        let location = raw.range(of: selected, options: last ? .backwards : []).location
        let position = try XCTUnwrap(speech.position(elementID: try element.attr("data-margined-speech"), sourceOffset: location))
        let text = speech.segments[position.index].text as NSString
        XCTAssertEqual(text.substring(from: position.offset), expected)
    }
    private func rawText(_ node: Node) -> String {
        if let text = node as? TextNode { return text.getWholeText() }
        return node.getChildNodes().map { rawText($0) }.joined()
    }
}
