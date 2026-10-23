import Foundation
import SwiftSoup
import WebKit
import XCTest
@testable import Margined

final class LocalImageTests: XCTestCase {
    func testAbsoluteImagePathsUseNormalFileAccess() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let file = root.appendingPathComponent("review.md")
        let image = root.appendingPathComponent("mockups/figure 1.png")
        XCTAssertEqual(LocalImage.resolve(image.path, documentURL: file), image)
        XCTAssertEqual(LocalImage.resolve(image.absoluteString, documentURL: file), image)
        XCTAssertEqual(LocalImage.resolve("mockups/figure%201.png", documentURL: file), image)
        XCTAssertEqual(LocalImage.resolve(root.path + "-other/private.png", documentURL: file)?.path,
                       root.path + "-other/private.png")
        XCTAssertNil(LocalImage.resolve("file://remote-host" + image.path, documentURL: file))
        XCTAssertNil(LocalImage.resolve("//remote-host/figure.png", documentURL: file))
        XCTAssertNil(LocalImage.resolve("https://example.com/figure.png", documentURL: file))
        XCTAssertNotNil(LocalImage.resolve(root.appendingPathComponent("figure.svg").path, documentURL: file))
    }

    func testRendererRoutesAbsoluteAndFileImagesThroughHandler() async throws {
        let result = try await MarkdownRenderer.shared.render("""
        ![absolute](/tmp/mockups/figure.png)
        ![file](file:///tmp/mockups/figure%201.png)
        ![remote](//example.com/figure.png)
        """)
        let images = try SwiftSoup.parse(result.html).select("img").array()
        XCTAssertEqual(images.count, 3)
        let url = try XCTUnwrap(URLComponents(string: images[0].attr("src")))
        XCTAssertEqual(url.scheme, "margined-resource")
        XCTAssertEqual(url.host, "local")
        XCTAssertEqual(String(url.percentEncodedPath.dropFirst()).removingPercentEncoding, "/tmp/mockups/figure.png")
        let fileURL = try XCTUnwrap(URLComponents(string: images[1].attr("src")))
        XCTAssertEqual(fileURL.scheme, "margined-resource")
        XCTAssertFalse(images[2].hasAttr("src"))
    }

    func testParentAndSymlinkImagesAreNotRestrictedToDocumentDirectory() throws {
        let workspace = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let root = workspace.appendingPathComponent("notes")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }
        let image = workspace.appendingPathComponent("figure.png")
        try Data([0]).write(to: image)
        let file = root.appendingPathComponent("review.md")
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("linked"), withDestinationURL: workspace)
        XCTAssertEqual(LocalImage.resolve("../figure.png", documentURL: file), image)
        XCTAssertEqual(LocalImage.resolve("linked/figure.png", documentURL: file), image)
    }

    @MainActor
    func testWebViewLoadsParentAbsoluteFileAndSymlinkImagesWithoutFolderOptIn() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let notes = root.appendingPathComponent("notes")
        try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = notes.appendingPathComponent("review.md")
        let image = root.appendingPathComponent("figure.png")
        try XCTUnwrap(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+j5iQAAAAASUVORK5CYII=")).write(to: image)
        try FileManager.default.createSymbolicLink(at: notes.appendingPathComponent("linked.png"), withDestinationURL: image)
        let reader = ReaderState(); reader.fileURL = file
        let handler = ImageSchemeHandler()
        handler.documentURL = file
        handler.loadFailed = { reader.localImageError = $0 }
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(handler, forURLScheme: "margined-resource")
        let webView = WKWebView(frame: .zero, configuration: configuration)
        let result = try await MarkdownRenderer.shared.render("""
        ![Parent](../figure.png)
        ![Absolute](\(image.path))
        ![File URL](\(image.absoluteString))
        ![Symlink](linked.png)
        """)
        webView.loadHTMLString(result.html, baseURL: root)
        var loaded = false
        for _ in 0..<100 {
            try await Task.sleep(for: .milliseconds(25))
            loaded = (try? await webView.evaluateJavaScript("document.querySelectorAll('img').length === 4 && Array.from(document.querySelectorAll('img')).every(image => image.naturalWidth === 1)")) as? Bool ?? false
            if loaded { break }
        }
        XCTAssertTrue(loaded, "The actual image request must reach the handler and decode without an opt-in")
        XCTAssertNil(reader.localImageError)
    }
}
