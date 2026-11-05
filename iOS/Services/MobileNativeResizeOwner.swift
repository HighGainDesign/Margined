import Foundation
import CoreGraphics

/// Maps CSS document points through page zoom and the measured content-layer
/// transform. Derived from public layer conversions; no WebKit class assumptions.
struct MobileNativeCoordinateProjection: Equatable {
    let origin: CGPoint
    let scale: CGFloat
    init?(zero: CGPoint, unitX: CGPoint, unitY: CGPoint, pageZoom: CGFloat) {
        let x = unitX.x - zero.x, y = unitY.y - zero.y
        guard [zero.x, zero.y, unitX.x, unitX.y, unitY.x, unitY.y, pageZoom].allSatisfy(\.isFinite),
              pageZoom > 0, x > 0, y > 0, abs(x - y) < 0.0001,
              abs(unitX.y - zero.y) < 0.0001, abs(unitY.x - zero.x) < 0.0001 else { return nil }
        origin = zero; scale = x * pageZoom
        guard scale.isFinite, scale > 0 else { return nil }
    }
    func cssViewport(_ native: CGRect) -> CGRect {
        CGRect(x: (native.minX - origin.x) / scale, y: (native.minY - origin.y) / scale,
            width: native.width / scale, height: native.height / scale)
    }
    func nativePoint(_ css: CGPoint) -> CGPoint {
        CGPoint(x: css.x * scale + origin.x, y: css.y * scale + origin.y)
    }
}

/// UIKit's final setter must share this actor and
/// run synchronously inside commit, after current geometry/input validation.
@MainActor
final class MobileNativeResizeFence {
    struct Stamp: Equatable {
        let transaction: UInt64
        let offset: UInt64
        let input: UInt64
        let intent: UInt64
    }
    private var transaction: UInt64 = 0
    private var offset: UInt64 = 0
    private var input: UInt64 = 0
    private var intent: UInt64 = 0
    private var intents: Set<UUID> = []
    private var started: Double = 0
    private(set) var pending = false
    private(set) var target: CGSize = .zero
    private(set) var revision: UInt64 = 0
    var hasAppIntent: Bool { !intents.isEmpty }

    func begin(target: CGSize, now: Double) -> Stamp {
        transaction += 1
        revision += 1
        self.target = target
        started = now
        pending = true
        return stamp()
    }
    func stamp() -> Stamp { Stamp(transaction: transaction, offset: offset, input: input, intent: intent) }
    func sameMotion(_ stamp: Stamp) -> Bool {
        !hasAppIntent && stamp.offset == offset && stamp.input == input && stamp.intent == intent
    }
    func matches(_ stamp: Stamp) -> Bool { pending && !hasAppIntent && stamp == self.stamp() }
    func coalesce(_ target: CGSize) {
        guard pending, target != self.target else { return }
        self.target = target
        revision += 1
    }
    func nativeOffsetChanged() { offset += 1 }
    func nativeInputBegan() { input += 1 }
    func beginAppIntent() -> UUID {
        intent += 1
        _ = retire()
        let id = UUID()
        intents.insert(id)
        return id
    }
    func endAppIntent(_ id: UUID) { intents.remove(id) }
    func documentWillChange() {
        // Old asynchronous work can outlive cancellation. Its completion may
        // end only its own ticket; it cannot block or authorize a new document.
        intent += 1
        intents.removeAll()
        _ = retire()
    }

