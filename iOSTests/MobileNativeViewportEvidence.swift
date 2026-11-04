import UIKit

// TEMPORARY diagnostic-only snapshots. Read public geometry without changing
// delegates, layout, scrolling, focus, animation, or test readiness conditions.
@MainActor
enum MobileNativeViewportEvidence {
    static func capture(_ scroll: UIScrollView) -> [String: Any] {
        func insets(_ value: UIEdgeInsets) -> [Double] {
            [Double(value.top), Double(value.left), Double(value.bottom), Double(value.right)]
        }
        func affine(_ value: CGAffineTransform) -> [Double] {
            [Double(value.a), Double(value.b), Double(value.c), Double(value.d), Double(value.tx), Double(value.ty)]
        }
        func rect(_ value: CGRect) -> [Double] {
            [Double(value.origin.x), Double(value.origin.y), Double(value.width), Double(value.height)]
        }
        func view(_ value: UIView, depth: Int) -> [String: Any] {
            var result: [String: Any] = [
                "class": String(describing: type(of: value)),
                "identity": String(describing: ObjectIdentifier(value)),
                "bounds": rect(value.bounds), "frame": rect(value.frame),
                "transform": affine(value.transform),
                "layerAffine": affine(value.layer.affineTransform()),
                "layerTransform3D": String(describing: value.layer.transform),
                "layerPosition": [Double(value.layer.position.x), Double(value.layer.position.y)],
                "layerAnchor": [Double(value.layer.anchorPoint.x), Double(value.layer.anchorPoint.y)],
                "hidden": value.isHidden, "alpha": Double(value.alpha)]
            if let presentation = value.layer.presentation() {
                result["presentationBounds"] = rect(presentation.bounds)
                result["presentationAffine"] = affine(presentation.affineTransform())
                result["presentationPosition"] = [Double(presentation.position.x), Double(presentation.position.y)]
            }
            if depth > 0 { result["children"] = value.subviews.prefix(16).map { view($0, depth: depth - 1) } }
            return result
        }
        return ["zoomScale": Double(scroll.zoomScale), "minimumZoomScale": Double(scroll.minimumZoomScale),
            "maximumZoomScale": Double(scroll.maximumZoomScale), "zooming": scroll.isZooming,
            "zoomBouncing": scroll.isZoomBouncing, "adjustedContentInset": insets(scroll.adjustedContentInset),
            "contentInset": insets(scroll.contentInset), "scrollView": view(scroll, depth: 2)]
    }
}
