import Foundation
import XCTest
@testable import Margined

final class LocalizationTests: XCTestCase {
    func testEnglishWordCountUsesSingularAndPluralCatalogForms() {
        let locale = Locale(identifier:"en")
        XCTAssertEqual(String(localized:"\(1) words",locale:locale),"1 word")
        XCTAssertEqual(String(localized:"\(2) words",locale:locale),"2 words")
        XCTAssertEqual(String(localized:"\(0) words",locale:locale),"0 words")
    }

    func testEnglishChangesAndRemainingCountHaveSingularForms() {
        let locale = Locale(identifier:"en")
        XCTAssertEqual(String(localized:"\(1) unreviewed changes available.",locale:locale),"1 unreviewed change available.")
        XCTAssertEqual(String(localized:"\(2) unreviewed changes available.",locale:locale),"2 unreviewed changes available.")
        XCTAssertEqual(String(localized:"\(1) changes remaining.",locale:locale),"1 change remaining.")
        XCTAssertEqual(String(localized:"\(1) unreviewed changes, panel \("shown")",locale:locale),"1 unreviewed change, panel shown")
    }
}

extension LocalizationTests {
    func testActiveProcessLocalizesCommandsAndErrors() {
        // Also run with AppleLanguages configured before this host launches.
        let language = Locale.preferredLanguages.first ?? "en"
        let code = language.hasPrefix("zh") ? (language.contains("Hant") || language.contains("TW") ? "zh-Hant" : "zh-Hans") : String(language.split(separator: "-").first ?? "en")
        let examples = [
            "en": ("Read Aloud", "This file is not UTF-8 or BOM-marked UTF-16 text."),
            "es": ("Leer en voz alta", "Este archivo no es texto UTF-8 ni UTF-16 con BOM."),
            "zh-Hans": ("朗读", "此文件不是 UTF-8 或带 BOM 的 UTF-16 文本。"),
            "zh-Hant": ("朗讀", "此檔案不是 UTF-8 或帶 BOM 的 UTF-16 文字。"),
            "ja": ("読み上げ", "このファイルはUTF-8でもBOM付きUTF-16でもありません。"),
            "fr": ("Lire à voix haute", "Ce fichier n’est ni en UTF-8 ni en UTF-16 avec BOM."),
            "de": ("Vorlesen", "Diese Datei ist weder UTF-8- noch UTF-16-Text mit BOM.")
        ]
        let expected = examples[code] ?? examples["en"]!
        XCTAssertEqual(String(localized: "Read Aloud"), expected.0)
        XCTAssertEqual(ReaderError.invalidEncoding.localizedDescription, expected.1)
    }

    func testCompiledTranslationsAndPluralForms() throws {
        let examples: [(String, String, String, String)] = [
            ("es", "Leer en voz alta", "1 palabra", "2 palabras"),
            ("zh-Hans", "朗读", "1 字", "2 字"),
            ("zh-Hant", "朗讀", "1 字", "2 字"),
            ("ja", "読み上げ", "1 語", "2 語"),
            ("fr", "Lire à voix haute", "1 mot", "2 mots"),
            ("de", "Vorlesen", "1 Wort", "2 Wörter")
        ]
        for (language, title, singular, plural) in examples {
            let path = try XCTUnwrap(Bundle.main.path(forResource: language, ofType: "lproj"), "Missing compiled \(language)")
            let bundle = try XCTUnwrap(Bundle(path: path))
            XCTAssertEqual(bundle.localizedString(forKey: "Read Aloud", value: nil, table: nil), title)
            XCTAssertEqual(String(localized: "\(1) words", bundle: bundle, locale: Locale(identifier: language)), singular)
            XCTAssertEqual(String(localized: "\(2) words", bundle: bundle, locale: Locale(identifier: language)), plural)
        }
    }
}
