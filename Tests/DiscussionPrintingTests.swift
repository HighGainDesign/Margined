import AppKit
import PDFKit
import XCTest
@testable import Margined

@MainActor
final class DiscussionPrintingTests: XCTestCase {
    func testDiscussionPrintProducesAPaginatedSearchablePDFOfTheDisplayedNotes() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("Review.md")
        let prose = "# Printed review\n\nThe passage being discussed.\n"
        let paragraphs = (1...70).map { "Saved comment paragraph \($0), with enough ordinary text to paginate and remain searchable in a PDF." }.joined(separator: "\n\n")
        let thread = DiscussionThread(id: "t-pdf-notes", state: .open,
            target: .init(type: "TextQuoteSelector", exact: "The passage being discussed.", prefix: "Printed review", suffix: "", section: "Printed review"),
            messages: [
                .init(id: "m-pdf-first", author: "First Reviewer", created: "2026-10-24T10:00:00Z",
                      body: "A **formatted** saved comment.\n\n" + paragraphs, inReplyTo: nil),
                .init(id: "m-pdf-reply", author: "Second Reviewer", created: "2026-10-24T11:00:00Z",
                      body: "The final saved reply.", inReplyTo: "m-pdf-first")
            ], resolvedBy: nil, resolved: nil, attachmentHistory: [])
        let bytes = try MarkdownSourceEdits.apply(DiscussionEdits.splices(for: .newThread(thread), in: DiscussionCodec.parse(prose)),
                                                 to: Data(prose.utf8), expectedSource: prose)
        try bytes.write(to: file)
        let output = try await MarkdownRenderer.shared.render(MarkdownSource.decode(bytes), appearance: .dark)
        let newer = Data("# A newer version on disk\n".utf8)
        try newer.write(to: file, options: .atomic)
        let prepared = try await PreparedPrintDocument.prepare(output, title: "Review", fileURL: file,
                                                               includeDiscussions: true, loadRemoteImages: false)
        defer { prepared.cancel() }
        let ready = prepared.webView.url != nil && !prepared.webView.isLoading
        XCTAssertTrue(ready); guard ready else { return }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 816, height: 700),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = prepared.webView
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        let destination = folder.appendingPathComponent("Review.pdf")
        let info = NSPrintInfo()
        info.paperSize = NSSize(width: 612, height: 792)
        info.horizontalPagination = .fit
        info.dictionary().addEntries(from: [
            NSPrintInfo.AttributeKey.jobDisposition: NSPrintInfo.JobDisposition.save,
            NSPrintInfo.AttributeKey.jobSavingURL: destination
        ])
        let operation = prepared.webView.printOperation(with: info)
        operation.canSpawnSeparateThread = true
        operation.showsPrintPanel = false; operation.showsProgressPanel = false
        let document = MarkdownDocument()
        defer { document.close() }
        document.runDiscussionPrint(operation, prepared: prepared, for: window)
        XCTAssertTrue(document.isPrintingDiscussions, "The actual print controller retains its frozen page until completion")
        for _ in 0..<800 where document.isPrintingDiscussions { try await Task.sleep(for: .milliseconds(25)) }
        XCTAssertFalse(document.isPrintingDiscussions, "The native spool-thread callback must finish the matching job on MainActor")
        let pdf = try XCTUnwrap(PDFDocument(url: destination)), text = try XCTUnwrap(pdf.string)
        let evidence = XCTAttachment(data: try Data(contentsOf: destination), uniformTypeIdentifier: "com.adobe.pdf")
        evidence.name = "Rendered document with saved discussions"; evidence.lifetime = .keepAlways
        add(evidence)
        XCTAssertGreaterThan(pdf.pageCount, 1)
        for expected in ["Printed review", "First Reviewer", "Second Reviewer", "A formatted saved comment.",
                         "Saved comment paragraph 70", "The final saved reply."] {
            XCTAssertTrue(text.contains(expected), "Missing printed discussion content: \(expected)")
        }
        XCTAssertFalse(text.contains("A newer version on disk"))
        XCTAssertFalse(text.contains("Open this file in Margined to reply."))
        XCTAssertEqual(try Data(contentsOf: file), newer)
    }

    func testFileMenuOffersExplicitDiscussionPrintingAlongsideProsePrint() throws {
        let proseAction = #selector(NSDocument.printDocument(_:))
        let file = try XCTUnwrap(NSApp.mainMenu?.items.first {
            $0.submenu?.items.contains { $0.action == proseAction } == true
        }?.submenu)
        let prose = try XCTUnwrap(file.items.first { $0.action == proseAction })
        XCTAssertEqual(prose.keyEquivalent, "p")
        XCTAssertEqual(prose.keyEquivalentModifierMask, .command)
        let action = NSSelectorFromString("printWithDiscussions:")
        let discussion = file.items.first { $0.action == action }
        XCTAssertNotNil(discussion, "Including discussions must be an explicit print choice")
        guard let discussion else { return }
        XCTAssertEqual(discussion.title, String(localized: "Print with Discussions…"))
        XCTAssertEqual(discussion.keyEquivalent, "")
        XCTAssertNil(discussion.target, "Printing follows the active document's responder chain")
        let document = MarkdownDocument(); defer { document.close() }
        XCTAssertTrue(document.responds(to: action))
        XCTAssertFalse(document.validateUserInterfaceItem(discussion), "No printing before document content loads")
    }
}
