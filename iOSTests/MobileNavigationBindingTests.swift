import SwiftUI
import XCTest
@testable import MarginediOS

@MainActor
final class MobileNavigationBindingTests: XCTestCase {
    func testAnOldCompactBindingCannotClearAReplyAfterAMarginRoundTrip() async throws {
        let (reader, _) = try await fixture()
        let workspace = MobileDocumentWorkspace(reader: reader, openFolder: {}, closeFile: {})
        reader.openDiscussion("t-binding")
        reader.discussions.setDraft("Keep my unposted reply.", for: .thread("t-binding"))
        let old = workspace.navigationBinding()
        reader.discussionUsesMargin = true
        reader.discussionUsesMargin = false
        old.wrappedValue = []
        XCTAssertEqual(reader.discussionRoute, .thread("t-binding"),
                       "A queued native update from the previous presentation cannot dismiss the retained conversation")
        XCTAssertEqual(reader.inspector, .discussions)
        XCTAssertEqual(reader.discussions.drafts[.thread("t-binding")]?.body, "Keep my unposted reply.")
    }

    func testTheCurrentCompactBindingStillHonorsNativeBack() async throws {
        let (reader, _) = try await fixture()
        let workspace = MobileDocumentWorkspace(reader: reader, openFolder: {}, closeFile: {})
        reader.openDiscussion("t-binding")
        reader.discussionUsesMargin = true
        reader.discussionUsesMargin = false
        workspace.navigationBinding().wrappedValue = [.list]
        XCTAssertNil(reader.discussionRoute)
        XCTAssertEqual(reader.inspector, .discussions)
        workspace.navigationBinding().wrappedValue = []
        XCTAssertNil(reader.inspector)
    }

    func testAnOldDocumentsBindingCannotCloseANewDocumentWithTheSameThreadIDs() async throws {
        let (reader, file) = try await fixture()
        let workspace = MobileDocumentWorkspace(reader: reader, openFolder: {}, closeFile: {})
        reader.openDiscussion("t-binding")
        let old = workspace.navigationBinding()
        let second = file.deletingLastPathComponent().appendingPathComponent("Second.md")
        try Data(contentsOf: file).write(to: second)
        await reader.open(url: second); await reader.waitForRendering()
        reader.openDiscussion("t-binding")
        old.wrappedValue = []
        XCTAssertEqual(reader.discussionRoute, .thread("t-binding"),
                       "A callback from the old document cannot dismiss another document's conversation")
        XCTAssertEqual(reader.inspector, .discussions)
        workspace.navigationBinding().wrappedValue = [.list]
        XCTAssertNil(reader.discussionRoute)
    }

    func testAnOldConversationBindingCannotDismissTheChangesInspector() async throws {
        let (reader, _) = try await fixture()
        let workspace = MobileDocumentWorkspace(reader: reader, openFolder: {}, closeFile: {})
        reader.openDiscussion("t-binding")
        reader.discussions.setDraft("Keep this reply while reviewing changes.", for: .thread("t-binding"))
        let old = workspace.navigationBinding()
        reader.inspector = .changes
        old.wrappedValue = []
        XCTAssertEqual(reader.inspector, .changes,
                       "A queued conversation pop cannot close the newly selected inspector")
        XCTAssertEqual(reader.discussionRoute, .thread("t-binding"))
        workspace.navigationBinding().wrappedValue = []
        XCTAssertEqual(reader.inspector, .changes,
                       "A current binding for a non-conversation panel cannot dismiss that panel either")
        XCTAssertEqual(reader.discussionRoute, .thread("t-binding"))
        XCTAssertEqual(reader.discussions.selection, .thread("t-binding"))
        XCTAssertEqual(reader.discussions.drafts[.thread("t-binding")]?.body,
                       "Keep this reply while reviewing changes.")
    }

    func testPanelWidthPolicyCoversIPadPortraitLandscapeAndDuo() {
        for (width, expected) in [(834.0, false), (1032, true), (1194, true), (1376, true), (890, true), (390, false)] {
            for insets in [44.0, 88.0] {
                XCTAssertEqual(MobileReaderPanelLayout.canDockInspector(width: width,
                    bodyFont: 16, horizontalInsets: insets), expected,
                    "Docking at \(width) points must not depend on whether the document is already compact")
            }
        }
        XCTAssertFalse(MobileReaderPanelLayout.canDockInspector(width: 1032,
            bodyFont: 28, horizontalInsets: 44),
            "Larger document text can require compact panels even on a large iPad")
        XCTAssertTrue(MobileReaderPanelLayout.canDockOutline(width: 834, bodyFont: 16, horizontalInsets: 44))
        XCTAssertFalse(MobileReaderPanelLayout.canDockOutline(width: 390, bodyFont: 16, horizontalInsets: 44))
    }

    private func fixture() async throws -> (MobileReaderState, URL) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let prose = "# Plan\n\nA passage for discussion.\n"
        let thread = DiscussionThread(id: "t-binding", state: .open,
            target: .init(type: "TextQuoteSelector", exact: "A passage for discussion.", prefix: "Plan", suffix: "", section: "Plan"),
            messages: [.init(id: "m-binding", author: "Reviewer", created: "2026-10-24T10:00:00Z",
                body: "A saved note.", inReplyTo: nil)], resolvedBy: nil, resolved: nil, attachmentHistory: [])
        let bytes = try MarkdownSourceEdits.apply(DiscussionEdits.splices(for: .newThread(thread), in: DiscussionCodec.parse(prose)),
            to: Data(prose.utf8), expectedSource: prose)
        let file = folder.appendingPathComponent("First.md"); try bytes.write(to: file)
        let reader = MobileReaderState(defaults: UserDefaults(suiteName: "Margined.BindingTests." + UUID().uuidString)!)
        addTeardownBlock { @MainActor in
            reader.discussions.discardDrafts(); await reader.close()
            try? FileManager.default.removeItem(at: folder)
        }
        await reader.open(url: file); await reader.waitForRendering()
        XCTAssertEqual(reader.rendered?.discussions?.threads.count, 1)
        return (reader, file)
    }
}
