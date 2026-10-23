import XCTest
@testable import MarginediOS

final class MobileLocaleTests: XCTestCase {
    func testAllInterfaceLocalesContainMobileStrings() throws {
        for locale in ["en", "es", "zh-Hans", "zh-Hant", "ja", "fr", "de"] {
            let path = try XCTUnwrap(Bundle.main.path(forResource: locale, ofType: "lproj"))
            let bundle = try XCTUnwrap(Bundle(path: path))
            for key in ["Open Sample Document", "Your Markdown, clearly.", "Save Checkmarks to This File?", "Playback Options"] {
                let value = bundle.localizedString(forKey: key, value: nil, table: "Localizable")
                XCTAssertFalse(value.isEmpty)
                if locale != "en" { XCTAssertNotEqual(value, key, "Missing \(locale): \(key)") }
            }
        }
    }
}
