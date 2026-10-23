import XCTest
@testable import Margined

@MainActor
final class SpeechPreferencesTests: XCTestCase {
    func testReadingPreferencesPersistAndClampInvalidRates() {
        let name = "MarginedTests.SpeechPrefs.\(UUID())", defaults: UserDefaults
        defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let first = SpeechPreferences(defaults: defaults)
        XCTAssertEqual(first.rate, 1)
        XCTAssertTrue(first.followReading)
        first.rate = 9
        XCTAssertEqual(first.rate, 2)
        first.rate = .nan
        XCTAssertEqual(first.rate, 1)
        first.rate = 1.25
        first.followReading = false
        first.options = SpeechOptions(includeCode: true, includeLinkDestinations: true)
        first.setVoice("french-voice", for: "fr")
        first.setVoice("japanese-voice", for: "ja")
        let restored = SpeechPreferences(defaults: defaults)
        XCTAssertEqual(restored.rate, 1.25)
        XCTAssertFalse(restored.followReading)
        XCTAssertTrue(restored.options.includeCode)
        XCTAssertTrue(restored.options.includeLinkDestinations)
        XCTAssertEqual(restored.voice(for: "fr-CA"), "french-voice")
        XCTAssertEqual(restored.voice(for: "ja"), "japanese-voice")
        XCTAssertNil(restored.voice(for: "de"))
        restored.setVoice(nil, for: "fr")
        XCTAssertNil(SpeechPreferences(defaults: defaults).voice(for: "fr"))
    }
}
