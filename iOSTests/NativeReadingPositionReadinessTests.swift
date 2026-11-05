import QuartzCore
import XCTest

@MainActor
final class NativeReadingPositionReadinessTests: XCTestCase {
    func testEquivalentAnchorRepresentationsHaveIdentityMapping() {
        let parent = CALayer()
        parent.bounds = CGRect(x: 0, y: 978, width: 358, height: 71)
        let content = CALayer()
        content.bounds = CGRect(x: 0, y: 0, width: 358, height: 2112)
        parent.addSublayer(content)
        content.anchorPoint = .zero; content.position = .zero
        XCTAssertTrue(NativeReadingLayerMapping.isIdentity(content, to: parent))
        content.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        content.position = CGPoint(x: 179, y: 1056)
        XCTAssertTrue(NativeReadingLayerMapping.isIdentity(content, to: parent),
                      "Equivalent centered anchors must not make a coherent viewport fail readiness")
    }

    func testTranslatedScaledAndPerspectiveMappingsAreRejected() {
        let parent = CALayer(), content = CALayer()
        parent.addSublayer(content)
        content.anchorPoint = .zero; content.position = .zero
        for transform in [CATransform3DMakeTranslation(0, 20, 0), CATransform3DMakeScale(1, 1.2, 1)] {
            content.transform = transform
            XCTAssertFalse(NativeReadingLayerMapping.isIdentity(content, to: parent))
        }
        content.transform = CATransform3DIdentity
        var perspective = CATransform3DIdentity; perspective.m34 = 0.001
        parent.sublayerTransform = perspective
        XCTAssertFalse(NativeReadingLayerMapping.isIdentity(content, to: parent))
    }
}
