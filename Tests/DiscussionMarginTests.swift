import Foundation
import XCTest
#if MARGINED_DISCUSSION_PROBE
#elseif os(iOS)
@testable import MarginediOS
#else
@testable import Margined
#endif

final class DiscussionMarginTests: XCTestCase {
    func testMeasuredFontInsetsAndOutlineKeepAUsableProseColumn() {
        XCTAssertTrue(DiscussionMarginLayout.canShowMargin(width: 900, bodyFont: 16, horizontalInsets: 80, outlineWidth: 0))
        XCTAssertFalse(DiscussionMarginLayout.canShowMargin(width: 860, bodyFont: 16, horizontalInsets: 80, outlineWidth: 0))
        XCTAssertFalse(DiscussionMarginLayout.canShowMargin(width: 1_100, bodyFont: 30, horizontalInsets: 80, outlineWidth: 0))
        XCTAssertFalse(DiscussionMarginLayout.canShowMargin(width: 1_080, bodyFont: 16, horizontalInsets: 80, outlineWidth: 220))
        XCTAssertTrue(DiscussionMarginLayout.canShowMargin(width: 1_100, bodyFont: 16, horizontalInsets: 80, outlineWidth: 220))
        XCTAssertFalse(DiscussionMarginLayout.canShowMargin(width: .nan, bodyFont: 16, horizontalInsets: 80, outlineWidth: 0))
    }
    func testCardsAlignWithPassagesAndStackOverlappingThreadsStably() {
        let positions = DiscussionMarginLayout.cards(ids: ["later", "first", "overlap", "missing"],
            anchorTops: ["later": 150, "first": 20, "overlap": 150],
            heights: ["first": 60, "later": 40, "overlap": 30, "missing": 20], topInset: 20)
        XCTAssertEqual(positions.map(\.id), ["first", "later", "overlap", "missing"])
        XCTAssertEqual(positions.map(\.top), [0, 130, 182, 224])
    }
    func testGeometryRequiresTheCurrentEnabledRenderAndKnownThreadIDs() {
        let body: [String: Any] = ["kind": "geometry", "token": "r1", "sourceID": "source",
            "bodyFont": 16.0, "horizontalInsets": 80.0, "viewportHeight": 600.0,
            "anchors": [["id": "t1", "top": 180.0, "height": 24.0]]]
        let valid = DiscussionBridge.Context(token: "r1", sourceID: "source", enabled: true, allowedThreadIDs: ["t1"])
        XCTAssertEqual(DiscussionMarginSnapshot.read(body, context: valid)?.anchors.first?.id, "t1")
        for context in [DiscussionBridge.Context(token: "old", sourceID: "source", enabled: true, allowedThreadIDs: ["t1"]),
                        .init(token: "r1", sourceID: "new source", enabled: true, allowedThreadIDs: ["t1"]),
                        .init(token: "r1", sourceID: "source", enabled: false, allowedThreadIDs: ["t1"]),
                        .init(token: "r1", sourceID: "source", enabled: true, allowedThreadIDs: [])] {
            XCTAssertNil(DiscussionMarginSnapshot.read(body, context: context))
        }
        for bad in [Double.nan, Double.infinity, -Double.infinity] {
            var changed = body; changed["bodyFont"] = bad
            XCTAssertNil(DiscussionMarginSnapshot.read(changed, context: valid))
        }
        var boolean = body; boolean["bodyFont"] = true
        XCTAssertNil(DiscussionMarginSnapshot.read(boolean, context: valid))
        var repeated = body; repeated["anchors"] = [["id": "t1", "top": 0, "height": 24], ["id": "t1", "top": 10, "height": 24]]
        XCTAssertNil(DiscussionMarginSnapshot.read(repeated, context: valid))
    }
}
