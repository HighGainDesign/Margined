import Foundation
#if os(macOS)
import QuickLookUI
#else
import QuickLook
#endif
import UniformTypeIdentifiers

final class PreviewProvider: QLPreviewProvider, QLPreviewingController {
    func providePreview(for request: QLFilePreviewRequest) async throws -> QLPreviewReply {
        let url = request.fileURL
        let appearance = ReaderPreferences.appearance(in: ReaderPreferences.defaults)
        let document = try await PreviewDocument.load(url, appearance: appearance)
        return QLPreviewReply(dataOfContentType: .html, contentSize: CGSize(width: 850, height: 700)) { reply in
            reply.stringEncoding = .utf8
            reply.attachments = document.attachments.mapValues { attachment in
                QLPreviewReplyAttachment(data: attachment.data,
                    contentType: UTType(attachment.contentTypeIdentifier) ?? .data)
            }
            return Data(document.html.utf8)
        }
    }
}
