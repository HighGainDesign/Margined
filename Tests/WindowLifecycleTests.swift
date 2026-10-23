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
        reader.miniaturize(nil)
        XCTAssertTrue(app.applicationShouldHandleReopen(NSApp, hasVisibleWindows: false))
        XCTAssertFalse(reader.isMiniaturized)
        XCTAssertTrue(reader.isVisible)
        XCTAssertFalse(welcome.isVisible)
    }
}
