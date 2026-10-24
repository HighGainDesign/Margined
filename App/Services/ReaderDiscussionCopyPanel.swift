import AppKit
import UniformTypeIdentifiers

@MainActor
final class ReaderDiscussionCopyPanel: NSObject, NSOpenSavePanelDelegate {
    let panel = NSSavePanel()

    init(reader: ReaderState, export: ReaderDiscussionExport? = nil) {
        super.init()
        panel.delegate = self
        panel.allowedContentTypes = [UTType(importedAs: "net.daringfireball.markdown")]
        panel.canCreateDirectories = true
        panel.title = String(localized: "Save Markdown Copy")
        panel.message = String(localized: "Creates a new Markdown file and keeps your unposted comments. Image files stay in their current folders.")
        let filename = reader.fileURL?.deletingPathExtension().lastPathComponent ?? reader.title
        if let export {
            panel.title = export.title
            panel.message = export.message
            panel.prompt = String(localized: "Export")
            panel.nameFieldStringValue = filename + " " + export.filenameSuffix + ".md"
        } else { panel.nameFieldStringValue = filename + " Copy.md" }
        panel.directoryURL = reader.fileURL?.deletingLastPathComponent()
    }

    func panel(_ sender: Any, validate url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            throw CocoaError(.fileWriteFileExists, userInfo: [NSLocalizedDescriptionKey:
                String(localized: "Choose a new filename. Copies never replace an existing file.")])
        }
    }
}
