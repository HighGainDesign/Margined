import Dispatch
import WebKit

/// Prepares one unused page. Document pages and their private stores are never recycled.
@MainActor
final class ReaderPagePreparation {
    static let shared = ReaderPagePreparation()

    struct Page {
        let webView: WKWebView
        let images: ImageSchemeHandler
    }

    private var unusedPage: Page?
    private let memoryPressure: any DispatchSourceMemoryPressure

    private init() {
        memoryPressure = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        memoryPressure.setEventHandler { [weak self] in
            Task { @MainActor in self?.discard() }
        }
        memoryPressure.resume()
    }

    func take() -> Page {
        if let page = unusedPage {
            unusedPage = nil
            return page
        }
        return makePage()
    }

    func prepareIfNeeded() {
        guard unusedPage == nil else { return }
        let page = makePage()
        unusedPage = page
        page.webView.loadHTMLString("""
        <!doctype html><meta http-equiv="Content-Security-Policy" content="default-src 'none'; base-uri 'none'; form-action 'none'"><title></title>
        """, baseURL: nil)
    }

    private func makePage() -> Page {
        let images = ImageSchemeHandler()
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.setURLSchemeHandler(images, forURLScheme: "margined-resource")
        return Page(webView: WKWebView(frame: .zero, configuration: configuration), images: images)
    }

    private func discard() {
        unusedPage?.webView.stopLoading()
        unusedPage = nil
    }
}
