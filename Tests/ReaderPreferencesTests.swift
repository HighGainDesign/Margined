import AppKit
import XCTest
@testable import Margined

final class ReaderPreferencesTests: XCTestCase {
    @MainActor
    func testAppearanceChangesTheApplicationAndRestoresSystemForEveryWindow() async throws {
        let defaults = ReaderPreferences.defaults
        let original = defaults.object(forKey: ReaderPreferences.appearanceKey)
        let originalAppearance = NSApp.appearance
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 620, height: 500),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer {
            defaults.set(original, forKey: ReaderPreferences.appearanceKey)
            NSApp.appearance = originalAppearance
            window.close()
        }
        for (mode, expected) in [(DocumentAppearance.dark, NSAppearance.Name.darkAqua), (.light, .aqua)] {
            defaults.set(mode.rawValue, forKey: ReaderPreferences.appearanceKey)
            for _ in 0..<100 {
                if NSApp.appearance?.name == expected { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertEqual(NSApp.appearance?.name, expected,
                           "Welcome, settings, title bars and future windows must share the selected appearance")
            XCTAssertEqual(window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]), expected)
        }
        defaults.set(DocumentAppearance.system.rawValue, forKey: ReaderPreferences.appearanceKey)
        for _ in 0..<100 {
            if NSApp.appearance == nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertNil(NSApp.appearance, "System must remove the application override")
    }

    override class func tearDown() {
        ReaderPreferences.defaults.removePersistentDomain(forName: "MarginedTests.ReaderPreferences.\(ProcessInfo.processInfo.processIdentifier)")
        super.tearDown()
    }

    func testIndependentPreferenceReadersSeeChangesAndSafelyDefaultToSystem() throws {
        let suite = "MarginedTests.PreferenceReaders.\(UUID().uuidString)"
        let app = try XCTUnwrap(UserDefaults(suiteName: suite))
        let preview = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { app.removePersistentDomain(forName: suite) }
        XCTAssertEqual(ReaderPreferences.appearance(in: preview), .system)
        for appearance in DocumentAppearance.allCases {
            app.set(appearance.rawValue, forKey: ReaderPreferences.appearanceKey)
            XCTAssertEqual(ReaderPreferences.appearance(in: preview), appearance)
        }
        app.set("unknown", forKey: ReaderPreferences.appearanceKey)
        XCTAssertEqual(ReaderPreferences.appearance(in: preview), .system)
    }
}
