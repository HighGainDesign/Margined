import SwiftUI
import UIKit
import Vision
import XCTest
@testable import MarginediOS

@MainActor
final class MobileTutorialPresentationTests: XCTestCase {
    func testGuideShowsItsExitWithoutSelectingALesson() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let presenter = UIViewController(), window = UIWindow(windowScene: scene)
        window.rootViewController = presenter; window.makeKeyAndVisible()
        let guide = UIHostingController(rootView: MobileSetupGuide(imageFolders: MobileImageFolders(), foldersChanged: {},
            tutorial: TutorialSession(platform: .mobile), openPractice: { _ in }))
        presenter.present(guide, animated: false)
        defer { presenter.dismiss(animated: false); window.isHidden = true; window.rootViewController = nil }
        for _ in 0..<100 where guide.view.window == nil { try await Task.sleep(for: .milliseconds(20)) }
        var text = ""
        for _ in 0..<30 {
            guide.view.layoutIfNeeded()
            let image = UIGraphicsImageRenderer(bounds: guide.view.bounds).image { _ in
                guide.view.drawHierarchy(in: guide.view.bounds, afterScreenUpdates: true)
            }
            let request = VNRecognizeTextRequest(); request.recognitionLevel = .accurate; request.recognitionLanguages = ["en-US"]
            try VNImageRequestHandler(cgImage: XCTUnwrap(image.cgImage)).perform([request])
            text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
            if text.contains("Done") { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(text.contains("Done"), "A first-time guide must show its exit before a lesson is selected: \(text)")
    }
}
