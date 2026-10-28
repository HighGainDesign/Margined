import SwiftUI
import UIKit
import XCTest
@testable import MarginediOS

@MainActor
final class MobileAppearanceTests: XCTestCase {
    func testOpeningScreenAndNavigationChromeFollowAppearanceAndReturnToSystem() async throws {
        let defaults = ReaderPreferences.defaults
        let original = defaults.object(forKey: ReaderPreferences.appearanceKey)
        let originalGuide = defaults.object(forKey: "mobileSetupGuideSeen")
        defaults.set(true, forKey: "mobileSetupGuideSeen")
        defaults.set("light", forKey: ReaderPreferences.appearanceKey)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let host = UIHostingController(rootView: MobileRootView(playback: MobilePlaybackOwner(), imageFolders: MobileImageFolders()))
        let window = UIWindow(windowScene: scene)
        window.overrideUserInterfaceStyle = .dark
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true; window.rootViewController = nil
            defaults.set(original, forKey: ReaderPreferences.appearanceKey)
            defaults.set(originalGuide, forKey: "mobileSetupGuideSeen")
        }
        for (mode, expected) in [("light", UIUserInterfaceStyle.light), ("dark", .dark), ("system", .dark)] {
            defaults.set(mode, forKey: ReaderPreferences.appearanceKey)
            for _ in 0..<100 {
                if host.view.traitCollection.userInterfaceStyle == expected { break }
                try await Task.sleep(for: .milliseconds(25))
            }
            XCTAssertEqual(host.view.traitCollection.userInterfaceStyle, expected,
                           "Appearance must include the library and navigation, and System must inherit its window")
        }
    }
}
