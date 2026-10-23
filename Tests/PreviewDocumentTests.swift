import Foundation
import SwiftSoup
import XCTest
#if os(iOS)
@testable import MarginediOS
#else
@testable import Margined
#endif

final class PreviewDocumentTests: XCTestCase {
    private let pixel = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+j5iQAAAAASUVORK5CYII=")!

    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testLocalImageUsesPreviewAttachmentAndKeepsAuthoredSize() async throws {
        let root = try folder()
        try pixel.write(to: root.appendingPathComponent("figure 画像.png"))
        let rendered = try await MarkdownRenderer.shared.render("<img src=\"figure%20画像.png\" alt=\"Example\" width=\"120\" height=\"60\">")
        let preview = try await PreviewDocument.package(html: rendered.html, documentURL: root.appendingPathComponent("review.md"))
        let doc = try SwiftSoup.parse(preview.html)
        let image = try XCTUnwrap(doc.select("img").first())
        let source = try image.attr("src")
        XCTAssertTrue(source.hasPrefix("cid:"), "System Quick Look cannot load the app's private URL scheme")
        let attachment = try XCTUnwrap(preview.attachments[String(source.dropFirst(4))])
        XCTAssertEqual(attachment.data, pixel)
        XCTAssertEqual(attachment.contentTypeIdentifier, "public.png")
        XCTAssertEqual(try image.attr("width"), "120")
        XCTAssertEqual(try image.attr("height"), "60")
        XCTAssertEqual(try image.attr("alt"), "Example")
    }

    func testDuplicateRelativeAbsoluteAndSymlinkPathsShareOneAttachment() async throws {
        let root = try folder()
        let notes = root.appendingPathComponent("notes")
        try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
        let image = root.appendingPathComponent("figure.png")
        try pixel.write(to: image)
        try FileManager.default.createSymbolicLink(at: notes.appendingPathComponent("linked.png"), withDestinationURL: image)
        let rendered = try await MarkdownRenderer.shared.render("![parent](../figure.png) ![absolute](\(image.path)) ![link](linked.png)")
        let preview = try await PreviewDocument.package(html: rendered.html, documentURL: notes.appendingPathComponent("review.md"))
        let images = try SwiftSoup.parse(preview.html).select("img").array()
        XCTAssertEqual(images.count, 3)
        XCTAssertEqual(preview.attachments.count, 1)
        XCTAssertEqual(Set(try images.map { try $0.attr("src") }).count, 1)
    }

    func testMissingDirectoryAndOversizedImagesKeepAlternativeText() async throws {
        let root = try folder()
        try Data(repeating: 0, count: 8 * 1_024 * 1_024 + 1).write(to: root.appendingPathComponent("huge.png"))
        try FileManager.default.createDirectory(at: root.appendingPathComponent("directory.png"), withIntermediateDirectories: true)
        let rendered = try await MarkdownRenderer.shared.render("![Missing](gone.png) ![Directory](directory.png) ![Large](huge.png)")
        let preview = try await PreviewDocument.package(html: rendered.html, documentURL: root.appendingPathComponent("review.md"))
        let images = try SwiftSoup.parse(preview.html).select("img").array()
        XCTAssertEqual(try images.map { try $0.attr("alt") }, ["Missing", "Directory", "Large"])
        XCTAssertTrue(try images.allSatisfy { try $0.attr("src").isEmpty })
        XCTAssertTrue(preview.attachments.isEmpty)
    }

