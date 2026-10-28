import AppKit

struct ReaderDiscussionExport: Sendable {
    enum Kind: Sendable { case clean, conversation }
    let kind: Kind
    let data: Data
    let removedBlocks: Int

    var title: String {
        switch kind {
        case .clean: String(localized: "Export Clean Copy")
        case .conversation: String(localized: "Export Conversations")
        }
    }
    var filenameSuffix: String {
        switch kind {
        case .clean: String(localized: "Clean")
        case .conversation: String(localized: "Conversations")
        }
    }
    var message: String {
        switch kind {
        case .clean:
            let count = removedBlocks == 1 ? String(localized: "This copy removes one saved discussion.") : String(localized: "This copy removes \(removedBlocks) saved discussions.")
            return count + " " + String(localized: "Your original stays unchanged. Unposted comments are not included. Image files stay in their current folders.")
        case .conversation:
            return String(localized: "Exports all saved discussions as readable Markdown. Your original stays unchanged. Unposted comments are not included.")
        }
    }
}

extension ReaderDiscussionFiles {
    static func prepareExport(_ kind: ReaderDiscussionExport.Kind, from reader: ReaderState) throws -> ReaderDiscussionExport {
        guard !reader.fileSaving, !reader.isRendering else { throw DiscussionSession.Failure.busy }
        let data = try displayedData(from: reader)
        switch kind {
        case .clean:
            let clean = try DiscussionExports.cleanCopy(data)
            return .init(kind: kind, data: clean.data, removedBlocks: clean.removedBlocks)
        case .conversation:
            guard let document = reader.rendered?.discussions else { throw DiscussionSession.Failure.unavailable }
            return .init(kind: kind, data: Data(DiscussionExports.conversation(document).utf8), removedBlocks: 0)
        }
    }
    static func beginExport(_ prepared: ReaderDiscussionExport, from reader: ReaderState, to destination: URL) throws -> Task<Void, Error> {
        guard !reader.fileSaving else { throw DiscussionSession.Failure.busy }
        reader.discussionCopySaving = true
        return Task { @MainActor in
            defer { reader.discussionCopySaving = false }
            _ = try await DiscussionCopy.create(prepared.data, at: destination)
        }
    }
}

extension ReaderState {
    func exportDiscussions(_ kind: ReaderDiscussionExport.Kind) {
        guard !fileSaving, !isRendering,
              let document = NSDocumentController.shared.documents.compactMap({ $0 as? MarkdownDocument }).first(where: { $0.reader === self }),
              let window = document.windowControllers.compactMap(\.window).first,
              window.attachedSheet == nil else { return }
        discussionError = nil; discussionExportedURL = nil
        do {
            let prepared = try ReaderDiscussionFiles.prepareExport(kind, from: self)
            let flow = ReaderDiscussionCopyPanel(reader: self, export: prepared)
            let panel = flow.panel
            panel.beginSheetModal(for: window) { [weak self, flow, weak window] response in
                withExtendedLifetime(flow) {
                    guard response == .OK, let self, window?.isVisible == true, let destination = panel.url else { return }
                    do {
                        // Accept synchronously before creating any UI completion task.
                        let saving = try ReaderDiscussionFiles.beginExport(prepared, from: self, to: destination)
                        Task {
                            do {
                                try await saving.value
                                self.discussionExportedURL = destination
                                self.announcements.schedule(String(localized: "Copy exported."), topic: .updates)
                            } catch { self.reportDiscussionExportError(error) }
                        }
                    } catch { self.reportDiscussionExportError(error) }
                }
            }
        } catch { reportDiscussionExportError(error) }
    }
    func inspectDiscussionSource() {
        ReaderDiscussionSourceWindow.show(source: source, title: fileURL?.lastPathComponent ?? title,
            context: currentDiscussionVersion.context, zoom: zoom, reader: self)
    }
    private func reportDiscussionExportError(_ error: Error) {
        discussionError = error.localizedDescription
        announcements.schedule(error.localizedDescription, topic: .saveFailure)
    }
}
