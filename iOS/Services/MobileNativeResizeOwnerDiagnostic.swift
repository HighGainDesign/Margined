#if MARGINED_NATIVE_RESIZE_OWNER_DIAGNOSTIC
import Foundation
import CoreGraphics

/// Temporary diagnostic policy. UIKit's final setter must share this actor and
/// run synchronously inside commit, after current geometry/input validation.
@MainActor
final class MobileNativeResizeFenceDiagnostic {
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

    @discardableResult
    func commit(_ stamp: Stamp, revision: UInt64, now: Double, ready: Bool, write: () -> Void) -> Bool {
        guard matches(stamp), revision == self.revision, ready,
              now >= started, now - started < 3 else { return false }
        pending = false
        write() // No await or queued JavaScript setter may separate check/write.
        return true
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

/// Finite, compile-flagged experiment. It never queues a JavaScript scroll
/// setter; document/offset/input/intent checks and the final native write share
/// the main actor. Unsupported/expired paths are failed preservation attempts.
@MainActor
final class MobileNativeResizeOwnerDiagnostic: NSObject {
    @MainActor private final class Pulse: NSObject {
        weak var owner: MobileNativeResizeOwnerDiagnostic?
        weak var link: CADisplayLink?
        init(_ owner: MobileNativeResizeOwnerDiagnostic) { self.owner = owner }
        @objc func tick() {
            guard let owner else { link?.invalidate(); return }
            owner.tick()
        }
    }
    private weak var web: WKWebView?
    private let world: WKContentWorld
    private let document: () -> String?
    private let script: String?
    private let fence = MobileNativeResizeFenceDiagnostic()
    private var observation: NSKeyValueObservation?
    private var link: CADisplayLink?
    private var session: UUID?
    private var token: String?
    private var position: [String: Any]?
    private var captured: MobileNativeResizeFenceDiagnostic.Stamp?
    private struct Retained {
        let token: String
        let position: [String: Any]
        let stamp: MobileNativeResizeFenceDiagnostic.Stamp
        let receipt: [String: Any]
    }
    private var retained: Retained?
    // At most one WebContent request may remain outstanding, even if a prior
    // transaction expires. A stalled process cannot accumulate awaiting tasks.
    private var query: UUID?
    private var latestTarget: CGSize = .zero
    private var lastQuery: CFTimeInterval = 0
    private var invalidated = false
    private var queries = 0
    private var evidence: [String: Any] = [:]
    private var captureReceipt: [String: Any] = [:]

    init(web: WKWebView, world: WKContentWorld, document: @escaping () -> String?) {
        self.web = web
        self.world = world
        self.document = document
        script = Bundle.main.url(forResource: "native-reading-position-diagnostic", withExtension: "js")
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) }
        super.init()
        observation = web.scrollView.observe(\.contentOffset, options: [.old, .new]) { [weak self] _, change in
            guard change.oldValue != change.newValue else { return }
            MainActor.assumeIsolated { self?.fence.nativeOffsetChanged() }
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
        position = retained?.position
        captured = retained == nil ? nil : fence.stamp()
        captureReceipt = retained?.receipt ?? [:]
        if retained != nil { captureReceipt["remounted"] = true }
        retained = nil
        queries = 0; lastQuery = 0; evidence = [:]
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
        if web.frame != frame {
            web.frame = frame
            web.setNeedsLayout(); web.layoutIfNeeded()
        }
    }

    private func tick() {
        guard session != nil, fence.pending else { link?.invalidate(); link = nil; return }
        let now = CACurrentMediaTime()
        if fence.expire(now: now) != nil { finish("diagnostic-deadline", preserved: false); return }
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
        guard idle(web.scrollView), query == nil else { return }
        // Bound diagnostic query work, never use elapsed time as readiness.
        guard now - lastQuery >= 1.0 / 30 else { return }
        guard let script else { finish("missing-resource", preserved: false); return }
        lastQuery = now; queries += 1
        let id = UUID(), currentSession = session, stamp = fence.stamp(), revision = fence.revision
        let origin = web.scrollView.contentOffset
        let oldSize = web.bounds.size
        var arguments: [String: Any] = ["documentToken": token ?? ""]
        if let position {
            arguments["operation"] = "destination"; arguments["position"] = position
        } else {
            arguments["operation"] = "capture"
            arguments["nativeViewport"] = ["x": Double(origin.x), "y": Double(origin.y),
                "width": Double(oldSize.width), "height": Double(oldSize.height)]
        }
        let capturing = position == nil
        query = id
        web.callAsyncJavaScript(script, arguments: arguments, in: nil,
            in: world) { [weak self] result in
            guard let self else { return }
            guard self.query == id else { return }
            self.query = nil
            guard self.session == currentSession, self.fence.pending, !self.invalidated,
                  self.token == self.document(), let web = self.web else { return }
            if self.fence.expire(now: CACurrentMediaTime()) != nil {
                self.finish("completion-after-deadline", preserved: false); return
            }
            guard case let .success(raw) = result, let value = raw as? [String: Any],
                  let metrics = value["metrics"] as? [String: Any] else { return }
            if capturing {
                guard self.fence.matches(stamp), web.bounds.size == oldSize,
                      web.scrollView.contentOffset == origin, self.idle(web.scrollView),
                      self.geometry(metrics, web: web), let position = value["position"] as? [String: Any] else { return }
                self.position = position; self.captured = stamp
                let anchor = (position["candidates"] as? [[String: Any]])?.first
                // No document text or arbitrary author identifiers enter logs.
                self.captureReceipt = ["nativeX": Double(origin.x), "nativeY": Double(origin.y),
                    "domX": metrics["domX"] ?? NSNull(), "domY": metrics["domY"] ?? NSNull(),
                    "oldWidth": Double(oldSize.width), "oldHeight": Double(oldSize.height),
                    "anchorTag": anchor?["tag"] as? String ?? "", "virtualTop": position["top"] ?? NSNull(),
                    "markedReadingPassage": anchor?["id"] as? String == "resize-reading-passage",
                    "captureEpochs": ["transaction": stamp.transaction, "offset": stamp.offset,
                        "input": stamp.input, "intent": stamp.intent]]
                self.apply(self.fence.target)
            } else {
                guard let captured = self.captured else { return }
                guard self.fence.matches(captured) else {
                    self.finish("native-offset-or-input-superseded", preserved: false); return
                }
                guard revision == self.fence.revision,
                      let x = value["x"] as? Double, x.isFinite,
                      let y = value["y"] as? Double, y.isFinite else { return }
                let scroll = web.scrollView
                let ready = self.displayed(web) && self.idle(scroll) && web.bounds.size == self.fence.target &&
                    self.geometry(metrics, web: web)
                // Current unit/zero-inset geometry is required above. Clamp
                // only the computed destination, never a stale DOM origin.
                let destination = CGPoint(x: min(max(0, CGFloat(x)), max(0, scroll.contentSize.width - scroll.bounds.width)),
                    y: min(max(0, CGFloat(y)), max(0, scroll.contentSize.height - scroll.bounds.height)))
                if self.fence.commit(captured, revision: revision, now: CACurrentMediaTime(), ready: ready, write: {
                    scroll.setContentOffset(destination, animated: false)
                }) { self.finish("native-restore", preserved: true) }
                else if self.fence.expire(now: CACurrentMediaTime()) != nil {
                    self.finish("commit-after-deadline", preserved: false)
                }
            }
        }
    }

    private func finish(_ reason: String, preserved: Bool, retainPosition: Bool = false, releaseFrame: Bool = true) {
        guard let id = session else { return }
        if retainPosition, let token, let position, let captured, fence.matches(captured) {
            retained = Retained(token: token, position: position, stamp: captured, receipt: captureReceipt)
        }
        _ = fence.retire()
        session = nil; position = nil; captured = nil; token = nil
        link?.invalidate(); link = nil
        if releaseFrame { apply(latestTarget) }
        // An accepted setter is not proof of the final painted passage. The
        // unchanged native behavior assertions remain the outcome checks.
        let report: [String: Any] = ["id": id.uuidString, "reason": reason, "nativeSetterAccepted": preserved,
            "processID": Int(ProcessInfo.processInfo.processIdentifier),
            "queries": queries, "target": String(describing: latestTarget),
            "nativeOffset": String(describing: web?.scrollView.contentOffset), "lastGeometry": evidence,
            "capture": captureReceipt]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]),
           let json = String(data: data, encoding: .utf8) { print("NATIVE-RESIZE-OWNER " + json) }
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
    private func geometry(_ metrics: [String: Any], web: WKWebView) -> Bool {
        evidence = ["dom": metrics, "webBounds": String(describing: web.bounds),
            "scrollBounds": String(describing: web.scrollView.bounds),
            "contentSize": String(describing: web.scrollView.contentSize),
            "offset": String(describing: web.scrollView.contentOffset),
            "insets": String(describing: web.scrollView.adjustedContentInset),
            "pageZoom": web.pageZoom, "zoomScale": web.scrollView.zoomScale]
        func reject(_ reason: String) -> Bool { evidence["reason"] = reason; return false }
        func number(_ key: String) -> CGFloat? {
            guard let value = metrics[key] as? Double, value.isFinite, value > 0 else { return nil }
            return CGFloat(value)
        }
        func near(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) <= 1 }
        func same(_ a: CGSize, _ b: CGSize) -> Bool { near(a.width, b.width) && near(a.height, b.height) }
        guard let width = number("width"), let height = number("height"),
              let contentWidth = number("contentWidth"), let contentHeight = number("contentHeight") else { return reject("invalid-dom-dimensions") }
        let scroll = web.scrollView, size = CGSize(width: width, height: height)
        let content = CGSize(width: contentWidth, height: contentHeight)
        guard abs(web.pageZoom - 1) < 0.0001, abs(scroll.zoomScale - 1) < 0.0001,
              scroll.contentInset == .zero, scroll.adjustedContentInset == .zero else { return reject("unsupported-scale-or-insets") }
        guard web.bounds.origin == .zero, same(web.bounds.size, size), same(scroll.bounds.size, size) else { return reject("viewport-dimensions") }
        guard same(scroll.contentSize, content) else { return reject("content-dimensions") }
        guard let displayed = scroll.layer.presentation(), same(displayed.bounds.size, size),
              near(scroll.bounds.minX, scroll.contentOffset.x), near(scroll.bounds.minY, scroll.contentOffset.y),
              near(displayed.bounds.minX, scroll.contentOffset.x), near(displayed.bounds.minY, scroll.contentOffset.y) else { return reject("native-model-presentation") }
        let children = scroll.subviews.filter { !$0.isHidden && $0.alpha > 0.01 && same($0.bounds.size, content) }
        guard !children.isEmpty else { return reject("missing-native-content") }
        func identity(_ layer: CALayer, to parent: CALayer) -> Bool {
            guard CATransform3DIsAffine(layer.transform), CATransform3DIsAffine(parent.sublayerTransform) else { return false }
            return [CGPoint.zero, CGPoint(x: 1, y: 0), CGPoint(x: 0, y: 1)].allSatisfy {
                let mapped = layer.convert($0, to: parent)
                return abs(mapped.x - $0.x) < 0.0001 && abs(mapped.y - $0.y) < 0.0001
            }
        }
        let identityMapping = children.allSatisfy { view in
            guard let shown = view.layer.presentation(), same(shown.bounds.size, content) else { return false }
            return identity(view.layer, to: scroll.layer) && identity(shown, to: displayed)
        }
        evidence["reason"] = identityMapping ? "matching-geometry" : "effective-content-mapping"
        return identityMapping
    }
}

@MainActor
final class MobileNativeResizeViewportDiagnostic: UIView {
    let web: WKWebView
    let owner: MobileNativeResizeOwnerDiagnostic
    init(web: WKWebView, owner: MobileNativeResizeOwnerDiagnostic) {
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
#endif
