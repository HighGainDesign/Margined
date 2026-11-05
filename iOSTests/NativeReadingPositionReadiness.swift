import QuartzCore

@MainActor
enum NativeReadingLayerMapping {
    static func isIdentity(_ layer: CALayer, to parent: CALayer) -> Bool {
        guard CATransform3DIsAffine(layer.transform), CATransform3DIsAffine(parent.sublayerTransform) else { return false }
        for point in [CGPoint.zero, CGPoint(x: 1, y: 0), CGPoint(x: 0, y: 1)] {
            let mapped = layer.convert(point, to: parent)
            guard abs(mapped.x - point.x) < 0.0001, abs(mapped.y - point.y) < 0.0001 else { return false }
        }
        return true
    }
}

#if canImport(UIKit)
import UIKit
import WebKit

/// This fixture requires an unzoomed viewport with matching native and DOM
/// coordinates before it can perform another action from that reading position.
@MainActor
enum NativeReadingPositionReadiness {
    static func matches(_ metrics: [String: Any], web: WKWebView, window: UIWindow,
        evidence: inout [String: Any]) -> Bool {
        func number(_ key: String) -> Double? {
            guard let value = metrics[key] as? Double, value.isFinite else { return nil }
            return value
        }
        func near(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) <= 1 }
        func sameSize(_ a: CGSize, _ b: CGSize) -> Bool {
            near(a.width, b.width) && near(a.height, b.height)
        }
        func reject(_ reason: String) -> Bool { evidence["reason"] = reason; return false }
        let scroll = web.scrollView
        let webBounds = web.bounds, scrollBounds = scroll.bounds, offset = scroll.contentOffset
        let contentSize = scroll.contentSize, inset = scroll.contentInset, adjusted = scroll.adjustedContentInset
        let pageZoom = web.pageZoom, zoom = scroll.zoomScale
        let presentation = scroll.layer.presentation()
        evidence = ["dom": metrics, "webBounds": String(describing: webBounds),
            "scrollBounds": String(describing: scrollBounds), "offset": String(describing: offset),
            "contentSize": String(describing: contentSize), "inset": String(describing: inset),
            "adjustedInset": String(describing: adjusted), "pageZoom": pageZoom, "zoomScale": zoom,
            "scrollPresentationBounds": String(describing: presentation?.bounds),
            "attached": web.window === window, "windowKey": window.isKeyWindow,
            "windowHidden": window.isHidden, "webHidden": web.isHidden, "webAlpha": web.alpha]
        guard metrics["semanticVisible"] as? Bool == true else { return reject("paragraph is outside the requested semantic position") }
        guard let x = number("x"), let y = number("y"),
              let width = number("width"), let height = number("height"),
              let contentWidth = number("contentWidth"), let contentHeight = number("contentHeight"),
              width > 0, height > 0, contentWidth > 0, contentHeight > 0 else { return reject("missing or invalid DOM dimensions") }
        guard web.window === window, !window.isHidden, window.isKeyWindow,
              !web.isHidden, web.alpha > 0.01,
              web.convert(webBounds, to: window).intersects(window.bounds) else { return reject("history is not displayed in its fixture window") }
        guard abs(pageZoom - 1) < 0.0001, abs(zoom - 1) < 0.0001,
              !scroll.isZooming, !scroll.isZoomBouncing,
              inset == .zero, adjusted == .zero else { return reject("fixture does not have unit scale and zero insets") }
        guard webBounds.origin == .zero,
              sameSize(webBounds.size, CGSize(width: width, height: height)),
              sameSize(scrollBounds.size, webBounds.size) else { return reject("native and DOM viewport dimensions differ") }
        guard sameSize(contentSize, CGSize(width: contentWidth, height: contentHeight)) else { return reject("native and DOM content dimensions differ") }
        guard near(offset.x, CGFloat(x)), near(offset.y, CGFloat(y)),
              near(scrollBounds.origin.x, CGFloat(x)), near(scrollBounds.origin.y, CGFloat(y)) else { return reject("native and DOM scroll origins differ") }
        guard let presentation,
              near(presentation.bounds.origin.x, CGFloat(x)), near(presentation.bounds.origin.y, CGFloat(y)),
              sameSize(presentation.bounds.size, scrollBounds.size) else { return reject("native model and presentation bounds differ") }
        // Discover visible content-sized children without private class names.
        let content = scroll.subviews.filter { !$0.isHidden && $0.alpha > 0.01 && sameSize($0.bounds.size, contentSize) }
        evidence["contentCandidates"] = content.count
        guard !content.isEmpty else { return reject("no visible content-sized native child") }
        func layerDetails(_ layer: CALayer) -> [String: String] {
            ["bounds": String(describing: layer.bounds), "position": String(describing: layer.position),
             "anchor": String(describing: layer.anchorPoint), "transform": String(describing: layer.transform)]
        }
        for view in content {
            evidence["contentModel"] = layerDetails(view.layer)
            let displayed = view.layer.presentation()
            evidence["contentPresentation"] = displayed.map { layerDetails($0) } as Any? ?? "none"
            guard NativeReadingLayerMapping.isIdentity(view.layer, to: scroll.layer) else { return reject("content model mapping is not identity") }
            guard let displayed else { return reject("content presentation is unavailable") }
            guard sameSize(displayed.bounds.size, view.bounds.size) else { return reject("content model and presentation sizes differ") }
            guard NativeReadingLayerMapping.isIdentity(displayed, to: presentation) else { return reject("content presentation mapping is not identity") }
        }
        evidence["reason"] = "coherent native and DOM reading position"
        return true
    }
}
#endif
