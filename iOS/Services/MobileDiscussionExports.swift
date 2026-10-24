import Foundation

struct MobileDiscussionExport: Identifiable {
    enum Kind: Equatable { case savedCopy, markdown, clean, conversation }
    let id = UUID()
    let kind: Kind
    let version: MobileDiscussionVersion
    let source: String
    let data: Data
    let removedBlocks: Int
    var title: String {
        switch kind {
        case .savedCopy: String(localized: "Save Markdown Copy")
        case .markdown: String(localized: "Save Markdown with Discussions")
        case .clean: String(localized: "Export Clean Copy")
        case .conversation: String(localized: "Export Conversations")
        }
    }
    var suffix: String {
        switch kind {
        case .savedCopy, .markdown: String(localized: "Copy")
        case .clean: String(localized: "Clean")
        case .conversation: String(localized: "Conversations")
        }
    }
}
struct MobileDiscussionExportResult: Identifiable {
    let id = UUID()
    let url: URL
    let saved: SourceFileEdit.Snapshot
    let reader: MobileReaderState?
}

/// The folder remains scoped while its picker, save and any child open use it.
@MainActor final class MobileDiscussionExportFolder {
    let url: URL
    private let started: Bool
    init(_ url: URL) { self.url = url; started = url.startAccessingSecurityScopedResource() }
    deinit { if started { url.stopAccessingSecurityScopedResource() } }
}

extension MobileReaderState {
    func requestDiscussionExport(_ kind: MobileDiscussionExport.Kind) {
        guard canEditDiscussions, !discussionImportLoading, discussionSheet == nil,
              discussionCopyRequest == nil else { return }
        discussionError = nil
        do {
            guard let document = rendered?.discussions, document.source.utf8.elementsEqual(source.utf8) else {
                throw DiscussionSession.Failure.unavailable
            }
            let data: Data
            if let snapshot = currentDiscussionVersion.snapshot, try snapshot.source.utf8.elementsEqual(source.utf8) {
                data = snapshot.data
            } else { data = Data(source.utf8) }
            let output: Data, removed: Int
            switch kind {
            case .savedCopy, .markdown: output = data; removed = 0
            case .clean:
                let clean = try DiscussionExports.cleanCopy(data); output = clean.data; removed = clean.removedBlocks
            case .conversation: output = Data(DiscussionExports.conversation(document).utf8); removed = 0
            }
            discussionExport = .init(kind: kind, version: currentDiscussionVersion,
                source: source, data: output, removedBlocks: removed)
        } catch { discussionError = error.localizedDescription }
    }
    func createDiscussionExport(_ exportID: UUID, at destination: URL, folder: URL? = nil) {
        guard let export = discussionExport, export.id == exportID, discussionExportResult == nil, canEditDiscussions else { return }
        guard matchesDiscussionVersion(export.version), source.utf8.elementsEqual(export.source.utf8) else {
            discussionError = DiscussionSession.Failure.staleSource.localizedDescription; return
        }
        let scope = folder.map { MobileDiscussionExportFolder($0) }
        discussionError = nil
        performDiscussionFileSave { [self, scope] in
            defer { withExtendedLifetime(scope) {} }
            var child: MobileReaderState?
            do {
                let saved = try await DiscussionCopy.create(export.data, at: destination)
                if export.kind == .savedCopy {
                    let copy = makeDiscussionCopyReader(); child = copy
                    await copy.open(url: destination); await copy.waitForRendering()
                    guard copy.hasDocument, copy.currentDiscussionVersion.snapshot == saved else { throw SourceFileEdit.Failure.changed }
                    if let scope { try await copy.access.addFolderAccess(scope.url) }
                }
                guard documentGeneration == export.version.context, discussionExport?.id == export.id else {
                    if let child { await child.close() }; return
                }
                discussionExportResult = .init(url: destination, saved: saved, reader: child)
            } catch {
                if let child { await child.close() }
                guard documentGeneration == export.version.context else { return }
                discussionError = error.localizedDescription
            }
        }
    }
    func requestOpenDiscussionCopy(_ resultID: UUID) {
        guard !fileSaving, discussionExportResult?.id == resultID, discussionExportResult?.reader != nil else { return }
        discussionCopyOpenRequest = resultID
    }
    /// Called synchronously by the workspace before replacing its visible reader.
    /// It transfers the latest drafts, never filesystem-bound Undo history.
    func takeDiscussionCopyToOpen(_ resultID: UUID) throws -> MobileReaderState? {
        guard let export = discussionExport, let result = discussionExportResult, result.id == resultID else { return nil }
        defer { discussionCopyOpenRequest = nil }
        guard canEditDiscussions, matchesDiscussionVersion(export.version), source.utf8.elementsEqual(export.source.utf8),
              let copy = result.reader, !copy.isRendering, copy.hasDocument,
              copy.currentDiscussionVersion.snapshot == result.saved,
              let projection = copy.rendered?.discussionText else { throw DiscussionSession.Failure.staleSource }
        try discussions.copyDrafts(to: copy.discussions)
        copy.discussions.acceptProjection(projection)
        copy.inspector = inspector
        copy.discussionRoute = discussionRoute
        if copy.discussions.hasUnpostedDrafts { copy.inspector = .discussions }
        discussions.discardDrafts()
        discussionExportResult = nil; discussionExport = nil
        return copy
    }
    func cancelDiscussionExport(_ exportID: UUID) {
        guard !fileSaving, discussionExport?.id == exportID else { return }
        let child = discussionExportResult?.reader
        discussionExport = nil; discussionExportResult = nil; discussionCopyOpenRequest = nil
        if let child { Task { await child.close() } }
    }
}
