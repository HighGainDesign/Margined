import Foundation
import XCTest
@testable import Margined

final class ReaderPreferencesTests: XCTestCase {
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
