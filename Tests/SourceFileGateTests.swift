import Foundation
import XCTest
#if MARGINED_DISCUSSION_PROBE
#elseif os(iOS)
@testable import MarginediOS
#else
@testable import Margined
#endif

final class SourceFileGateTests: XCTestCase {
    // Async scheduling must not let Post overtake a tick, or Close drop an accepted write.
    func testAcceptedTickAndPostSerializeBeforeCloseAndRejectLaterOperations() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".md")
        try Data("- [ ] Task\n".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let initial = try SourceFileEdit.read(url), gate = SourceFileGate()
        let tick = gate.enqueue { try SourceFileEdit.setMarker(120, at: 3, was: 32, expected: initial) }
        // This Post was composed against the old snapshot, so it must fail after
        // the earlier tick, rather than dropping its checkmark to append a note.
        let stalePost = gate.enqueue { try SourceFileEdit.commit(Data("- [ ] Task\n\nNote.\n".utf8), expected: initial) }
        let closing = gate.close()
        let late = gate.enqueue { try SourceFileEdit.commit(Data("late".utf8), expected: initial) }
        let saved = try await tick.value()
        XCTAssertEqual(saved.data, Data("- [x] Task\n".utf8))
        do { _ = try await stalePost.value(); XCTFail("Post must use its exact composed snapshot") } catch { }
        try await closing.value()
        do { _ = try await late.value(); XCTFail("Close must stop acceptance") } catch { }
        XCTAssertEqual(try Data(contentsOf: url), Data("- [x] Task\n".utf8))
    }
}
