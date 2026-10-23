import AppKit
import PDFKit
import WebKit
import XCTest
import os
@testable import Margined

@MainActor
final class PrintingTests: XCTestCase {
    func testFileMenuOffersStandardPrintShortcut() throws {
        let file = try XCTUnwrap(NSApp.mainMenu?.items.first { $0.submenu?.items.contains { $0.action == #selector(NSDocumentController.openDocument(_:)) } == true }?.submenu)
        let item = try XCTUnwrap(file.items.first { $0.action == #selector(NSDocument.printDocument(_:)) })
        XCTAssertEqual(item.keyEquivalent, "p")
        XCTAssertEqual(item.keyEquivalentModifierMask, .command)
        XCTAssertNil(item.target, "Print should follow the active document's responder chain")
    }

    func testPrintIsUnavailableBeforeDocumentContentLoads() {
        let document = MarkdownDocument()
        defer { document.close() }
        let item = NSMenuItem(title: "Print", action: #selector(NSDocument.printDocument(_:)), keyEquivalent: "p")
        XCTAssertFalse(document.validateUserInterfaceItem(item))
    }

    func testRenderedDocumentPrintsAllPagesAsSearchablePDF() async throws {
        let rows = (1...90).map { "| Row \($0) | Rendered table value \($0) |" }.joined(separator: "\n")
        let source = """
        # Printed document

        A **formatted paragraph** with a [working link](https://example.com).

        Equation $x^2 + 1$.

        ```mermaid
        flowchart LR
        Source --> Release
        ```

        - [x] Completed task
        - [ ] Remaining task

        | Item | Details |
        | --- | --- |
        \(rows)

        ```swift
        let finalCode = "printable code"
        ```

        ## Final section

        End of the printed document.
        """
        var components = URLComponents()
        components.scheme = "margined"; components.host = "preview"
        components.queryItems = [.init(name: "title", value: "Printing test"), .init(name: "text", value: source)]
        let document = try MarkdownDocument(preview: PreviewRequest(url: XCTUnwrap(components.url)))
        defer { document.close() }
        document.makeWindowControllers()
        document.showWindows()
        let window = try XCTUnwrap(document.windowControllers.first?.window)
        var web: WKWebView?
        for _ in 0..<200 {
            web = findWeb(in: window.contentView!)
            if let web, !web.isLoading, web.url != nil,
               (try? await web.evaluateJavaScript("document.body.innerText.includes('End of the printed document.')")) as? Bool == true { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        let webView = try XCTUnwrap(web)
        // Printing a dark, zoomed reader must still produce legible paper output.
        _ = try await webView.evaluateJavaScript("document.documentElement.dataset.appearance = 'dark'; document.querySelector('p').classList.add('margined-speaking', 'margined-change'); true")
        webView.pageZoom = 1.5
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("Margined-print-\(UUID()).pdf")
        defer { try? FileManager.default.removeItem(at: destination) }
        let operation = try XCTUnwrap(document.printOperation(withSettings: [
            .jobDisposition: NSPrintInfo.JobDisposition.save,
            .jobSavingURL: destination
        ]))
        operation.printInfo.paperSize = NSSize(width: 612, height: 792)
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false
        let completion = PrintCompletion()
        operation.runModal(for: window, delegate: completion,
                           didRun: #selector(PrintCompletion.didRun(_:success:contextInfo:)), contextInfo: nil)
        for _ in 0..<1200 where completion.success == nil {
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertEqual(completion.success, true)
        let pdf = try XCTUnwrap(PDFDocument(url: destination))
        let attachment = XCTAttachment(data: try Data(contentsOf: destination), uniformTypeIdentifier: "com.adobe.pdf")
        attachment.name = "Rendered document printing"
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTAssertGreaterThan(pdf.pageCount, 1, "The whole document must paginate, not just the visible viewport")
        let text = try XCTUnwrap(pdf.string)
        for expected in ["Printed document", "formatted paragraph", "Completed task", "Remaining task", "Row 90", "finalCode", "End of the printed document."] {
            XCTAssertTrue(text.contains(expected), "Missing printed content: \(expected)")
        }
        // PDFKit may substitute the system font and slightly adjust its point size.
        let body = try XCTUnwrap(pdf.findString("formatted paragraph", withOptions: []).first?.attributedString)
        let bodyFont = try XCTUnwrap(body.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        XCTAssertLessThanOrEqual(bodyFont.pointSize, 10.8, "Keep print text compact independently of reader zoom")
        let heading = try XCTUnwrap(pdf.findString("Printed document", withOptions: []).first?.attributedString)
        let headingFont = try XCTUnwrap(heading.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        XCTAssertLessThanOrEqual(headingFont.pointSize, 17.2)
        XCTAssertFalse(text.contains("$x^2 + 1$"))
        XCTAssertFalse(text.contains("Source --> Release"), "Print the diagram, not its collapsed source")
        XCTAssertFalse(text.contains("**formatted paragraph**"))
        XCTAssertFalse(text.contains("https://example.com"), "Print visible link text rather than Markdown syntax")
        XCTAssertEqual(webView.pageZoom, 1.5, "Printing must not change the reader's zoom")
        let appearance = try await webView.evaluateJavaScript("document.documentElement.dataset.appearance") as? String
        XCTAssertEqual(appearance, "dark")
    }

    private func findWeb(in view: NSView) -> WKWebView? {
        if let web = view as? WKWebView { return web }
        return view.subviews.lazy.compactMap { self.findWeb(in: $0) }.first
    }
}

private final class PrintCompletion: NSObject {
    private let result = OSAllocatedUnfairLock<Bool?>(initialState: nil)
    var success: Bool? { result.withLock { $0 } }
    @objc func didRun(_ operation: NSPrintOperation, success: Bool, contextInfo: UnsafeMutableRawPointer?) {
        result.withLock { $0 = success }
    }
}
