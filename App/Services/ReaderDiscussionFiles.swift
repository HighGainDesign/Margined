import AppKit
import UniformTypeIdentifiers

@MainActor
final class ReaderDiscussionCopyOperation {
    private var document: MarkdownDocument?
    private var saving: Task<Void, Error>?

    init(_ operation: @escaping @MainActor () async throws -> MarkdownDocument) {
        saving = Task { @MainActor [self] in document = try await operation() }
    }
    var value: MarkdownDocument {
        get async throws {
            guard let saving else { throw DiscussionSession.Failure.unavailable }
            try await saving.value
            guard let document else { throw DiscussionSession.Failure.unavailable }
            return document
        }
    }
}

@MainActor
enum ReaderDiscussionFiles {
    static func displayedData(from reader: ReaderState) throws -> Data {
        guard let document = reader.rendered?.discussions,
              document.source.utf8.elementsEqual(reader.source.utf8) else { throw DiscussionSession.Failure.unavailable }
        if let snapshot = reader.currentDiscussionVersion.snapshot,
           try snapshot.source.utf8.elementsEqual(reader.source.utf8) { return snapshot.data }
        return Data(reader.source.utf8)
    }

    static func beginCopy(from reader: ReaderState, to destination: URL) throws -> ReaderDiscussionCopyOperation {
        guard !reader.fileSaving, !reader.isRendering else { throw DiscussionSession.Failure.busy }
        let data = try displayedData(from: reader)
        let drafts = DiscussionSession()
        try reader.discussions.copyDrafts(to: drafts)
        // Accept and capture synchronously in the native Save completion.
        reader.discussionCopySaving = true
        return ReaderDiscussionCopyOperation {
            defer { reader.discussionCopySaving = false }
            let saved = try await DiscussionCopy.create(data, at: destination)
            let copy = try MarkdownDocument(savedCopy: saved)
            try drafts.copyDrafts(to: copy.reader.discussions)
            return copy
        }
    }

    static func makeCopy(from reader: ReaderState, to destination: URL) async throws -> MarkdownDocument {
        let operation = try beginCopy(from: reader, to: destination)
        return try await operation.value
    }

}

extension ReaderState {
    func chooseDiscussionCopy() {
        guard !fileSaving, !isRendering, !discussionImportLoading,
              let document = NSDocumentController.shared.documents.compactMap({ $0 as? MarkdownDocument }).first(where: { $0.reader === self }),
              let window = document.windowControllers.compactMap(\.window).first,
              window.attachedSheet == nil else { return }
        let version = currentDiscussionVersion
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(importedAs: "net.daringfireball.markdown")]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.directoryURL = fileURL?.deletingLastPathComponent()
        panel.title = String(localized: "Review Another Copy")
        panel.prompt = String(localized: "Review")
        panel.message = String(localized: "Review comments and replies before importing. Your document’s prose and the other copy stay unchanged.")
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let self, let url = panel.url else { return }
            guard self.matchesDiscussionVersion(version) else {
                self.discussionError = DiscussionReconciliation.Failure.staleSource.localizedDescription
                return
            }
            Task { await self.reviewDiscussionCopy(url) }
        }
    }

    func saveDiscussionCopy() {
        guard !fileSaving, !isRendering,
              let document = NSDocumentController.shared.documents.compactMap({ $0 as? MarkdownDocument }).first(where: { $0.reader === self }),
              let window = document.windowControllers.compactMap(\.window).first,
              window.attachedSheet == nil else { return }
        let flow = ReaderDiscussionCopyPanel(reader: self)
        let panel = flow.panel
        panel.beginSheetModal(for: window) { [weak self, flow, weak window] response in
            withExtendedLifetime(flow) {
                guard response == .OK, let self, window?.isVisible == true, let destination = panel.url else { return }
                do {
                    let operation = try ReaderDiscussionFiles.beginCopy(from: self, to: destination)
                    Task {
                        do {
                            let copy = try await operation.value
                            NSDocumentController.shared.addDocument(copy)
                            copy.makeWindowControllers(); copy.showWindows()
                            NSDocumentController.shared.noteNewRecentDocumentURL(destination)
                        } catch { self.discussionError = error.localizedDescription }
                    }
                } catch { self.discussionError = error.localizedDescription }
            }
        }
    }
}
