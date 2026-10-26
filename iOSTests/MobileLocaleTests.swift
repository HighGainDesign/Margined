import XCTest
@testable import MarginediOS

final class MobileLocaleTests: XCTestCase {
    func testAllInterfaceLocalesContainMobileStrings() throws {
        for locale in ["en", "es", "zh-Hans", "zh-Hant", "ja", "fr", "de"] {
            let path = try XCTUnwrap(Bundle.main.path(forResource: locale, ofType: "lproj"))
            let bundle = try XCTUnwrap(Bundle(path: path))
            let missing = "__MARGINED_MISSING_LOCALIZATION__"
            let unknown = ["Margined", "Deliberately", "Unknown", "Localization"].joined(separator: "-")
            XCTAssertEqual(bundle.localizedString(forKey: unknown, value: missing, table: "Localizable"), missing,
                           "The missing-resource control must reject a key absent from this locale")
            for key in ["Open Sample Document", "Your Markdown, clearly.", "Save Checkmarks to This File?", "Playback Options", "Inspector", "Close Inspector", "Close Outline", "Changes", "Discussions"] {
                let value = bundle.localizedString(forKey: key, value: locale == "en" ? key : missing, table: "Localizable")
                XCTAssertFalse(value.isEmpty)
                XCTAssertNotEqual(value, missing, "Missing \(locale): \(key)")
            }
        }
    }
}
