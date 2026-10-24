import Foundation
import WebKit
import XCTest
#if os(iOS)
@testable import MarginediOS
#else
@testable import Margined
#endif

@MainActor
final class PrintContentTests: XCTestCase {
    func testProsePrintUsesTheDisplayedSnapshotAndLoadsLocalImagesReadOnly() async throws {
        let folder = try temporaryFolder(), file = folder.appendingPathComponent("Review.md")
        let pixel = try XCTUnwrap(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+j5iQAAAAASUVORK5CYII="))
        try pixel.write(to: folder.appendingPathComponent("figure.png"))
        let source = "# Displayed version\n\nKeep this original paragraph.\n\n![Local](figure.png)\n\n- [ ] A printable task.\n"
        try Data(source.utf8).write(to: file)
        let output = try await MarkdownRenderer.shared.render(source, appearance: .dark, mapTasks: true)
        let newer = Data("# Newer disk version\n\nNot the displayed document.\n".utf8)
        try newer.write(to: file, options: .atomic)
        let prepared = try await PreparedPrintDocument.prepare(output, title: "Review", fileURL: file,
                                                               includeDiscussions: false, loadRemoteImages: false)
        defer { prepared.cancel() }
        let ready = prepared.webView.url != nil && !prepared.webView.isLoading
        XCTAssertTrue(ready, "Print preparation must return a committed, ready native WebView")
        guard ready else { return }
        let text = try await prepared.webView.evaluateJavaScript("document.querySelector('main').textContent") as? String
        XCTAssertTrue(text?.contains("Keep this original paragraph.") == true)
        XCTAssertFalse(text?.contains("Newer disk version") == true)
        let image = try await prepared.webView.evaluateJavaScript("document.querySelector('img[alt=Local]').naturalWidth") as? Int
        XCTAssertEqual(image, 1)
        let disabled = try await prepared.webView.evaluateJavaScript("document.querySelector('input').disabled") as? Bool
        XCTAssertEqual(disabled, true)
        XCTAssertFalse(prepared.webView.configuration.defaultWebpagePreferences.allowsContentJavaScript)
        XCTAssertFalse(prepared.webView.configuration.websiteDataStore.isPersistent)
        XCTAssertEqual(try Data(contentsOf: file), newer)
    }

    func testDiscussionPrintUsesSavedNotesFromTheDisplayedSnapshotWithoutPreviewInstructions() async throws {
        let folder = try temporaryFolder(), file = folder.appendingPathComponent("Review.md")
        let prose = "# Displayed version\n\nKeep this original paragraph.\n"
        let thread = DiscussionThread(id: "t-print-content", state: .open,
            target: .init(type: "TextQuoteSelector", exact: "Keep this original paragraph.", prefix: "Displayed version", suffix: "", section: "Displayed version"),
            messages: [.init(id: "m-print-content", author: "Reviewer", created: "2026-10-24T10:00:00Z",
                             body: "A saved **discussion**.\n\n- [ ] A comment task", inReplyTo: nil)],
            resolvedBy: nil, resolved: nil, attachmentHistory: [])
        let bytes = try MarkdownSourceEdits.apply(DiscussionEdits.splices(for: .newThread(thread), in: DiscussionCodec.parse(prose)),
                                                 to: Data(prose.utf8), expectedSource: prose)
        let source = try MarkdownSource.decode(bytes)
        try bytes.write(to: file)
        let output = try await MarkdownRenderer.shared.render(source)
        let newer = Data("# Newer disk version\n\nNo saved notes here.\n".utf8)
        try newer.write(to: file, options: .atomic)
        let prepared = try await PreparedPrintDocument.prepare(output, title: "Review", fileURL: file,
                                                               includeDiscussions: true, loadRemoteImages: false)
        defer { prepared.cancel() }
        let ready = prepared.webView.url != nil && !prepared.webView.isLoading
        XCTAssertTrue(ready, "Including discussions must prepare the actual rendered snapshot before opening Print")
        guard ready else { return }
        let text = try await prepared.webView.evaluateJavaScript("document.querySelector('main').textContent") as? String
        XCTAssertTrue(text?.contains("Keep this original paragraph.") == true)
        XCTAssertTrue(text?.contains("A saved discussion.") == true)
        XCTAssertFalse(text?.contains("Newer disk version") == true)
        XCTAssertFalse(text?.contains("Open this file in Margined to reply.") == true,
                       "A printed PDF is not the original Markdown file")
        let readonly = try await prepared.webView.evaluateJavaScript("document.querySelectorAll('section.discussion-appendix input:not([disabled]),button,script,textarea').length") as? Int
        XCTAssertEqual(readonly, 0)
        XCTAssertFalse(prepared.webView.configuration.defaultWebpagePreferences.allowsContentJavaScript)
        XCTAssertEqual(try Data(contentsOf: file), newer)
    }

    func testCancelledPrintPreparationNeverReturnsAPrintablePage() async throws {
        let output = try await MarkdownRenderer.shared.render("# A print request\n\nDisplayed text.")
        let request = Task { try await PreparedPrintDocument.prepare(output, title: "Review", fileURL: nil,
                                                                   includeDiscussions: true, loadRemoteImages: false) }
        request.cancel()
        do {
            let prepared = try await request.value; prepared.cancel()
            XCTFail("A canceled request must not open a print dialog later")
        } catch is CancellationError {
            // Cancellation is explicit and never starts another document's print.
        }
    }

    private func temporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder
    }
}