    func testPreviewKeepsOfflineArtworkAndBlocksRemoteResources() async throws {
        let root = try folder()
        let file = root.appendingPathComponent("review.md")
        let source = "# Preview\n\n> [!NOTE]\n> Offline.\n\n$x^2$\n\n![Tracker](https://example.invalid/pixel.png)\n\n<script>alert(1)</script>\n\n<form><input></form>\n\n- [ ] Task\n"
        try Data(source.utf8).write(to: file)
        let preview = try await PreviewDocument.load(file, appearance: .light)
        let doc = try SwiftSoup.parse(preview.html)
        XCTAssertEqual(try doc.select("html").attr("data-appearance"), "light")
        XCTAssertEqual(try doc.select("blockquote.margined-alert-note").size(), 1)
        XCTAssertEqual(try doc.select("math").size(), 1)
        XCTAssertEqual(try doc.select("input[type=checkbox][disabled]").size(), 1)
        XCTAssertEqual(try doc.select("script, form").size(), 0)
        let csp = try doc.select("meta[http-equiv=Content-Security-Policy]").attr("content")
        XCTAssertTrue(csp.contains("default-src 'none'"))
        XCTAssertTrue(csp.contains("img-src cid: data:"))
        XCTAssertFalse(csp.contains("https:"))
        XCTAssertFalse(csp.contains("margined-resource:"))
        XCTAssertFalse(try XCTUnwrap(doc.select("img[alt=Tracker]").first()).hasAttr("src"))
        XCTAssertTrue(preview.attachments.isEmpty)
        XCTAssertEqual(try Data(contentsOf: file), Data(source.utf8), "A preview must never write the source")
    }

    func testEmbeddedArtworkSurvivesPackaging() async throws {
        let root = try folder()
        let rendered = try await MarkdownRenderer.shared.render("![Embedded](data:image/png;base64,\(pixel.base64EncodedString()))")
        let preview = try await PreviewDocument.package(html: rendered.html, documentURL: root.appendingPathComponent("review.md"))
        XCTAssertEqual(try SwiftSoup.parse(preview.html).select("img").attr("src"), "data:image/png;base64,\(pixel.base64EncodedString())")
        XCTAssertTrue(preview.attachments.isEmpty)
    }

    func testBOMMarkedSourceLoadsWithoutModification() async throws {
        let file = try folder().appendingPathComponent("review.md")
        let data = try Data([0xff, 0xfe]) + XCTUnwrap("# 日本語\n\nReadable.".data(using: .utf16LittleEndian))
        try data.write(to: file)
        let preview = try await PreviewDocument.load(file, appearance: .dark)
        XCTAssertEqual(try SwiftSoup.parse(preview.html).select("h1").text(), "日本語")
        XCTAssertEqual(try SwiftSoup.parse(preview.html).select("html").attr("data-appearance"), "dark")
        XCTAssertEqual(try Data(contentsOf: file), data)
    }

    func testAttachmentMemoryIsBoundedAcrossDistinctImages() async throws {
        let root = try folder()
        let image = pixel + Data(repeating: 0, count: 8 * 1_024 * 1_024 - pixel.count)
        for n in 0..<5 { try image.write(to: root.appendingPathComponent("image\(n).png")) }
        let rendered = try await MarkdownRenderer.shared.render((0..<5).map { "![Image \($0)](image\($0).png)" }.joined(separator: "\n\n"))
        let preview = try await PreviewDocument.package(html: rendered.html, documentURL: root.appendingPathComponent("review.md"))
        XCTAssertEqual(preview.attachments.count, 4, "A system preview must not retain unbounded attachment data")
        XCTAssertLessThanOrEqual(preview.attachments.values.reduce(0) { $0 + $1.data.count }, 32 * 1_024 * 1_024)
        let images = try SwiftSoup.parse(preview.html).select("img").array()
        XCTAssertEqual(images.count, 5)
        XCTAssertEqual(try images.last?.attr("alt"), "Image 4")
        XCTAssertFalse(try XCTUnwrap(images.last).hasAttr("src"))
    }

    func testCanceledPreviewDoesNotProduceAResult() async throws {
        let file = try folder().appendingPathComponent("review.md")
        try Data("# Canceled".utf8).write(to: file)
        let task = Task { try await PreviewDocument.load(file) }
        task.cancel()
        do { _ = try await task.value; XCTFail("Canceled preview must stop") }
        catch is CancellationError {}
    }
}
