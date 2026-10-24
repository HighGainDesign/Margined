import Darwin
import Foundation
import UIKit

struct MobileDiscussionShare: Identifiable {
    let id = UUID()
    let url: URL
    let configuration: UIActivityItemsConfiguration
}

/// Each provider retains this immutable file, even after its reader changes or
/// the share sheet is dismissed. Removing the last provider releases the copy.
@MainActor private final class MobileDiscussionSharedFile {
    let directory: URL
    let url: URL
    init(directory: URL, url: URL) { self.directory = directory; self.url = url }
    deinit { try? FileManager.default.removeItem(at: directory) }
}

private enum MobileDiscussionShareStaging {
    @concurrent static func create(_ data: Data, filename: String) async throws -> (directory: URL, url: URL) {
        try Task.checkCancellation()
        let templateURL = FileManager.default.temporaryDirectory.appendingPathComponent("Margined-Share-XXXXXX")
        var template = Array(templateURL.path.utf8CString)
        let directory = try template.withUnsafeMutableBufferPointer { bytes -> URL in
            guard let base = bytes.baseAddress, mkdtemp(base) != nil else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            return URL(fileURLWithPath: String(cString: base), isDirectory: true)
        }
        do {
            let url = directory.appendingPathComponent(filename)
            _ = try await DiscussionCopy.create(data, at: url)
            try Task.checkCancellation()
            return (directory, url)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }
}

extension MobileReaderState {
    func requestMarkdownShare() {
        guard canEditDiscussions, !discussionImportLoading, discussionSheet == nil, discussionCopyRequest == nil else { return }
        discussionError = nil
        do {
            let prepared = try prepareDiscussionExport(.markdown)
            let base = ((title as NSString).lastPathComponent as NSString).deletingPathExtension
            let filename = (base.isEmpty || base == "." || base == ".." ? String(localized: "Document") : base) + ".md"
            performDiscussionFileSave { [self] in
                do {
                    let staged = try await MobileDiscussionShareStaging.create(prepared.data, filename: filename)
                    let file = MobileDiscussionSharedFile(directory: staged.directory, url: staged.url)
                    guard documentGeneration == prepared.version.context else { return }
                    let provider = NSItemProvider()
                    let url = file.url
                    provider.suggestedName = filename
                    provider.registerFileRepresentation(forTypeIdentifier: "net.daringfireball.markdown", fileOptions: [], visibility: .all) { [file] completion in
                        withExtendedLifetime(file) { completion(url, false, nil) }
                        return nil
                    }
                    let configuration = UIActivityItemsConfiguration(itemProviders: [provider])
                    discussionShare = .init(url: url, configuration: configuration)
                } catch {
                    guard documentGeneration == prepared.version.context else { return }
                    discussionError = error.localizedDescription
                }
            }
        } catch { discussionError = error.localizedDescription }
    }
    func finishDiscussionShare(_ shareID: UUID) {
        guard discussionShare?.id == shareID else { return }
        discussionShare = nil
    }
}
