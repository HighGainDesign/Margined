import Foundation

/// A system print job uses the displayed snapshot, independent of later updates.
struct MobilePrintRequest: Identifiable {
    let id = UUID()
    let context: UUID
    let output: RenderedMarkdown
    let title: String
    let fileURL: URL?
    let includeDiscussions: Bool
    let loadRemoteImages: Bool
}

extension MobileReaderState {
    func requestPrint(includeDiscussions: Bool) {
        guard printRequest == nil, hasDocument, !isOpening, !isRendering, !fileSaving,
              !showChecklistConfirmation, !showDraftDiscardConfirmation,
              let output = rendered, output.taskSource.utf8.elementsEqual(source.utf8) else { return }
        printRequest = .init(context: documentGeneration, output: output, title: title,
            fileURL: fileURL, includeDiscussions: includeDiscussions, loadRemoteImages: loadRemoteImages)
    }
    func finishPrint(_ requestID: UUID) {
        guard printRequest?.id == requestID else { return }
        printRequest = nil
    }
}
