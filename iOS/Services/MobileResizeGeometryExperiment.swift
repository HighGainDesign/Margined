#if MARGINED_RESIZE_GEOMETRY_EXPERIMENT
import UIKit
import WebKit

/// Temporary timing experiment. Never include this gate in release artifacts.
/// It checks layout dimensions and effective mapping, deliberately not origin
/// agreement or semantic visibility: those are outcomes of the pending restore.
@MainActor
final class MobileResizeGeometryExperiment: NSObject, WKScriptMessageHandlerWithReply {
    private struct Request {
        let token: String
        let lease: Int
        let revision: Int
        let viewport: CGSize
        let content: CGSize
        let started: CFTimeInterval
        let reply: @MainActor (Any?, String?) -> Void
    }
    @MainActor private final class Pulse: NSObject {
        weak var owner: MobileResizeGeometryExperiment?
        init(_ owner: MobileResizeGeometryExperiment) { self.owner = owner }
        @objc func tick() { owner?.check() }
    }
    private weak var web: WKWebView?
    private let accepts: @MainActor (String) -> Bool
    private var pending: Request?
    private var link: CADisplayLink?
    private var token = ""
    private var highestLease = 0
    private var highestRevision = 0
    private var evidence: [String: Any] = [:]

    init(web: WKWebView, accepts: @escaping @MainActor (String) -> Bool) {
        self.web = web
        self.accepts = accepts
    }

    func invalidate() { resolve(false, reason: "invalidated") }

    func userContentController(_ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage, replyHandler: @escaping @MainActor (Any?, String?) -> Void) {
        guard message.frameInfo.isMainFrame, message.webView === web,
              let body = message.body as? [String: Any], let incomingToken = body["token"] as? String,
              accepts(incomingToken), let lease = body["lease"] as? Int, lease > 0,
              let revision = body["revision"] as? Int, revision > 0,
              let kind = body["kind"] as? String, ["wait", "cancel", "restored"].contains(kind) else {
            replyHandler(["ready": false, "reason": "invalid-request"], nil); return
        }
        if kind == "restored" {
            let report: [String: Any] = ["lease": lease, "revision": revision,
                "x": body["x"] as? Double ?? -1, "y": body["y"] as? Double ?? -1]
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]),
               let json = String(data: data, encoding: .utf8) { print("RESIZE-GEOMETRY-DOM-RESTORED \(json)") }
            replyHandler(["ready": false, "reason": "trace-only"], nil); return
        }
        if token != incomingToken {
            resolve(false, reason: "document-replaced")
            token = incomingToken; highestLease = 0; highestRevision = 0
        }
        guard lease > highestLease || (lease == highestLease && revision > highestRevision) else {
            replyHandler(["ready": false, "reason": "retired-request"], nil); return
        }
        highestLease = lease; highestRevision = revision
        resolve(false, reason: kind == "cancel" ? "cancelled" : "superseded")
        if kind == "cancel" { replyHandler(["ready": false, "reason": "cancelled"], nil); return }
        func positive(_ key: String) -> Double? {
            guard let value = body[key] as? Double, value.isFinite, value > 0 else { return nil }
            return value
        }
        guard let width = positive("width"), let height = positive("height"),
              let contentWidth = positive("contentWidth"), let contentHeight = positive("contentHeight") else {
            replyHandler(["ready": false, "reason": "invalid-dimensions"], nil); return
        }
        pending = Request(token: incomingToken, lease: lease, revision: revision,
            viewport: CGSize(width: width, height: height), content: CGSize(width: contentWidth, height: contentHeight),
            started: CACurrentMediaTime(), reply: replyHandler)
        evidence = [:]
        let pulse = CADisplayLink(target: Pulse(self), selector: #selector(Pulse.tick))
        link = pulse
        pulse.add(to: .main, forMode: .common)
        check()
    }

    private func check() {
        guard let request = pending else { return }
        guard accepts(request.token), let web, let window = web.window,
              !window.isHidden, !web.isHidden, web.alpha > 0.01,
              web.convert(web.bounds, to: window).intersects(window.bounds) else {
            resolve(false, reason: "document-not-displayed"); return
        }
        let scroll = web.scrollView
        func near(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) <= 1 }
        func sameSize(_ a: CGSize, _ b: CGSize) -> Bool { near(a.width, b.width) && near(a.height, b.height) }
        evidence = ["webBounds": String(describing: web.bounds), "scrollBounds": String(describing: scroll.bounds),
            "contentSize": String(describing: scroll.contentSize), "offset": String(describing: scroll.contentOffset),
            "pageZoom": web.pageZoom, "zoomScale": scroll.zoomScale]
        guard abs(web.pageZoom - 1) < 0.0001, abs(scroll.zoomScale - 1) < 0.0001,
              !scroll.isZooming, !scroll.isZoomBouncing,
              scroll.contentInset == .zero, scroll.adjustedContentInset == .zero else {
            resolve(false, reason: "unsupported-scale-or-insets"); return
        }
        // This deadline only bounds diagnostic work. It NEVER grants readiness.
        if CACurrentMediaTime() - request.started >= 3 {
            resolve(false, reason: "diagnostic-budget-expired"); return
        }
        guard web.bounds.origin == .zero, sameSize(web.bounds.size, request.viewport),
              sameSize(scroll.bounds.size, request.viewport) else {
            evidence["waiting"] = "viewport-size"; return
        }
        guard sameSize(scroll.contentSize, request.content) else { evidence["waiting"] = "content-size"; return }
        guard let displayedScroll = scroll.layer.presentation(),
              sameSize(displayedScroll.bounds.size, request.viewport) else {
            evidence["waiting"] = "scroll-presentation-size"; return
        }
        let candidates = scroll.subviews.filter { !$0.isHidden && $0.alpha > 0.01 && sameSize($0.bounds.size, request.content) }
        evidence["contentCandidates"] = candidates.count
        guard !candidates.isEmpty else { evidence["waiting"] = "content-view"; return }
        for view in candidates {
            guard Self.identity(view.layer, to: scroll.layer), let displayed = view.layer.presentation(),
                  sameSize(displayed.bounds.size, request.content), Self.identity(displayed, to: displayedScroll) else {
                evidence["waiting"] = "effective-content-mapping"; return
            }
        }
        resolve(true, reason: "matching-geometry")
    }

    private static func identity(_ layer: CALayer, to parent: CALayer) -> Bool {
        guard CATransform3DIsAffine(layer.transform), CATransform3DIsAffine(parent.sublayerTransform) else { return false }
        for point in [CGPoint.zero, CGPoint(x: 1, y: 0), CGPoint(x: 0, y: 1)] {
            let mapped = layer.convert(point, to: parent)
            guard abs(mapped.x - point.x) < 0.0001, abs(mapped.y - point.y) < 0.0001 else { return false }
        }
        return true
    }

    private func resolve(_ ready: Bool, reason: String) {
        guard let request = pending else { return }
        pending = nil
        link?.invalidate(); link = nil
        let report: [String: Any] = ["lease": request.lease, "revision": request.revision,
            "ready": ready, "reason": reason, "elapsed": CACurrentMediaTime() - request.started,
            "requestedViewport": String(describing: request.viewport), "requestedContent": String(describing: request.content),
            "native": evidence]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]),
           let json = String(data: data, encoding: .utf8) { print("RESIZE-GEOMETRY-EXPERIMENT \(json)") }
        request.reply(["ready": ready, "reason": reason], nil)
    }
}
#endif
