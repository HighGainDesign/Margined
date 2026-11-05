import Foundation
import WebKit

/// Native functional fixtures must finish process/navigation setup before
/// measuring behavior. Hosted iOS WebContent startup has taken up to 29 seconds;
/// the individual content, selection and layout assertions keep their own waits.
@MainActor
enum WebKitTestReadiness {
    static let navigationTimeout: TimeInterval = 60

    static func navigation(_ view: () -> WKWebView?, expectedURL: URL? = nil) async -> WKWebView? {
        let deadline = ContinuousClock.now.advanced(by: .seconds(navigationTimeout))
        while ContinuousClock.now < deadline, !Task.isCancelled {
            if let web = view(), !web.isLoading, web.estimatedProgress == 1,
               let url = web.url, expectedURL == nil || url == expectedURL {
                return web
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return nil
    }
}
