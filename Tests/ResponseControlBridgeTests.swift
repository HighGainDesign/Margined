import Foundation
import XCTest
#if MARGINED_RESPONSE_BRIDGE_PROBE
#elseif os(iOS)
@testable import MarginediOS
#else
@testable import Margined
#endif

final class ResponseControlBridgeTests: XCTestCase {
    private let message: [String: Any] = ["kind": "answer", "id": 0, "token": "current"]

    func testCurrentMainFrameMappedAnswerIsAccepted() {
        XCTAssertEqual(ResponseControlBridge.answerID(message, isMainFrame: true, enabled: true, token: "current", allowed: [0]), 0)
    }

    func testReadOnlyStaleSubframeAndUnmappedRequestsAreRejected() {
        XCTAssertNil(ResponseControlBridge.answerID(message, isMainFrame: false, enabled: true, token: "current", allowed: [0]))
        XCTAssertNil(ResponseControlBridge.answerID(message, isMainFrame: true, enabled: false, token: "current", allowed: [0]))
        XCTAssertNil(ResponseControlBridge.answerID(message, isMainFrame: true, enabled: true, token: "new", allowed: [0]))
        XCTAssertNil(ResponseControlBridge.answerID(message, isMainFrame: true, enabled: true, token: "current", allowed: []))
        XCTAssertNil(ResponseControlBridge.answerID(["kind": "answer", "id": 0, "token": ""], isMainFrame: true, enabled: true, token: "", allowed: [0]))
    }

    func testOnlyExplicitAnswerRequestsAreAccepted() {
        for kind in ["task", "", "Answer"] {
            XCTAssertNil(ResponseControlBridge.answerID(["kind": kind, "id": 0, "token": "current"], isMainFrame: true, enabled: true, token: "current", allowed: [0]))
        }
        XCTAssertNil(ResponseControlBridge.answerID(["id": 0, "checked": true, "token": "current"], isMainFrame: true, enabled: true, token: "current", allowed: [0]))
    }

    func testBooleanFractionStringAndUnboundedIDsAreRejected() {
        for invalid: Any in [true, "0", -1, 0.5, Double.nan, Double.infinity, Double(Int32.max) + 1, NSNull()] {
            XCTAssertNil(ResponseControlBridge.answerID(["kind": "answer", "id": invalid, "token": "current"], isMainFrame: true, enabled: true, token: "current", allowed: [0]))
        }
    }
}
