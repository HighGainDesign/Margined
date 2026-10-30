import SwiftUI
import UIKit
import XCTest
@testable import MarginediOS

@MainActor
final class MobileAppearanceTests: XCTestCase {
    func testPresentedStartupGuideTracksWholeAppAppearance() async throws {
        let defaults = ReaderPreferences.defaults
        let original = defaults.object(forKey: ReaderPreferences.appearanceKey)
        let originalGuide = defaults.object(forKey: "mobileSetupGuideSeen")
        defaults.set(false, forKey: "mobileSetupGuideSeen")
        defaults.set("light", forKey: ReaderPreferences.appearanceKey)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let playback = MobilePlaybackOwner(), folders = MobileImageFolders()
        let host = UIHostingController(rootView: MobileRootView(playback: playback, imageFolders: folders))
        let window = UIWindow(windowScene: scene); window.overrideUserInterfaceStyle = .dark
        window.rootViewController = host; window.makeKeyAndVisible()
        defer {
            host.dismiss(animated: false); window.isHidden = true; window.rootViewController = nil
            defaults.set(original, forKey: ReaderPreferences.appearanceKey)
            defaults.set(originalGuide, forKey: "mobileSetupGuideSeen")
        }
        for _ in 0..<100 where host.view.traitCollection.userInterfaceStyle != .light { try await Task.sleep(for: .milliseconds(20)) }
        for _ in 0..<100 where host.presentedViewController == nil { try await Task.sleep(for: .milliseconds(20)) }
        let sheet = try XCTUnwrap(host.presentedViewController, "Exercise the app's real SwiftUI presentation, not an unrelated UIKit modal")
        XCTAssertNotNil(sheet.view.window)
        for (mode, expected) in [("light", UIUserInterfaceStyle.light), ("dark", .dark), ("system", .dark)] {
            defaults.set(mode, forKey: ReaderPreferences.appearanceKey)
            for _ in 0..<100 where sheet.view.traitCollection.userInterfaceStyle != expected { try await Task.sleep(for: .milliseconds(20)) }
            XCTAssertEqual(sheet.view.traitCollection.userInterfaceStyle, expected,
                           "A presented app-owned sheet must follow appearance changes without reopening")
        }
    }

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
