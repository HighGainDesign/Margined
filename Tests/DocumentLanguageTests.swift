import XCTest
import SwiftSoup
@testable import Margined

final class DocumentLanguageTests: XCTestCase {
    func testSelectedLanguageIsValidatedAndIndependentOfContentLanguage() async throws {
        XCTAssertEqual(DocumentLanguage.normalized(" en_us "),"en-US")
        XCTAssertEqual(DocumentLanguage.normalized("zh-hant"),"zh-Hant")
        XCTAssertNil(DocumentLanguage.normalized("en\" onload=\"alert(1)"))
        XCTAssertNil(DocumentLanguage.normalized("javascript:en"))
        let output = try await MarkdownRenderer.shared.render(Self.french,documentLanguage:"ja")
        let document = try SwiftSoup.parse(output.html)
        XCTAssertEqual(try document.select("html").attr("lang"),"ja")
        XCTAssertEqual(try document.select("main").attr("dir"),"auto")
        XCTAssertEqual(output.documentLanguage,"ja")
    }

    func testConfidentFrenchDetectionDoesNotInheritEnglishInterface() async throws {
        let output = try await MarkdownRenderer.shared.render(Self.french)
        XCTAssertEqual(output.documentLanguage,"fr")
        XCTAssertEqual(try SwiftSoup.parse(output.html).select("html").attr("lang"),"fr")
    }

    func testUnknownAndInvalidLanguageNeverBecomeFalseEnglishOrAttributes() async throws {
        let unknown = try await MarkdownRenderer.shared.render("1234\n")
        XCTAssertNil(unknown.documentLanguage)
        XCTAssertFalse(try SwiftSoup.parse(unknown.html).select("html").first()!.hasAttr("lang"))
        let invalid = try await MarkdownRenderer.shared.render("1234\n",documentLanguage:"en\" onload=\"alert(1)")
        let document = try SwiftSoup.parse(invalid.html)
        XCTAssertFalse(try document.select("html").first()!.hasAttr("onload"))
        XCTAssertFalse(try document.select("html").first()!.hasAttr("lang"))
    }

    func testArabicDocumentKeepsItsOwnDirectionAndLanguage() async throws {
        let source = "# خطة العمل\n\nهذه وثيقة تشرح خطة العمل الجديدة وتساعد القارئ على متابعة المهام والنتائج. يمكن قراءة الأقسام ومراجعة التغييرات والتنقل بين العناوين دون تغيير محتوى الملف الأصلي.\n"
        let output = try await MarkdownRenderer.shared.render(source,documentLanguage:"ar")
        let document = try SwiftSoup.parse(output.html)
        XCTAssertEqual(output.documentLanguage,"ar")
        XCTAssertTrue(try document.select("h1").text().contains("خطة العمل"))
        XCTAssertEqual(try document.select("main").attr("dir"),"auto")
    }

    private static let french = """
    # Une journée de lecture

    Aujourd’hui nous préparons un document pour expliquer les changements apportés au projet. Chaque section présente les objectifs, les résultats et les prochaines étapes. Le lecteur peut parcourir les titres, consulter les tableaux et retrouver facilement le passage qu’il était en train de lire.
    """
}
