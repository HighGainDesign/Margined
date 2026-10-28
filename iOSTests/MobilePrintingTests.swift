import Foundation
import SwiftUI
import UIKit
import WebKit
import XCTest
@testable import MarginediOS

@MainActor
final class MobilePrintingTests: XCTestCase {
    // Printing must capture the displayed version; reading the file later would
    // silently print an agent's newer changes instead.
    func testPrintRequestRetainsDisplayedProseAndSavedDiscussionsAfterRefresh() async throws {
        let (reader, file, original) = try await fixture()
        reader.requestPrint(includeDiscussions: true)
        let request = try XCTUnwrap(reader.printRequest, "A ready document must offer system printing")
        XCTAssertEqual(try Data(contentsOf: file), original)
        let replacement = Data("# A newer version\n\nDifferent prose with no discussions.\n".utf8)
        try replacement.write(to: file, options: .atomic)
        await reader.refresh()
        await reader.waitForRendering()
        XCTAssertTrue(reader.source.contains("A newer version"))
        let page = try await MarkdownRenderer.shared.printHTML(request.output, title: request.title,
            includeDiscussions: request.includeDiscussions, loadRemoteImages: request.loadRemoteImages)
        XCTAssertTrue(page.contains("The displayed passage."))
        XCTAssertTrue(page.contains("A saved reply."))
        XCTAssertFalse(page.contains("Different prose"))
        XCTAssertTrue(request.includeDiscussions)
        XCTAssertEqual(request.context, reader.documentGeneration)
        XCTAssertEqual(try Data(contentsOf: file), replacement)
        await reader.close()
    }

    func testAnExistingPrintRequestCannotBeReplacedByAnotherMenuAction() async throws {
        let (reader, _, _) = try await fixture()
        reader.requestPrint(includeDiscussions: false)
        let prose = try XCTUnwrap(reader.printRequest)
        reader.requestPrint(includeDiscussions: true)
        XCTAssertEqual(reader.printRequest?.id, prose.id)
        XCTAssertFalse(try XCTUnwrap(reader.printRequest).includeDiscussions)
        reader.finishPrint(prose.id)
        XCTAssertNil(reader.printRequest)
        reader.requestPrint(includeDiscussions: true)
        XCTAssertTrue(try XCTUnwrap(reader.printRequest).includeDiscussions)
        await reader.close()
    }

    func testCloseAndSwitchDiscardPrintRequestsAndIgnoreOldCompletion() async throws {
        let (reader, file, _) = try await fixture()
        reader.requestPrint(includeDiscussions: false)
        let old = try XCTUnwrap(reader.printRequest)
        await reader.close()
        XCTAssertNil(reader.printRequest, "Closing must prevent a delayed print dialog")
        await reader.open(url: file); await reader.waitForRendering()
        reader.requestPrint(includeDiscussions: true)
        let current = try XCTUnwrap(reader.printRequest)
        XCTAssertNotEqual(current.context, old.context)
        reader.finishPrint(old.id)
        XCTAssertEqual(reader.printRequest?.id, current.id, "An old completion cannot clear another document's request")
        reader.finishPrint(current.id)
        XCTAssertNil(reader.printRequest)
        await reader.close()
    }

    func testPrintingRequiresAReadyDisplayedDocument() async throws {
        let empty = MobileReaderState()
        empty.requestPrint(includeDiscussions: false)
        XCTAssertNil(empty.printRequest)
        let (reader, _, _) = try await fixture()
        reader.requestPrint(includeDiscussions: false)
        let first = try XCTUnwrap(reader.printRequest)
        reader.finishPrint(first.id)
        reader.showChecklistConfirmation = true
        reader.requestPrint(includeDiscussions: false)
        XCTAssertNil(reader.printRequest, "Print must not compete with a saving-consent dialog")
        reader.showChecklistConfirmation = false
        reader.requestPrint(includeDiscussions: false)
        XCTAssertNotNil(reader.printRequest)
        await reader.close()
    }

