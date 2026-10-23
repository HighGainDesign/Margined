import Foundation
import WebKit

@MainActor
final class ImageSchemeHandler: NSObject, WKURLSchemeHandler {
    #if os(macOS) && MARGINED_APP_STORE
    private let folderAccess = SandboxImageFolders.shared
    #endif
    var documentURL: URL? {
        didSet { if documentURL != oldValue { cancelPendingLoads() } }
    }
    var loadFailed: ((String) -> Void)?
    private var requests: [ObjectIdentifier: Task<Void, Never>] = [:]

    deinit {
        for request in requests.values { request.cancel() }
    }

    func cancelPendingLoads() {
        for request in requests.values { request.cancel() }
        requests.removeAll()
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url, url.host == "local",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let relativePath = String(components.percentEncodedPath.dropFirst()).removingPercentEncoding,
              let image = LocalImage.resolve(relativePath, documentURL: documentURL) else {
            urlSchemeTask.didFailWithError(URLError(.noPermissionsToReadFile))
            return
        }
        let identifier = ObjectIdentifier(urlSchemeTask)
        requests.removeValue(forKey: identifier)?.cancel()
        requests[identifier] = Task { [weak self] in
            do {
                // A provider may need to download the image. Keep that work off
                // MainActor, and never finish a request WebKit has stopped.
                let data = try await LocalImageData.read(image)
                try Task.checkCancellation()
                guard let self else { return }
                requests[identifier] = nil
                urlSchemeTask.didReceive(URLResponse(url: url, mimeType: LocalImage.mimeType(for: image),
                                                    expectedContentLength: data.count, textEncodingName: nil))
                urlSchemeTask.didReceive(data)
                urlSchemeTask.didFinish()
            } catch {
                guard !Task.isCancelled, let self else { return }
                requests[identifier] = nil
                loadFailed?(String(localized: "Couldn’t load “\(image.lastPathComponent)”: \(error.localizedDescription)"))
                urlSchemeTask.didFailWithError(error)
            }
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {
        requests.removeValue(forKey: ObjectIdentifier(urlSchemeTask))?.cancel()
    }
}
