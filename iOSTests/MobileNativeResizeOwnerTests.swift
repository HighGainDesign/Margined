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
            let fence = MobileNativeResizeFence()
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
            let fence = MobileNativeResizeFence()
            let old = fence.begin(target: first, now: 0)
            fence.nativeInputBegan() // Pan/pinch precedes its first offset.
            expect(!fence.commit(old, revision: fence.revision, now: 1, ready: true) {}, "input before offset retires old A")
        }
        do {
            let fence = MobileNativeResizeFence()
            let capture = fence.begin(target: first, now: 0), oldRevision = fence.revision
            fence.coalesce(latest)
            expect(fence.matches(capture), "coalescing keeps captured semantic intent")
            expect(fence.target == latest, "latest target wins")
            expect(!fence.commit(capture, revision: oldRevision, now: 1, ready: true) {}, "old geometry result cannot commit")
            expect(fence.commit(capture, revision: fence.revision, now: 1, ready: true) {}, "new geometry result can commit")
        }
        do {
            let fence = MobileNativeResizeFence()
            let old = fence.begin(target: first, now: 0)
            fence.nativeOffsetChanged() // Frame-induced clamp is not exempt.
            expect(!fence.commit(old, revision: fence.revision, now: 1, ready: true) {}, "automatic clamp also retires old A")
        }
        do {
            let fence = MobileNativeResizeFence()
            let old = fence.begin(target: first, now: 10)
            fence.coalesce(latest)
            expect(fence.expire(now: 12.99) == nil, "deadline does not release early")
            expect(fence.expire(now: 13) == latest, "deadline releases latest requested frame")
            expect(!fence.commit(old, revision: fence.revision, now: 1, ready: true) {}, "timeout never grants commit readiness")
        }
        do {
            let fence = MobileNativeResizeFence()
            let old = fence.begin(target: first, now: 0)
            expect(fence.retire() == first, "teardown releases held target")
            expect(!fence.commit(old, revision: fence.revision, now: 1, ready: true) {}, "late reply after teardown is inert")
        }
        do {
            let fence = MobileNativeResizeFence()
            let retained = fence.begin(target: first, now: 0)
            _ = fence.retire() // A retained reader temporarily leaves navigation.
            _ = fence.begin(target: latest, now: 1)
            expect(fence.sameMotion(retained), "a remount can reuse unchanged semantic intent")
            expect(!fence.matches(retained), "the old transaction still cannot write")
            fence.nativeOffsetChanged()
            expect(!fence.sameMotion(retained), "a newer native position retires retained intent")
        }
        do {
            let fence = MobileNativeResizeFence()
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
            let fence = MobileNativeResizeFence()
            let old = fence.begin(target: first, now: 0)
            var writes = 0
            // A WebContent completion can run before the next display-link tick.
            expect(!fence.commit(old, revision: fence.revision, now: 3.001, ready: true) { writes += 1 },
                   "late completion cannot commit without an expiration tick")
            expect(writes == 0, "expired completion performs no native setter")
            expect(fence.expire(now: 3.001) == first, "expired completion can release held layout")
        }
        do {
            let fence = MobileNativeResizeFence()
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
        do {
            let fence = MobileNativeResizeFence()
            let captured = fence.begin(target: first, now: 0)
            let current = fence.applyingOwnedFrameClamp(captured, revision: fence.revision, now: { 1 }) {
                fence.nativeOffsetChanged()
                return true // The caller checked the exact predicted UIKit clamp.
            }
            expect(current != nil, "one synchronous verified owned frame clamp can advance its capture")
            expect(current.map { fence.commit($0, revision: fence.revision, now: 1, ready: true) {} } == true,
                "verified geometry ownership preserves semantic position")
        }
        for interference in 0..<6 {
            let fence = MobileNativeResizeFence()
            let captured = fence.begin(target: first, now: 0)
            let revision = fence.revision
            if interference == 0 { fence.nativeOffsetChanged() } // B before owned call.
            let current = fence.applyingOwnedFrameClamp(captured, revision: revision, now: { 1 }) {
                fence.nativeOffsetChanged()
                if interference == 1 { fence.nativeOffsetChanged() }
                if interference == 2 { fence.nativeInputBegan() }
                if interference == 3 { _ = fence.beginAppIntent() }
                if interference == 4 { fence.coalesce(latest) }
                return interference != 5 // Unexpected post-offset/content geometry.
            }
            expect(current == nil, "owned clamp cannot acknowledge interference \(interference)")
            expect(!fence.commit(captured, revision: revision, now: 1, ready: true) {},
                "old capture stays rejected after interference \(interference)")
        }
        do {
            let fence = MobileNativeResizeFence()
            let captured = fence.begin(target: first, now: 0)
            let current = fence.applyingOwnedFrameClamp(captured, revision: fence.revision, now: { 1 }) {
                fence.nativeOffsetChanged(); return true
            }
            fence.nativeOffsetChanged() // Same-looking B AFTER the owned call.
            expect(current.map { !fence.commit($0, revision: fence.revision, now: 1, ready: true) {} } == true,
                "a newer native B still retires an acknowledged owned clamp")
        }
        do {
            let fence = MobileNativeResizeFence()
            let captured = fence.begin(target:first,now:0)
            var calls = 0
            let current = fence.applyingOwnedFrameClamp(captured,revision:fence.revision,now:{ calls += 1; return calls == 1 ? 1 : 3.001 }) {
                fence.nativeOffsetChanged(); return true
            }
            expect(current == nil,"owned geometry cannot extend the original deadline")
            expect(fence.expire(now:3.001) == first,"owned clamp deadline still releases layout")
        }
        return failures
    }
}

#if canImport(XCTest)
import XCTest
@MainActor
final class MobileNativeResizeOwnerTests: XCTestCase {
    func testNativeResizeFenceCallbackOrderings() {
        XCTAssertEqual(MobileNativeResizeFenceScenarios.failures(), [])
    }
}
#endif
