import Foundation
import SwiftSoup
import UniformTypeIdentifiers

struct PreviewAttachment: Sendable {
    let data: Data
    let contentTypeIdentifier: String
}

/// A self-contained system preview. Quick Look has no handler for the reader's
/// private image scheme, so readable local assets travel with the HTML as CIDs.
struct PreviewDocument: Sendable {
    let html: String
    let attachments: [String: PreviewAttachment]

    @concurrent
    static func load(_ url: URL, appearance: DocumentAppearance = .system) async throws -> PreviewDocument {
        try Task.checkCancellation()
        guard url.isFileURL else { throw CocoaError(.fileReadUnsupportedScheme) }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let source = try MarkdownSource.read(url)
        let rendered = try await MarkdownRenderer.shared.render(source, title: url.lastPathComponent,
            wide: true, appearance: appearance)
        return try await package(html: rendered.html, documentURL: url)
    }

    /// Accepts only sanitized renderer output; remote URLs are never read here.
    @concurrent
    static func package(html: String, documentURL: URL) async throws -> PreviewDocument {
        try Task.checkCancellation()
        let document = try SwiftSoup.parse(html)
        document.outputSettings().prettyPrint(pretty: false)
        var attachments: [String: PreviewAttachment] = [:]
        var identifiers: [URL: String] = [:]
        var attachmentBytes = 0
        let maximumAttachmentBytes = 32 * 1_024 * 1_024
        for image in try document.select("img").array() {
            try Task.checkCancellation()
            let source = try image.attr("src")
            guard let resource = URLComponents(string: source),
                  resource.scheme == "margined-resource", resource.host == "local",
                  let reference = String(resource.percentEncodedPath.dropFirst()).removingPercentEncoding,
                  let url = LocalImage.resolve(reference, documentURL: documentURL) else { continue }
            if let id = identifiers[url] {
                try image.attr("src", "cid:" + id)
                continue
            }
            // Keep alternative text when the OS denies an image, it disappears,
            // or it exceeds the same per-image bound as the normal reader.
            try image.removeAttr("src")
            let attachment: PreviewAttachment
            do {
                let data = try await LocalImageData.read(url)
                guard data.count <= maximumAttachmentBytes - attachmentBytes else { continue }
                attachment = PreviewAttachment(data: data,
                    contentTypeIdentifier: UTType(filenameExtension: url.pathExtension)?.identifier ?? UTType.data.identifier)
            } catch { continue }
            let id = "margined-image-\(attachments.count)"
            attachments[id] = attachment
            attachmentBytes += attachment.data.count
            identifiers[url] = id
            try image.attr("src", "cid:" + id)
        }
        // A preview remains offline even if a future caller rendered with a
        // different image policy. The input's other safety rules stay intact.
        for policy in try document.select("meta[http-equiv=Content-Security-Policy]").array() {
            try policy.attr("content", "default-src 'none'; style-src 'unsafe-inline'; img-src cid: data:; base-uri 'none'; form-action 'none'")
        }
        try Task.checkCancellation()
        return PreviewDocument(html: try document.outerHtml(), attachments: attachments)
    }
}
