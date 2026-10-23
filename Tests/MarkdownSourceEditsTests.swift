import Foundation
import XCTest
#if MARGINED_DISCUSSION_PROBE
#elseif os(iOS)
@testable import MarginediOS
#else
@testable import Margined
#endif

final class MarkdownSourceEditsTests: XCTestCase {
    // Re-encoding to UTF-8 or normalizing newlines would corrupt these source files.
    func testSplicesPreserveEncodingBOMAndUnrelatedBytes() throws {
        let source = "# café 🐈\r\n\r\nBefore.\r\n"
        let after = "# café 🐈\r\n\r\nAfter 日本.\r\n"
        let lower = Array(source.utf8).count - 9
        let edit = MarkdownSourceSplice(range: lower..<(lower + 7), replacement: "After 日本.")
        let fixtures: [(Data, Data)] = [
            (Data(source.utf8), Data(after.utf8)),
            (Data([239,187,191]) + Data(source.utf8), Data([239,187,191]) + Data(after.utf8)),
            (Data([255,254]) + source.data(using: .utf16LittleEndian)!, Data([255,254]) + after.data(using: .utf16LittleEndian)!),
            (Data([254,255]) + source.data(using: .utf16BigEndian)!, Data([254,255]) + after.data(using: .utf16BigEndian)!)
        ]
        for (original, expected) in fixtures {
            XCTAssertEqual(try MarkdownSourceEdits.apply([edit], to: original, expectedSource: source), expected)
        }
    }

    func testMultipleOriginalOffsetsApplyWithoutShiftingLaterEdits() throws {
        let source = "abc\r\ndef\r\n"
        let edits: [MarkdownSourceSplice] = [.init(range: 5..<8, replacement: "longer"), .init(range: 0..<0, replacement: "# "), .init(range: 1..<2, replacement: "")]
        XCTAssertEqual(try MarkdownSourceEdits.apply(edits, to: Data(source.utf8), expectedSource: source), Data("# ac\r\nlonger\r\n".utf8))
    }

    func testRejectsStaleSourceOverlapsAndMidScalarOffsets() throws {
        let source = "🐈 text"
        let invalid: [[MarkdownSourceSplice]] = [
            [.init(range: 1..<2, replacement: "x")],
            [.init(range: 0..<4, replacement: "x"), .init(range: 3..<5, replacement: "y")],
            [.init(range: 20..<20, replacement: "x")],
            [.init(range: 0..<0, replacement: "x"), .init(range: 0..<0, replacement: "y")]
        ]
        for edits in invalid { XCTAssertThrowsError(try MarkdownSourceEdits.apply(edits, to: Data(source.utf8), expectedSource: source)) }
        XCTAssertThrowsError(try MarkdownSourceEdits.apply([], to: Data(source.utf8), expectedSource: "other"))
        // Swift String equality folds canonically equivalent Unicode. File snapshots must not.
        XCTAssertThrowsError(try MarkdownSourceEdits.apply([], to: Data("cafe\u{301}".utf8), expectedSource: "café"))
    }

    func testNoOpIsByteExactAndOversizedCandidateIsRejected() throws {
        let source = "\u{feff}body\r\n"
        let original = Data([239,187,191]) + Data(source.utf8)
        XCTAssertEqual(try MarkdownSourceEdits.apply([], to: original, expectedSource: source), original)
        for (bom, encoding) in [(Data([255,254]), String.Encoding.utf16LittleEndian), (Data([254,255]), .utf16BigEndian)] {
            let encoded = bom + source.data(using: encoding)!
            XCTAssertEqual(try MarkdownSource.decode(encoded), source)
            XCTAssertEqual(try MarkdownSourceEdits.apply([], to: encoded, expectedSource: source), encoded)
        }
        XCTAssertThrowsError(try MarkdownSourceEdits.apply([.init(range: 0..<0, replacement: String(repeating: "x", count: MarkdownSource.maximumBytes))], to: original, expectedSource: source))
    }
}
