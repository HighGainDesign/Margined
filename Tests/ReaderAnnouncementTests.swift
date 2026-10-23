import XCTest
@testable import Margined

@MainActor
final class ReaderAnnouncementTests: XCTestCase {
    func testRapidUpdatesCoalesceAndResolvedSearchDoesNotSpeak() async throws {
        var spoken:[String] = []
        let announcements = ReaderAnnouncements(delay:.milliseconds(20)) { spoken.append($0) }
        announcements.isEligible = { true }
        announcements.schedule("One change",topic:.changes)
        announcements.schedule("Two changes",topic:.changes)
        announcements.schedule("No matches",topic:.search)
        announcements.cancel(topic:.search)
        for _ in 0..<100 where spoken.isEmpty { try await Task.sleep(for:.milliseconds(10)) }
        XCTAssertEqual(spoken,["Two changes"])
    }

    func testInactiveClosedAndNoLongerActiveReadersStaySilent() async throws {
        var spoken:[String] = [], active = false
        let announcements = ReaderAnnouncements(delay:.milliseconds(20)) { spoken.append($0) }
        announcements.isEligible = { active }
        announcements.schedule("Background update",topic:.changes)
        active = true
        try await Task.sleep(for:.milliseconds(60))
        XCTAssertTrue(spoken.isEmpty,"Background events must not be replayed when a reader becomes active")
        announcements.schedule("Previous reader update",topic:.changes)
        active = false
        try await Task.sleep(for:.milliseconds(60))
        XCTAssertTrue(spoken.isEmpty)
        active = true
        announcements.schedule("Closing reader",topic:.failure)
        announcements.cancel()
        try await Task.sleep(for:.milliseconds(60))
        XCTAssertTrue(spoken.isEmpty)
    }

    func testFailuresRemainAheadOfCoalescedReviewProgress() async throws {
        var spoken:[String] = []
        let announcements = ReaderAnnouncements(delay:.milliseconds(20)) { spoken.append($0) }
        announcements.isEligible = { true }
        announcements.schedule("Three changes",topic:.changes)
        announcements.schedule("Two remaining",topic:.review)
        announcements.schedule("Checkbox could not be saved",topic:.failure)
        for _ in 0..<100 where spoken.isEmpty { try await Task.sleep(for:.milliseconds(10)) }
        XCTAssertEqual(spoken,["Checkbox could not be saved\nTwo remaining"])
    }

    func testReaderAnnouncesResultsWithoutReadingDocumentContents() async throws {
        var spoken:[String] = []
        let announcements = ReaderAnnouncements(delay:.milliseconds(20)) { spoken.append($0) }
        announcements.isEligible = { true }
        let reader = ReaderState(announcements:announcements)
        reader.fileURL = URL(fileURLWithPath:"/tmp/announcements.md")
        reader.source = "Original confidential paragraph."
        reader.render(); try await settle(reader)
        try await Task.sleep(for:.milliseconds(60))
        XCTAssertTrue(spoken.isEmpty,"Opening a document should not announce its full contents")
        reader.acceptFileUpdate("Changed confidential paragraph.")
        try await settle(reader)
        for _ in 0..<100 where spoken.isEmpty { try await Task.sleep(for:.milliseconds(10)) }
        XCTAssertTrue(spoken.joined().contains("1"))
        XCTAssertFalse(spoken.joined().contains("confidential"))
        spoken.removeAll()
        reader.searchText = "missing"; reader.searchFound = false
        for _ in 0..<100 where spoken.isEmpty { try await Task.sleep(for:.milliseconds(10)) }
        XCTAssertTrue(spoken.joined().localizedCaseInsensitiveContains("no matches"))
        spoken.removeAll()
        reader.checklistError = "File changed before saving"
        for _ in 0..<100 where spoken.isEmpty { try await Task.sleep(for:.milliseconds(10)) }
        XCTAssertTrue(spoken.joined().contains("File changed before saving"))
        reader.stop()
    }

    func testIndividualReviewAnnouncesRemainingCountThenCompletion() async throws {
        var spoken:[String] = []
        let announcements = ReaderAnnouncements(delay:.milliseconds(20)) { spoken.append($0) }
        announcements.isEligible = { true }
        let reader = ReaderState(announcements:announcements)
        reader.fileURL = URL(fileURLWithPath:"/tmp/review-speech.md")
        reader.source = "Old first.\n\nOld second."
        reader.acceptFileUpdate("New first.\n\nNew second.")
        try await settle(reader)
        for _ in 0..<100 where spoken.isEmpty { try await Task.sleep(for:.milliseconds(10)) }
        spoken.removeAll()
        reader.markCurrentChangeReviewed(); try await settle(reader)
        for _ in 0..<100 where spoken.isEmpty { try await Task.sleep(for:.milliseconds(10)) }
        XCTAssertTrue(spoken.joined().contains("1 change remaining"))
        XCTAssertEqual(reader.selectedChange?.after,"New second.")
        spoken.removeAll()
        reader.markCurrentChangeReviewed(); try await settle(reader)
        for _ in 0..<100 where spoken.isEmpty { try await Task.sleep(for:.milliseconds(10)) }
        XCTAssertTrue(spoken.joined().contains("All changes reviewed"))
        XCTAssertEqual(reader.source,"New first.\n\nNew second.")
        reader.stop()
    }

    func testActualStaleSaveAnnouncesConflictAndKeepsAgentChanges() async throws {
        var spoken:[String] = []
        let announcements = ReaderAnnouncements(delay:.milliseconds(20)) { spoken.append($0) }
        announcements.isEligible = { true }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".md")
        defer { try? FileManager.default.removeItem(at:file) }
        let reader = ReaderState(announcements:announcements)
        reader.fileURL = file; reader.source = "- [ ] Original\n"
        try reader.source.write(to:file,atomically:true,encoding:.utf8)
        reader.render(); try await settle(reader); reader.checklistMode = true
        try "- [ ] Agent replacement\n".write(to:file,atomically:true,encoding:.utf8)
        reader.setTaskChecked(0,checked:true)
        for _ in 0..<200 {
            if !reader.checklistSaving, reader.source == "- [ ] Agent replacement\n", !spoken.isEmpty { break }
            try await Task.sleep(for:.milliseconds(10))
        }
        XCTAssertTrue(spoken.joined().localizedCaseInsensitiveContains("file changed"))
        XCTAssertEqual(try MarkdownSource.read(file),"- [ ] Agent replacement\n")
        reader.stop()
    }

    func testReadAloudSuppressesRoutineProgressButKeepsFailuresDiscoverable() async throws {
        var spoken: [String] = []
        let announcements = ReaderAnnouncements(delay: .milliseconds(20)) { spoken.append($0) }
        announcements.isEligible = { true }
        announcements.schedule("Old queued update", topic: .changes)
        announcements.suppressRoutine = true
        announcements.schedule("New routine update", topic: .updates)
        announcements.schedule("Save failed", topic: .saveFailure)
        for _ in 0..<100 where spoken.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(spoken, ["Save failed"])
        announcements.suppressRoutine = false
        announcements.schedule("All changes reviewed", topic: .review)
        for _ in 0..<100 where spoken.count < 2 { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(spoken.last, "All changes reviewed")
    }

    private func settle(_ reader:ReaderState) async throws {
        for _ in 0..<200 {
            if !reader.isRendering { return }
            try await Task.sleep(for:.milliseconds(10))
        }
        XCTFail("Render did not finish")
    }
}
