import Foundation
import OSLog
import QuickLookUI
import UniformTypeIdentifiers

/// Private timing harness; renderer and reply/attachment path are the production implementations.
final class PreviewProvider: QLPreviewProvider, QLPreviewingController {
    private static func record(_ stage: String, _ url: URL, attachments: Int? = nil) {
        var value: [String: Any] = ["stage": stage, "pid": getpid(),
            "file": url.lastPathComponent, "uptime_ns": DispatchTime.now().uptimeNanoseconds,
            "identifier": Bundle.main.bundleIdentifier ?? "unknown"]
        if let attachments { value["attachments"] = attachments }
        if let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
           let text = String(data: data, encoding: .utf8) {
            Logger(subsystem: "design.highgain.margined.benchmark.ql14", category: "viewing")
                .notice("MARGINED_QL_BENCH \(text, privacy: .public)")
        }
    }
    func providePreview(for request: QLFilePreviewRequest) async throws -> QLPreviewReply {
        let url = request.fileURL
        Self.record("request", url)
        // A deterministic benchmark theme avoids reading the user's shared settings.
        let document = try await PreviewDocument.load(url, appearance: .light)
        Self.record("ready", url, attachments: document.attachments.count)
        return QLPreviewReply(dataOfContentType: .html, contentSize: CGSize(width: 850, height: 700)) { reply in
            reply.stringEncoding = .utf8
            reply.attachments = document.attachments.mapValues { attachment in
                QLPreviewReplyAttachment(data: attachment.data,
                    contentType: UTType(attachment.contentTypeIdentifier) ?? .data)
            }
            Self.record("deliver", url, attachments: document.attachments.count)
            return Data(document.html.utf8)
        }
    }
}
