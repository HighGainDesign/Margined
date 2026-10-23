import Foundation
import WebKit

@MainActor
final class ImageSchemeHandler: NSObject, WKURLSchemeHandler {
    #if os(macOS) && MARGINED_APP_STORE
    private let folderAccess = SandboxImageFolders.shared
    #endif
    var documentURL: URL?
    var loadFailed: ((String) -> Void)?

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url, url.host == "local",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let relativePath = String(components.percentEncodedPath.dropFirst()).removingPercentEncoding,
              let image = LocalImage.resolve(relativePath, documentURL: documentURL) else {
            urlSchemeTask.didFailWithError(URLError(.noPermissionsToReadFile))
            return
        }
        do {
            guard try image.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
                throw URLError(.cannotOpenFile)
            }
            let file = try FileHandle(forReadingFrom: image)
            defer { try? file.close() }
            let data = try file.read(upToCount: MarkdownSource.maximumBytes + 1) ?? Data()
            guard data.count <= MarkdownSource.maximumBytes else { throw ReaderError.tooLarge }
            urlSchemeTask.didReceive(URLResponse(url: url, mimeType: LocalImage.mimeType(for: image),
                                                expectedContentLength: data.count, textEncodingName: nil))
            urlSchemeTask.didReceive(data)
            urlSchemeTask.didFinish()
        } catch {
            loadFailed?(String(localized: "Couldn’t load “\(image.lastPathComponent)”: \(error.localizedDescription)"))
            urlSchemeTask.didFailWithError(error)
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {}
}
