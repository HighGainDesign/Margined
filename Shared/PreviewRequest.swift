import Foundation

struct PreviewRequest: Equatable, Sendable {
    let text: String
    let title: String

    init(url: URL) throws {
        guard url.scheme?.lowercased() == "margined", url.host == "preview",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let text = components.queryItems?.first(where: { $0.name == "text" })?.value else {
            throw ReaderError.invalidPreviewURL
        }
        guard text.utf8.count <= MarkdownSource.maximumBytes else { throw ReaderError.tooLarge }
        self.text = text
        let title = components.queryItems?.first(where: { $0.name == "title" })?.value ?? "Drafts Preview"
        self.title = String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
    }
}