    private func fixture() async throws -> (MobileReaderState, URL, Data) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("Print.md")
        let prose = "# Displayed\n\nThe displayed passage.\n"
        let thread = DiscussionThread(id: "t-mobile-print", state: .open,
            target: .init(type: "TextQuoteSelector", exact: "The displayed passage.", prefix: "Displayed", suffix: "", section: "Displayed"),
            messages: [.init(id: "m-mobile-print", author: "Reviewer", created: "2026-10-24T10:00:00Z",
                body: "A saved reply.", inReplyTo: nil)], resolvedBy: nil, resolved: nil, attachmentHistory: [])
        let bytes = try MarkdownSourceEdits.apply(DiscussionEdits.splices(for: .newThread(thread), in: DiscussionCodec.parse(prose)),
            to: Data(prose.utf8), expectedSource: prose)
        try bytes.write(to: file)
        let reader = MobileReaderState()
        await reader.open(url: file); await reader.waitForRendering()
        XCTAssertNotNil(reader.rendered)
        addTeardownBlock { @MainActor in await reader.close() }
        return (reader, file, bytes)
    }
// Append inside MobilePrintingTests after its model contracts.
    func testSystemPrintUsesRenderedSavedDiscussionsAndKeepsUnpostedTextPrivate() async throws {
        let f = try await mountedFixture()
        f.reader.discussions.setDraft("Private unposted text.", for: .thread("t-mobile-print"))
        f.reader.requestPrint(includeDiscussions: true)
        let request = try XCTUnwrap(f.reader.printRequest)
        let presented = await poll {
            self.printingView() != nil && self.hasPresentation(f.host)
        }
        XCTAssertTrue(presented, "Print must prepare a rendered page and open the native system print dialog")
        guard presented, let view = printingView() else { return }
        let text = try await view.evaluateJavaScript("document.querySelector('main').textContent") as? String
        XCTAssertTrue(text?.contains("The displayed passage.") == true)
        XCTAssertTrue(text?.contains("A saved reply.") == true)
        XCTAssertFalse(text?.contains("Private unposted text.") == true)
        XCTAssertEqual(UIPrintInteractionController.shared.printInfo?.jobName, "Print.md")
        XCTAssertEqual(try Data(contentsOf: f.file), f.bytes)
        f.reader.finishPrint(request.id)
        let dismissed = await poll { self.printingView() == nil && !self.hasPresentation(f.host) }
        XCTAssertTrue(dismissed, "Finishing the request must release the print formatter and presentation")
        XCTAssertEqual(f.reader.discussions.drafts[.thread("t-mobile-print")]?.body, "Private unposted text.")
    }

    func testClosingDuringNativePreparationPreventsADelayedPrintDialog() async throws {
        let f = try await mountedFixture()
        f.reader.requestPrint(includeDiscussions: false)
        XCTAssertNotNil(f.reader.printRequest)
        await f.reader.close()
        // Allow queued preparation and representable updates a real opportunity
        // to run; the positive system-dialog test above proves the path works.
        try await Task.sleep(for: .milliseconds(750))
        XCTAssertNil(f.reader.printRequest)
        XCTAssertNil(printingView())
        XCTAssertFalse(hasPresentation(f.host), "A closed document must not present a late system print dialog")
        XCTAssertEqual(try Data(contentsOf: f.file), f.bytes)
    }

    private func printingView() -> WKWebView? {
        (UIPrintInteractionController.shared.printFormatter as? UIViewPrintFormatter)?.view as? WKWebView
    }
    private func hasPresentation(_ controller: UIViewController) -> Bool {
        controller.presentedViewController != nil || controller.children.contains(where: hasPresentation)
    }
    private func poll(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<500 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return false
    }
    private func mountedFixture() async throws -> (reader: MobileReaderState, file: URL, bytes: Data,
        window: UIWindow, host: UIHostingController<MobileDocumentWorkspace>) {
        let (reader, file, bytes) = try await fixture()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let host = UIHostingController(rootView: MobileDocumentWorkspace(reader: reader, openFolder: {}, closeFile: {}))
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 780)
        window.rootViewController = host; window.makeKeyAndVisible(); host.view.layoutIfNeeded()
        addTeardownBlock { @MainActor in
            reader.discussions.discardDrafts(); await reader.close()
            UIPrintInteractionController.shared.dismiss(animated: false)
            window.isHidden = true; window.rootViewController = nil
        }
        return (reader, file, bytes, window, host)
    }
}
