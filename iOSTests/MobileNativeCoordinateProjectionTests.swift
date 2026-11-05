import XCTest
@testable import MarginediOS

final class MobileNativeCoordinateProjectionTests: XCTestCase {
    func testRealPinchProjectsNativeViewportIntoCSSAndBack() throws {
        let scale = 1.782689443334461
        let mapping = try XCTUnwrap(MobileNativeCoordinateProjection(
            zero: .zero, unitX: CGPoint(x: scale, y: 0), unitY: CGPoint(x: 0, y: scale), pageZoom: 1))
        let viewport = mapping.cssViewport(CGRect(x: 157.33333333333334, y: 6835, width: 402, height: 610.6666666666666))
        XCTAssertEqual(viewport.minY, 3834.0946178574777, accuracy: 0.0001)
        XCTAssertEqual(viewport.width, 225.50198045043248, accuracy: 0.0001)
        XCTAssertEqual(mapping.nativePoint(viewport.origin).y, 6835, accuracy: 0.0001)
    }

    func testPageZoomAndPinchComposeRatherThanReplacingEachOther() throws {
        let mapping = try XCTUnwrap(MobileNativeCoordinateProjection(
            zero: .zero, unitX: CGPoint(x: 2.0 / 3, y: 0), unitY: CGPoint(x: 0, y: 2.0 / 3), pageZoom: 1.5))
        XCTAssertEqual(mapping.cssViewport(CGRect(x: 0, y: 3700, width: 402, height: 611)).minY, 3700, accuracy: 0.0001)
        XCTAssertEqual(mapping.nativePoint(CGPoint(x: 22, y: 3700)).y, 3700, accuracy: 0.0001)
    }

    func testTranslationAndNegativeInsetOriginRoundTrip() throws {
        let mapping = try XCTUnwrap(MobileNativeCoordinateProjection(
            zero: CGPoint(x: 10, y: 15), unitX: CGPoint(x: 12, y: 15), unitY: CGPoint(x: 10, y: 17), pageZoom: 1))
        let viewport = mapping.cssViewport(CGRect(x: -12, y: -20, width: 400, height: 600))
        XCTAssertEqual(viewport.minX, -11)
        XCTAssertEqual(viewport.minY, -17.5)
        XCTAssertEqual(mapping.nativePoint(viewport.origin), CGPoint(x: -12, y: -20))
    }

    func testRejectsRotatedSkewedSingularAndNonfiniteMappings() {
        for (x,y) in [(CGPoint(x:0,y:1),CGPoint(x:-1,y:0)),
                      (CGPoint(x:1,y:0),CGPoint(x:0.2,y:1)),
                      (.zero,CGPoint(x:0,y:1)),
                      (CGPoint(x:Double.nan,y:0),CGPoint(x:0,y:1))] {
            XCTAssertNil(MobileNativeCoordinateProjection(zero:.zero,unitX:x,unitY:y,pageZoom:1))
        }
    }
}
