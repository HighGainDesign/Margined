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

    func testDefaultPrintingKeepsExpandedDiscussionContentAndMarkersOffThePage() async throws {
        let prose = "# Print review\n\nVisible document body.\n"
        let thread = DiscussionThread(id: "t-print", state: .open,
            target: .init(type: "TextQuoteSelector", exact: "Visible document body.", prefix: "Print review", suffix: "", section: "Print review"),
            messages: [.init(id: "m-print", author: "Reviewer", created: "2026-10-24T10:00:00Z",
                             body: "SAVED_COMMENT_MUST_NOT_PRINT", inReplyTo: nil)],
            resolvedBy: nil, resolved: nil, attachmentHistory: [])
        let bytes = try MarkdownSourceEdits.apply(DiscussionEdits.splices(for: .newThread(thread), in: DiscussionCodec.parse(prose)),
                                                 to: Data(prose.utf8), expectedSource: prose)
        let source = try MarkdownSource.decode(bytes)
        var url = URLComponents(); url.scheme = "margined"; url.host = "preview"
        url.queryItems = [.init(name: "title", value: "Print review"), .init(name: "text", value: source)]
        let document = try MarkdownDocument(preview: PreviewRequest(url: XCTUnwrap(url.url)))
        defer { document.close() }
        document.makeWindowControllers(); document.showWindows()
        let window = try XCTUnwrap(document.windowControllers.first?.window)
        let mainReady = await printPoll {
            guard let web = self.findWeb(in: window.contentView!), web.url != nil, !web.isLoading else { return false }
            return (try? await web.evaluateJavaScript("document.querySelector('main')?.textContent.includes('Visible document body.')===true")) as? Bool == true
        }
        XCTAssertTrue(mainReady); guard mainReady else { return }
        let main = try XCTUnwrap(findWeb(in: window.contentView!))
        document.reader.openDiscussion("t-print")
        let expanded = await printPoll {
            guard let history = self.printWebViews(in: window.contentView!).first(where: { $0 !== main }),
                  history.url != nil, !history.isLoading else { return false }
            return (try? await history.evaluateJavaScript("document.querySelectorAll('article').length===1")) as? Bool == true
        }
        XCTAssertTrue(expanded, "Keep a real expanded history present while choosing the document's print view")
        guard expanded else { return }
        let decorated = await printPoll {
            (try? await main.evaluateJavaScript("document.querySelector('.margined-note-button')!==null")) as? Bool == true
        }
        XCTAssertTrue(decorated); guard decorated else { return }
        // Freeze only decoration observers so print reflow cannot replace our
        // identifiable marker. This remains the actual installed app overlay.
        let prepared = try await main.callAsyncJavaScript("""
        const layout=window.__marginedDiscussions?.layout;
        const marker=document.querySelector('.margined-note-button');
        const line=document.querySelector('.margined-note-line');
        if(!layout || !marker || !line) return false;
        layout.abort.abort();layout.observer?.disconnect();
        if(layout.pending!==null)cancelAnimationFrame(layout.pending);
        marker.textContent='TRANSIENT_MARKER_MUST_NOT_PRINT';
        Object.assign(marker.style,{left:'8px',top:'70px',width:'330px',color:'#000'});
        Object.assign(line.style,{left:'8px',top:'110px',width:'280px',height:'6px',borderBottom:'6px solid #ff0000'});
        return true;
        """, arguments: [:], in: nil, contentWorld: MarkdownWebView.Coordinator.discussionWorld) as? Bool
        XCTAssertEqual(prepared, true)
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("Margined-print-discussions-\(UUID()).pdf")
        defer { try? FileManager.default.removeItem(at: destination) }
        let operation = try document.printOperation(withSettings: [.jobDisposition: NSPrintInfo.JobDisposition.save, .jobSavingURL: destination])
        operation.printInfo.paperSize = NSSize(width: 612, height: 792)
        operation.showsPrintPanel = false; operation.showsProgressPanel = false
        let completion = PrintCompletion()
        operation.runModal(for: window, delegate: completion,
                           didRun: #selector(PrintCompletion.didRun(_:success:contextInfo:)), contextInfo: nil)
        let finished = await printPoll { completion.success != nil }
        XCTAssertTrue(finished); XCTAssertEqual(completion.success, true)
        guard finished, completion.success == true else { return }
        let pdf = try XCTUnwrap(PDFDocument(url: destination)), text = try XCTUnwrap(pdf.string)
        XCTAssertTrue(text.contains("Visible document body."))
        XCTAssertFalse(text.contains("SAVED_COMMENT_MUST_NOT_PRINT"), "Standard Print remains prose-only even with another WebView in the margin")
        XCTAssertFalse(text.contains("TRANSIENT_MARKER_MUST_NOT_PRINT"), "On-screen discussion buttons never belong in printed content")
        let page = try XCTUnwrap(pdf.page(at: 0))
        XCTAssertEqual(try redPrintPixels(page), 0, "Discussion lines and highlights must also stay off the page")
        XCTAssertEqual(document.reader.source, source)
        let markerRetained = try await main.evaluateJavaScript("document.querySelector('.margined-note-button')?.textContent==='TRANSIENT_MARKER_MUST_NOT_PRINT'") as? Bool
        XCTAssertEqual(markerRetained, true, "Printing hides transient decorations without deleting the live interface")
        let attachment = XCTAttachment(data: try Data(contentsOf: destination), uniformTypeIdentifier: "com.adobe.pdf")
        attachment.name = "Prose-only print with discussion markers"; attachment.lifetime = .keepAlways; add(attachment)
    }

    private func printPoll(_ condition: @MainActor () async -> Bool) async -> Bool {
        for _ in 0..<300 {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return false
    }
    private func printWebViews(in view: NSView) -> [WKWebView] {
        if let web = view as? WKWebView { return [web] }
        return view.subviews.flatMap { printWebViews(in: $0) }
    }
    private func redPrintPixels(_ page: PDFPage) throws -> Int {
        let width = 612, height = 792
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
        context.drawPDFPage(try XCTUnwrap(page.pageRef))
        let pixels = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        return (0..<(width * height)).reduce(into: 0) { count, pixel in
            let offset = pixel * 4
            if pixels[offset] > 180 && pixels[offset + 1] < 100 && pixels[offset + 2] < 100 { count += 1 }
        }
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