    func canCommit(_ stamp: Stamp, revision: UInt64, now: Double, ready: Bool) -> Bool {
        matches(stamp) && revision == self.revision && ready && now >= started && now - started < 3
    }
    @discardableResult
    func commit(_ stamp: Stamp, revision: UInt64, now: Double, ready: Bool, write: () -> Void) -> Bool {
        guard canCommit(stamp,revision:revision,now:now,ready:ready) else { return false }
        pending = false
        write() // No await or queued JavaScript setter may separate check/write.
        return true
    }
    /// One non-awaiting owner-issued frame setter may clamp its old offset.
    /// The caller proves the exact transition and unchanged native geometry.
    /// Epochs stay monotonic; only this capture advances. No deadline resets.
    func applyingOwnedFrameClamp(_ stamp: Stamp, revision: UInt64, now: () -> Double,
        change: () -> Bool) -> Stamp? {
        let start = now()
        let eligible = matches(stamp) && revision == self.revision && start >= started && start - started < 3
        let verified = change() // Always release/apply layout, even if obsolete.
        let end = now()
        guard eligible, verified, pending, !hasAppIntent,
              transaction == stamp.transaction, offset == stamp.offset + 1,
              input == stamp.input, intent == stamp.intent, revision == self.revision,
              end >= started, end - started < 3 else { return nil }
        return self.stamp()
    }

    @discardableResult
    func retire() -> CGSize? {
        let released = pending ? target : nil
        pending = false
        transaction += 1
        return released
    }
    func expire(now: Double) -> CGSize? {
        guard pending, now - started >= 3 else { return nil }
        return retire() // A deadline releases layout; it never authorizes scroll.
    }
}

#if canImport(UIKit)
import UIKit
import WebKit

/// Preserves the native-visible reading passage across viewport changes.
/// It never queues a JavaScript scroll
/// setter; document/offset/input/intent checks and the final native write share
/// the main actor. Unsupported/expired paths are failed preservation attempts.
@MainActor
final class MobileNativeResizeOwner: NSObject {
    @MainActor private final class Pulse: NSObject {
        weak var owner: MobileNativeResizeOwner?
        weak var link: CADisplayLink?
        init(_ owner: MobileNativeResizeOwner) { self.owner = owner }
        @objc func tick() {
            guard let owner else { link?.invalidate(); return }
            owner.tick()
        }
    }
    private weak var web: WKWebView?
    private let world: WKContentWorld
    private let document: () -> String?
    private let script: String?
    private let lockScript: String?
    private var resizeOrder: UInt64 = 0
    private var sessionQueried = false
    private var pendingRetiredOrder: UInt64?
    #if DEBUG
    private(set) var debugCleanupStatus = "idle"
    #endif
    private let fence = MobileNativeResizeFence()
    private var observation: NSKeyValueObservation?
    private var lastOffsetTransition: (old: CGPoint?, new: CGPoint?)?
    private var link: CADisplayLink?
    private var session: UUID?
    private var token: String?
    private var position: [String: Any]?
    private var captured: MobileNativeResizeFence.Stamp?
    private struct Retained {
        let token: String
        let position: [String: Any]
        let stamp: MobileNativeResizeFence.Stamp
    }
    private var retained: Retained?
    // At most one WebContent request may remain outstanding, even if a prior
    // transaction expires. A stalled process cannot accumulate awaiting tasks.
    private var query: UUID?
    private var latestTarget: CGSize = .zero
    private var lastQuery: CFTimeInterval = 0
    private var invalidated = false
    #if DEBUG
    var debugHoldNextReadyRestore = false
    private var debugHeldRestore: (@MainActor () -> Void)?
    private var debugHeldSession: UUID?
    private var debugHeldAuthorization: (@MainActor () -> Bool)?
    private(set) var debugHeldRestoreDocumentToken: String?
    private(set) var debugAcceptedRestoreTokens: [String] = []
    var debugHasHeldReadyRestore: Bool { debugHeldRestore != nil }
    var debugHeldRestoreIsCurrent: Bool { debugHeldRestore != nil && (debugHeldAuthorization?() ?? false) }
    private(set) var debugLastFinishReason = ""
    var debugReadyForResize: Bool { !fence.hasAppIntent && !fence.pending && query == nil && document() != nil }
    func debugDeliverHeldRestore() {
        let delivery = debugHeldRestore
        debugHeldRestore = nil; debugHeldSession = nil; debugHeldRestoreDocumentToken = nil; debugHeldAuthorization = nil
        delivery?()
    }
    #endif

