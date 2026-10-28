import AppKit
import XCTest
@testable import Margined

final class WindowLifecycleTests: XCTestCase {
    @MainActor
    func testWelcomeIsDismissedForDocumentControllerOpenAndCannotReappear() throws {
        let app = try XCTUnwrap(NSApp.delegate as? AppDelegate)
        XCTAssertTrue(NSDocumentController.shared.documents.isEmpty)
        XCTAssertFalse(app.applicationShouldOpenUntitledFile(NSApp))
        let welcome = try XCTUnwrap(NSApp.windows.first { $0.title == "Margined" && $0.isVisible })
        defer { welcome.close() }

        let request = try PreviewRequest(url: XCTUnwrap(URL(string: "margined://preview?text=%23%20Window%20check&title=Reader%20check")))
        let document = MarkdownDocument(preview: request)
        NSDocumentController.shared.addDocument(document)
        defer { document.close() }
        // File > Open creates windows through NSDocumentController rather than
        // the app delegate's URL handler. Both must dismiss the welcome window.
        document.makeWindowControllers()
        document.showWindows()
        XCTAssertFalse(welcome.isVisible)
        app.showWelcome()
        XCTAssertFalse(welcome.isVisible)

        let reader = try XCTUnwrap(document.windowControllers.first?.window)
        let screen = try XCTUnwrap(reader.screen ?? NSScreen.main)
        let requested = reader.frameRect(forContentRect: NSRect(x: 0, y: 0, width: 920, height: 760))
        let fitted = reader.constrainFrameRect(requested, to: screen)
        let expected = reader.contentRect(forFrameRect: fitted).size
        let content = try XCTUnwrap(reader.contentView).bounds.size
        XCTAssertEqual(content.width, expected.width, accuracy: 1)
        XCTAssertEqual(content.height, expected.height, accuracy: 1,
                       "AppKit may fit the default window to the available display")
        // SwiftUI can raise the frame minimum to fit its 300-point content
        // plus the OS title bar. Keep that adjustment bounded and resizable.
        let hostingMinimum = reader.frameRect(forContentRect: NSRect(x: 0, y: 0, width: 480, height: 300)).size
        XCTAssertGreaterThanOrEqual(reader.minSize.width, 480)
        XCTAssertGreaterThanOrEqual(reader.minSize.height, 320)
        XCTAssertLessThanOrEqual(reader.minSize.width, max(480, hostingMinimum.width))
        XCTAssertLessThanOrEqual(reader.minSize.height, max(320, hostingMinimum.height))
        XCTAssertEqual(reader.title, "Reader check")
        XCTAssertTrue(reader.styleMask.contains([.titled, .closable, .miniaturizable, .resizable]))
        XCTAssertFalse(reader.isReleasedWhenClosed, "The document controller owns the window")
        reader.setContentSize(NSSize(width: 700, height: 600))
        reader.contentView?.layoutSubtreeIfNeeded()
        XCTAssertEqual(reader.contentView?.bounds.size, NSSize(width: 700, height: 600),
                       "The reader must remain freely resizable")
        reader.miniaturize(nil)
        XCTAssertTrue(app.applicationShouldHandleReopen(NSApp, hasVisibleWindows: false))
        XCTAssertFalse(reader.isMiniaturized)
        XCTAssertTrue(reader.isVisible)
        XCTAssertFalse(welcome.isVisible)
    }
}
