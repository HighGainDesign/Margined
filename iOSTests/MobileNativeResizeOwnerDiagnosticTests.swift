#if MARGINED_NATIVE_RESIZE_OWNER_DIAGNOSTIC
import Foundation
import CoreGraphics
#if canImport(MarginediOS)
@testable import MarginediOS
#endif

/// Shared by hosted tests and a UI-free run of the actual fence implementation.
@MainActor
enum MobileNativeResizeFenceScenarios {
    static func failures() -> [String] {
        var failures: [String] = []
        func expect(_ value: Bool, _ label: String) { if !value { failures.append(label) } }
        let first = CGSize(width: 286, height: 710), latest = CGSize(width: 626, height: 230)
        do {
            let fence = MobileNativeResizeFenceDiagnostic()
            let old = fence.begin(target: first, now: 0)
            fence.nativeOffsetChanged() // Native B commits before final A.
            var writes = 0
            expect(!fence.commit(old, revision: fence.revision, now: 1, ready: true) { writes += 1 }, "native B retires old A")
            expect(writes == 0, "no obsolete setter after native B")
            let current = fence.stamp()
            expect(fence.commit(current, revision: fence.revision, now: 1, ready: true) { writes += 1 }, "fresh B capture can commit")
            expect(writes == 1, "one current final setter")
        }
        do {
            let fence = MobileNativeResizeFenceDiagnostic()
            let old = fence.begin(target: first, now: 0)
            fence.nativeInputBegan() // Pan/pinch precedes its first offset.
            expect(!fence.commit(old, revision: fence.revision, now: 1, ready: true) {}, "input before offset retires old A")
        }
        do {
            let fence = MobileNativeResizeFenceDiagnostic()
            let capture = fence.begin(target: first, now: 0), oldRevision = fence.revision
            fence.coalesce(latest)
            expect(fence.matches(capture), "coalescing keeps captured semantic intent")
            expect(fence.target == latest, "latest target wins")
            expect(!fence.commit(capture, revision: oldRevision, now: 1, ready: true) {}, "old geometry result cannot commit")
            expect(fence.commit(capture, revision: fence.revision, now: 1, ready: true) {}, "new geometry result can commit")
        }
        do {
            let fence = MobileNativeResizeFenceDiagnostic()
            let old = fence.begin(target: first, now: 0)
            fence.nativeOffsetChanged() // Frame-induced clamp is not exempt.
            expect(!fence.commit(old, revision: fence.revision, now: 1, ready: true) {}, "automatic clamp also retires old A")
        }
        do {
            let fence = MobileNativeResizeFenceDiagnostic()
            let old = fence.begin(target: first, now: 10)
            fence.coalesce(latest)
            expect(fence.expire(now: 12.99) == nil, "deadline does not release early")
            expect(fence.expire(now: 13) == latest, "deadline releases latest requested frame")
            expect(!fence.commit(old, revision: fence.revision, now: 1, ready: true) {}, "timeout never grants commit readiness")
        }
        do {
            let fence = MobileNativeResizeFenceDiagnostic()
            let old = fence.begin(target: first, now: 0)
            expect(fence.retire() == first, "teardown releases held target")
            expect(!fence.commit(old, revision: fence.revision, now: 1, ready: true) {}, "late reply after teardown is inert")
        }
        do {
            let fence = MobileNativeResizeFenceDiagnostic()
            let retained = fence.begin(target: first, now: 0)
            _ = fence.retire() // A retained reader temporarily leaves navigation.
            _ = fence.begin(target: latest, now: 1)
            expect(fence.sameMotion(retained), "a remount can reuse unchanged semantic intent")
            expect(!fence.matches(retained), "the old transaction still cannot write")
            fence.nativeOffsetChanged()
            expect(!fence.sameMotion(retained), "a newer native position retires retained intent")
        }
        do {
            let fence = MobileNativeResizeFenceDiagnostic()
            let old = fence.begin(target: first, now: 0)
            let firstIntent = fence.beginAppIntent(), secondIntent = fence.beginAppIntent()
            fence.endAppIntent(firstIntent)
            expect(fence.hasAppIntent, "overlapping newer app intent stays active")
            expect(!fence.commit(old, revision: fence.revision, now: 1, ready: true) {}, "app navigation retires old A")
            fence.endAppIntent(secondIntent)
            expect(!fence.hasAppIntent, "last app intent can finish")
            let new = fence.begin(target: latest, now: 1)
            expect(!fence.commit(new, revision: fence.revision, now: 1, ready: false) {}, "geometry or active input prevents final setter")
            expect(fence.commit(new, revision: fence.revision, now: 1, ready: true) {}, "new transaction can commit after intent ends")
        }
        do {
            let fence = MobileNativeResizeFenceDiagnostic()
            let old = fence.begin(target: first, now: 0)
            var writes = 0
            // A WebContent completion can run before the next display-link tick.
            expect(!fence.commit(old, revision: fence.revision, now: 3.001, ready: true) { writes += 1 },
                   "late completion cannot commit without an expiration tick")
            expect(writes == 0, "expired completion performs no native setter")
            expect(fence.expire(now: 3.001) == first, "expired completion can release held layout")
        }
        do {
            let fence = MobileNativeResizeFenceDiagnostic()
            let old = fence.begin(target: first, now: 0)
            let neverFinished = fence.beginAppIntent()
            let previousDocument = fence.stamp()
            fence.documentWillChange()
            expect(!fence.hasAppIntent, "old document's unfinished app work cannot block the replacement")
            expect(!fence.sameMotion(previousDocument), "a new document cannot reuse old semantic intent")
            expect(!fence.commit(old, revision: fence.revision, now: 1, ready: true) {},
                   "old document's callback cannot write after replacement")
            let currentIntent = fence.beginAppIntent()
            fence.endAppIntent(neverFinished)
            expect(fence.hasAppIntent, "old completion cannot end current document's intent")
            fence.endAppIntent(currentIntent)
            let current = fence.begin(target: latest, now: 1)
            expect(fence.commit(current, revision: fence.revision, now: 1, ready: true) {},
                   "new document can preserve reading without waiting for old work")
        }
        return failures
    }
}

#if canImport(XCTest)
import XCTest
@MainActor
final class MobileNativeResizeOwnerDiagnosticTests: XCTestCase {
    func testNativeResizeFenceCallbackOrderings() {
        XCTAssertEqual(MobileNativeResizeFenceScenarios.failures(), [])
    }
}
#endif
#endif