    init(web: WKWebView, world: WKContentWorld, document: @escaping () -> String?) {
        self.web = web
        self.world = world
        self.document = document
        let coordinateScript = Bundle.main.url(forResource: "native-reading-position", withExtension: "js")
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) }
        lockScript = Bundle.main.url(forResource:"native-resize-scroll-lock",withExtension:"js")
            .flatMap { try? String(contentsOf:$0,encoding:.utf8) }
        if let coordinateScript,let lockScript {
            script = "const lockReady=(()=>{\(lockScript)})();if(!lockReady)return null;return (()=>{\(coordinateScript)})();"
        } else { script = nil }
        super.init()
        observation = web.scrollView.observe(\.contentOffset, options: [.old, .new]) { [weak self] _, change in
            guard change.oldValue != change.newValue else { return }
            MainActor.assumeIsolated {
                guard let self else { return }
                self.fence.nativeOffsetChanged()
                self.lastOffsetTransition = (change.oldValue,change.newValue)
            }
        }
        web.scrollView.panGestureRecognizer.addTarget(self, action: #selector(inputChanged(_:)))
        web.scrollView.pinchGestureRecognizer?.addTarget(self, action: #selector(inputChanged(_:)))
    }

    @objc private func inputChanged(_ gesture: UIGestureRecognizer) {
        if gesture.state == .began { fence.nativeInputBegan() }
    }

    func requestSize(_ target: CGSize) {
        guard !invalidated, target.width.isFinite, target.height.isFinite,
              target.width > 0, target.height > 0, let web else { return }
        latestTarget = target
        if fence.pending {
            fence.coalesce(target)
            if position != nil { apply(target) }
            return
        }
        if let retained, retained.token != document() || !fence.sameMotion(retained.stamp) { self.retained = nil }
        guard web.bounds.size != target || retained != nil else { return }
        guard let token = document(), web.bounds.width > 0, web.bounds.height > 0 else {
            apply(target); return // No retained reading position exists yet.
        }
        if fence.hasAppIntent { apply(target); return }
        guard displayed(web) else { return } // Retain old geometry while hidden.
        _ = fence.begin(target: target, now: CACurrentMediaTime())
        session = UUID(); self.token = token
        resizeOrder += 1; sessionQueried = false
        position = retained?.position
        captured = retained == nil ? nil : fence.stamp()
        retained = nil
        lastQuery = 0
        if position != nil { apply(target) }
        let pulse = Pulse(self), link = CADisplayLink(target: pulse, selector: #selector(Pulse.tick))
        pulse.link = link; self.link = link
        link.add(to: .main, forMode: .common)
        tick()
    }

    func beginAppIntent() -> UUID {
        retained = nil
        let hadSession = session != nil
        let id = fence.beginAppIntent()
        if hadSession { finish("app-intent-superseded", preserved: false) }
        return id
    }
    func endAppIntent(_ id: UUID) { fence.endAppIntent(id) }
    func documentWillChange() {
        retained = nil
        if session != nil { finish("document-replaced", preserved: false) }
        fence.documentWillChange()
    }
    func detach() {
        if session != nil { finish("temporarily-detached", preserved: false, retainPosition: true, releaseFrame: false) }
    }
    func invalidate() {
        invalidated = true
        retained = nil
        if session != nil { finish("invalidated", preserved: false) }
        link?.invalidate(); link = nil
        observation?.invalidate(); observation = nil
        web?.scrollView.panGestureRecognizer.removeTarget(self, action: #selector(inputChanged(_:)))
        web?.scrollView.pinchGestureRecognizer?.removeTarget(self, action: #selector(inputChanged(_:)))
    }

    private func apply(_ size: CGSize) {
        guard let web, size.width > 0, size.height > 0 else { return }
        let frame = CGRect(origin: .zero, size: size)
        guard web.frame != frame else { return }
        let scroll = web.scrollView, before = scroll.contentOffset, content = scroll.contentSize
        let inset = scroll.adjustedContentInset, rawInset = scroll.contentInset
        let zoom = scroll.zoomScale, pageZoom = web.pageZoom
        func clamped(_ point: CGPoint, to viewport: CGSize) -> CGPoint {
            CGPoint(x:min(max(-inset.left,point.x),max(-inset.left,content.width - viewport.width + inset.right)),
                y:min(max(-inset.top,point.y),max(-inset.top,content.height - viewport.height + inset.bottom)))
        }
        // Only arithmetic representation error, never a subpixel motion allowance.
        func equal(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) <= max(a.ulp,b.ulp) * 8 }
        func equal(_ a: CGPoint, _ b: CGPoint) -> Bool { equal(a.x,b.x) && equal(a.y,b.y) }
        let predicted = clamped(before,to:size)
        if let captured, token == document(), scroll.delegate == nil, idle(scroll), equal(clamped(before,to:scroll.bounds.size),before),
           !equal(predicted,before) {
            let updated = fence.applyingOwnedFrameClamp(captured,revision:fence.revision,now:{ CACurrentMediaTime() }) {
                // No await, app scroll delegate, or synchronous app scroll writer
                // occurs inside this setter. layoutIfNeeded stays outside it.
                web.frame = frame
                guard let transition = self.lastOffsetTransition, let old = transition.old, let new = transition.new else { return false }
                return self.token == self.document() && self.idle(scroll) && web.frame == frame && scroll.bounds.size == size &&
                    scroll.contentSize == content && scroll.adjustedContentInset == inset && scroll.contentInset == rawInset &&
                    scroll.zoomScale == zoom && web.pageZoom == pageZoom && equal(old,before) && equal(new,predicted) &&
                    equal(scroll.contentOffset,predicted)
            }
            if let updated {
                self.captured = updated
            }
        } else { web.frame = frame }
        web.setNeedsLayout(); web.layoutIfNeeded()
    }

    private func tick() {
        guard session != nil, fence.pending else { link?.invalidate(); link = nil; return }
        let now = CACurrentMediaTime()
        if fence.expire(now: now) != nil { finish("resize-deadline", preserved: false); return }
        guard !invalidated, let web, token == document() else {
            retained = nil
            finish("document-changed", preserved: false); return
        }
        guard displayed(web) else {
            finish("temporarily-not-displayed", preserved: false, retainPosition: true, releaseFrame: false); return
        }
        if let captured, !fence.matches(captured) {
            finish("native-offset-or-input-superseded", preserved: false); return
        }
        #if DEBUG
        if debugHeldRestore != nil && debugHeldSession == session { return }
        #endif
        guard idle(web.scrollView), query == nil else { return }
        // Bound WebContent query work, never use elapsed time as readiness.
        guard now - lastQuery >= 1.0 / 30 else { return }
        guard let script else { finish("missing-resource", preserved: false); return }
        lastQuery = now
        let id = UUID(), currentSession = session, stamp = fence.stamp(), revision = fence.revision
        guard let native = nativeProjection(web) else { return }
        let origin = web.scrollView.contentOffset
        let oldSize = web.bounds.size
        let viewport = native.mapping.cssViewport(web.scrollView.bounds)
        var arguments: [String: Any] = ["documentToken": token ?? ""]
        arguments["lockOperation"] = "acquire"
        arguments["disableAnchor"] = true
        arguments["resizeOrder"] = resizeOrder
        arguments["resizeSession"] = currentSession?.uuidString ?? ""
        arguments["shouldLock"] = abs(web.scrollView.zoomScale - web.scrollView.minimumZoomScale) > 0.0001
        if let position {
            arguments["operation"] = "destination"; arguments["position"] = position
        } else {
            arguments["operation"] = "capture"
            arguments["nativeViewport"] = ["x": Double(viewport.minX), "y": Double(viewport.minY),
                "width": Double(viewport.width), "height": Double(viewport.height)]
        }
        let capturing = position == nil
        query = id
        sessionQueried = true
        web.callAsyncJavaScript(script, arguments: arguments, in: nil,
            in: world) { [weak self] result in
            guard let self else { return }
            guard self.query == id else { return }
            self.query = nil
            self.drainScrollLockCleanup()
            guard self.session == currentSession, self.fence.pending, !self.invalidated,
                  self.token == self.document(), let web = self.web else { return }
            if self.fence.expire(now: CACurrentMediaTime()) != nil {
                self.finish("completion-after-deadline", preserved: false); return
            }
            guard case let .success(raw) = result, let value = raw as? [String: Any],
                  let metrics = value["metrics"] as? [String: Any],
                  self.nativeProjection(web) == native else { return }
            if capturing {
                guard self.fence.matches(stamp), web.bounds.size == oldSize,
                      web.scrollView.contentOffset == origin, self.idle(web.scrollView),
                      self.geometry(metrics, web: web), let position = value["position"] as? [String: Any] else { return }
                self.position = position; self.captured = stamp
                self.apply(self.fence.target)
            } else {
                guard let captured = self.captured else { return }
                guard self.fence.matches(captured) else {
                    self.finish("native-offset-or-input-superseded", preserved: false); return
                }
                guard revision == self.fence.revision,
                      let x = value["x"] as? Double, x.isFinite,
                      let y = value["y"] as? Double, y.isFinite else { return }
                let expectedToken = self.token ?? ""
                #if DEBUG
                if self.debugHoldNextReadyRestore && self.restoreGeometryReady(metrics, web: web) {
                    self.debugHoldNextReadyRestore = false
                    self.debugHeldSession = currentSession
                    self.debugHeldRestoreDocumentToken = expectedToken
                    self.debugHeldAuthorization = { [weak self,weak web] in
                        guard let self,let web,self.session == currentSession,!self.invalidated,
                              self.token == expectedToken,self.document() == expectedToken else { return false }
                        return self.fence.canCommit(captured,revision:revision,now:CACurrentMediaTime(),
                            ready:self.restoreGeometryReady(metrics,web:web))
                    }
                    self.debugHeldRestore = { [weak self, weak web] in
                        guard let self, let web else { return }
                        self.commitRestore(captured, revision: revision, session: currentSession,
                            documentToken: expectedToken, x: CGFloat(x), y: CGFloat(y), metrics: metrics, web: web)
                    }
                    return
                }
                #endif
                self.commitRestore(captured, revision: revision, session: currentSession,
                    documentToken: expectedToken, x: CGFloat(x), y: CGFloat(y), metrics: metrics, web: web)
            }
        }
    }

    private func restoreGeometryReady(_ metrics: [String: Any], web: WKWebView) -> Bool {
        displayed(web) && idle(web.scrollView) && web.bounds.size == fence.target && geometry(metrics, web: web)
    }

    private func commitRestore(_ captured: MobileNativeResizeFence.Stamp, revision: UInt64,
        session expectedSession: UUID?, documentToken: String, x: CGFloat, y: CGFloat,
        metrics: [String: Any], web: WKWebView) {
        guard session == expectedSession, !invalidated, token == documentToken, document() == documentToken,
              fence.matches(captured), revision == fence.revision else { return }
        let scroll = web.scrollView
        let ready = restoreGeometryReady(metrics, web: web)
        guard let native = nativeProjection(web) else { return }
        let point = native.mapping.nativePoint(CGPoint(x: x, y: y))
        let inset = scroll.adjustedContentInset
        let destination = CGPoint(
            x: min(max(-inset.left, point.x), max(-inset.left, scroll.contentSize.width - scroll.bounds.width + inset.right)),
            y: min(max(-inset.top, point.y), max(-inset.top, scroll.contentSize.height - scroll.bounds.height + inset.bottom)))
        if fence.commit(captured, revision: revision, now: CACurrentMediaTime(), ready: ready, write: {
            #if DEBUG
            if self.debugAcceptedRestoreTokens.count == 64 { self.debugAcceptedRestoreTokens.removeFirst() }
            self.debugAcceptedRestoreTokens.append(documentToken)
            #endif
            scroll.setContentOffset(destination, animated: false)
        }) { finish("native-restore", preserved: true) }
        else if fence.expire(now: CACurrentMediaTime()) != nil {
            finish("commit-after-deadline", preserved: false)
        }
    }

    private func finish(_ reason: String, preserved: Bool, retainPosition: Bool = false, releaseFrame: Bool = true) {
        guard session != nil else { return }
        #if DEBUG
        debugLastFinishReason = reason
        #endif
        if retainPosition, let token, let position, let captured, fence.matches(captured) {
            retained = Retained(token: token, position: position, stamp: captured)
        }
        if sessionQueried {
            pendingRetiredOrder = max(pendingRetiredOrder ?? 0,resizeOrder)
            #if DEBUG
            debugCleanupStatus = "pending"
            #endif
            drainScrollLockCleanup()
        }
        _ = fence.retire()
        session = nil; position = nil; captured = nil; token = nil
        link?.invalidate(); link = nil
        if releaseFrame { apply(latestTarget) }

    }

    /// Shares the one WebContent request slot with coordinate queries. At most
    /// one coalesced retirement watermark waits natively, even if WebContent stalls.
    private func drainScrollLockCleanup() {
        guard query == nil,let order = pendingRetiredOrder,let web,let lockScript else { return }
        pendingRetiredOrder = nil
        #if DEBUG
        debugCleanupStatus = "pending"
        #endif
        let id = UUID();query = id
        web.callAsyncJavaScript(lockScript,arguments:["lockOperation":"release","resizeOrder":order],in:nil,in:world) { [weak self] result in
            guard let self,self.query == id else { return }
            self.query = nil
            let succeeded: Bool
            if case let .success(value) = result,(value as? Bool) == true { succeeded = true }
            else { succeeded = false; print("NATIVE-RESIZE-CLEANUP-FAILURE order=\(order)") }
            #if DEBUG
            self.debugCleanupStatus = succeeded ? "succeeded" : "failed"
            #endif
            self.drainScrollLockCleanup()
        }
    }

    private func idle(_ scroll: UIScrollView) -> Bool {
        !scroll.isTracking && !scroll.isDragging && !scroll.isDecelerating && !scroll.isZooming && !scroll.isZoomBouncing &&
            ![.began, .changed].contains(scroll.panGestureRecognizer.state) &&
            !(scroll.pinchGestureRecognizer.map { [.began, .changed].contains($0.state) } ?? false)
    }
    private func displayed(_ web: WKWebView) -> Bool {
        guard let window = web.window, !window.isHidden,
              web.convert(web.bounds, to: window).intersects(window.bounds) else { return false }
        var view: UIView? = web
        while let current = view {
            if current.isHidden || current.alpha <= 0.01 { return false }
            view = current.superview
        }
        return true
    }
    private struct NativeProjection: Equatable {
        let mapping: MobileNativeCoordinateProjection
        let contentBounds: CGRect
        let scrollBounds: CGRect
        let contentSize: CGSize
        let insets: UIEdgeInsets
        let pageZoom: CGFloat
        let zoomScale: CGFloat
    }

    private func nativeProjection(_ web: WKWebView) -> NativeProjection? {
        let scroll = web.scrollView
        func near(_ a: CGFloat, _ b: CGFloat, tolerance: CGFloat = 1) -> Bool { abs(a - b) <= tolerance }
        func same(_ a: CGRect, _ b: CGRect) -> Bool {
            near(a.minX,b.minX) && near(a.minY,b.minY) && near(a.width,b.width) && near(a.height,b.height)
        }
        guard web.pageZoom.isFinite, web.pageZoom > 0, scroll.zoomScale.isFinite, scroll.zoomScale > 0,
              web.bounds.origin == .zero, web.bounds.size == scroll.bounds.size,
              let displayed = scroll.layer.presentation(), same(displayed.bounds, scroll.bounds),
              near(scroll.bounds.minX, scroll.contentOffset.x), near(scroll.bounds.minY, scroll.contentOffset.y) else { return nil }
        func mapping(_ child: CALayer, _ parent: CALayer) -> MobileNativeCoordinateProjection? {
            guard CATransform3DIsAffine(child.transform), CATransform3DIsAffine(parent.sublayerTransform) else { return nil }
            return MobileNativeCoordinateProjection(zero: child.convert(.zero,to:parent),
                unitX:child.convert(CGPoint(x:1,y:0),to:parent),
                unitY:child.convert(CGPoint(x:0,y:1),to:parent),pageZoom:web.pageZoom)
        }
        var result: NativeProjection?
        for child in scroll.subviews where !child.isHidden && child.alpha > 0.01 {
            guard let model = mapping(child.layer,scroll.layer),
                  abs(model.scale / web.pageZoom - scroll.zoomScale) < 0.0001,
                  near(child.bounds.width * scroll.zoomScale,scroll.contentSize.width),
                  near(child.bounds.height * scroll.zoomScale,scroll.contentSize.height),
                  let shown = child.layer.presentation(), same(shown.bounds,child.layer.bounds),
                  let presentation = mapping(shown,displayed),
                  near(model.scale,presentation.scale,tolerance:0.0001),
                  near(model.origin.x,presentation.origin.x,tolerance:0.0001),
                  near(model.origin.y,presentation.origin.y,tolerance:0.0001) else { continue }
            let candidate = NativeProjection(mapping:model,contentBounds:child.bounds,scrollBounds:scroll.bounds,
                contentSize:scroll.contentSize,insets:scroll.adjustedContentInset,pageZoom:web.pageZoom,zoomScale:scroll.zoomScale)
            if let result, result != candidate { return nil }
            result = candidate
        }
        return result
    }

    private func geometry(_ metrics: [String: Any], web: WKWebView) -> Bool {
        func number(_ key: String, in values: [String: Any]) -> CGFloat? {
            guard let value = values[key] as? Double, value.isFinite, value > 0 else { return nil }
            return CGFloat(value)
        }
        guard let native = nativeProjection(web) else { return false }
        guard let layoutWidth = number("width",in:metrics), let layoutHeight = number("height",in:metrics),
              let contentWidth = number("contentWidth",in:metrics), let contentHeight = number("contentHeight",in:metrics),
              let visual = metrics["visual"] as? [String:Any], let width = number("width",in:visual),
              let height = number("height",in:visual), let scale = number("scale",in:visual) else { return false }
        let tolerance = max(1,native.pageZoom) + 0.5
        guard abs(layoutWidth * native.pageZoom - web.bounds.width) <= tolerance,
              abs(layoutHeight * native.pageZoom - web.bounds.height) <= tolerance else { return false }
        guard abs(contentWidth * native.pageZoom - native.contentBounds.width) <= tolerance,
              abs(contentHeight * native.pageZoom - native.contentBounds.height) <= tolerance else { return false }
        let viewport = native.mapping.cssViewport(native.scrollBounds)
        guard abs(width - viewport.width) <= 1, abs(height - viewport.height) <= 1,
              abs(scale - native.zoomScale) < 0.005 else { return false }
        return true
    }

}

@MainActor
final class MobileNativeResizeViewport: UIView {
    let web: WKWebView
    let owner: MobileNativeResizeOwner
    init(web: WKWebView, owner: MobileNativeResizeOwner) {
        self.web = web; self.owner = owner
        super.init(frame: .zero)
        clipsToBounds = true
        backgroundColor = .clear
        addSubview(web)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    override func layoutSubviews() { super.layoutSubviews(); owner.requestSize(bounds.size) }
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { owner.detach() }
        else { setNeedsLayout() }
    }
}
#endif
