import Foundation
import XCTest
#if os(iOS)
@testable import MarginediOS
#else
@testable import Margined
#endif

final class ViewingBenchmarkMetricsTests: XCTestCase {
    func testSessionReadsOnlyItsRegularSyntheticFixture() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let text = "# MARGINED-BENCHMARK-PROSE-000\n\nA reading fixture.\n"
        try text.write(to: root.appendingPathComponent("fixture.md"), atomically: true, encoding: .utf8)
        let request = ViewingBenchmarkRequest(version: 1, kind: .warm, sourceFile: "fixture.md",
            expectedMarker: "MARGINED-BENCHMARK-PROSE-000", sampleCount: 20)
        let source = try request.validatedSource(manifestURL: root.appendingPathComponent("request.json"))
        XCTAssertEqual(source.text, text)
        XCTAssertEqual(source.url.lastPathComponent, "fixture.md")
    }

    func testUnsafeOrUnverifiableRequestsCannotStart() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "# MARGINED-BENCHMARK-TEST\n".write(to: root.appendingPathComponent("fixture.md"), atomically: true, encoding: .utf8)
        let manifest = root.appendingPathComponent("request.json")
        for (version, file, marker, count) in [(2,"fixture.md","MARGINED-BENCHMARK-TEST",1),
            (1,"../fixture.md","MARGINED-BENCHMARK-TEST",1),
            (1,"/tmp/fixture.md","MARGINED-BENCHMARK-TEST",1),
            (1,"fixture.md","MARGINED-BENCHMARK-ABSENT",1),
            (1,"fixture.md","",1), (1,"fixture.md","MARGINED-BENCHMARK-TEST",0),
            (1,"fixture.md","MARGINED-BENCHMARK-TEST",101)] {
            let request = ViewingBenchmarkRequest(version: version, kind: .warm, sourceFile: file,
                expectedMarker: marker, sampleCount: count)
            XCTAssertThrowsError(try request.validatedSource(manifestURL: manifest))
        }
    }

    func testSymlinkCannotEscapeSessionDirectory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".md")
        defer { try? FileManager.default.removeItem(at: outside) }
        try "# MARGINED-BENCHMARK-OUTSIDE\n".write(to: outside, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("fixture.md"), withDestinationURL: outside)
        let request = ViewingBenchmarkRequest(version: 1, kind: .cold, sourceFile: "fixture.md",
            expectedMarker: "MARGINED-BENCHMARK-OUTSIDE", sampleCount: 1)
        XCTAssertThrowsError(try request.validatedSource(manifestURL: root.appendingPathComponent("request.json")))
    }

    func testBenchmarkConversationsAttachToTheirReadablePassage() async throws {
        let bundle = Bundle(for: ViewingBenchmarkMetricsTests.self)
        for (name, threadCount, messageCount) in [("annotated", 20, 80), ("long-discussion", 1, 120)] {
            let url = try XCTUnwrap(bundle.url(forResource: name + "-benchmark", withExtension: "md"))
            let source = try String(contentsOf: url, encoding: .utf8)
            let output = try await MarkdownRenderer.shared.render(source)
            let document = try XCTUnwrap(output.discussions)
            let projection = try XCTUnwrap(output.discussionText)
            XCTAssertTrue(document.diagnostics.isEmpty, name)
            XCTAssertEqual(document.threads.count, threadCount, name)
            XCTAssertEqual(document.threads.reduce(0) { $0 + $1.messages.count }, messageCount, name)
            XCTAssertEqual(projection.anchorResults.values.filter { $0.status == .attached }.count,
                           threadCount, "The timed fixture must include attached conversations: " + name)
            for thread in document.threads where projection.anchorResults[thread.id]?.status == .attached {
                let range = try XCTUnwrap(projection.anchorResults[thread.id]?.range)
                XCTAssertEqual((projection.text as NSString).substring(with: range), thread.target.exact)
            }
        }
    }

    func testMonotonicStagesProduceSeparateMillisecondDurations() throws {
        let value = try ViewingBenchmarkMeasurement(index: 0, pid: 42, requestNS: 1_000_000,
            renderReadyNS: 4_000_000, frameNS: 9_500_000)
        XCTAssertEqual(value.renderMilliseconds, 3)
        XCTAssertEqual(value.frameMilliseconds, 8.5)
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as! [String: Any]
        XCTAssertEqual(encoded["request_ns"] as? Int, 1_000_000)
        XCTAssertEqual(encoded["frame_ns"] as? Int, 9_500_000)
    }

    func testInvalidStageOrderingCannotBecomeAFastSample() {
        let invalid: [(UInt64, UInt64, UInt64)] = [(0,2,3), (3,2,4), (1,4,3)]
        for (start, ready, frame) in invalid {
            XCTAssertThrowsError(try ViewingBenchmarkMeasurement(index: 0, pid: 42,
                requestNS: start, renderReadyNS: ready, frameNS: frame))
        }
    }
}
