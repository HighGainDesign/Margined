import Foundation

struct MobileDiscussionCopyRequest: Identifiable {
    let id = UUID()
    let version: MobileDiscussionVersion
}
struct MobileDiscussionImportReview: Identifiable {
    let id = UUID()
    let version: MobileDiscussionVersion
    let preview: DiscussionImportPreview
    let incomingName: String
}
enum MobileDiscussionSheet: Identifiable {
    case passage(MobileDiscussionPassagePicker), importReview(MobileDiscussionImportReview), export(MobileDiscussionExport)
    var id: UUID { switch self { case let .passage(value): value.id; case let .importReview(value): value.id; case let .export(value): value.id } }
}
extension MobileReaderState {
    var discussionSheet: MobileDiscussionSheet? {
        if let passage = discussionPassagePicker { return .passage(passage) }
        if let review = discussionImportReview { return .importReview(review) }
        if let export = discussionExport { return .export(export) }
        return nil
    }
    func dismissDiscussionSheet(_ id: UUID) {
        if discussionPassagePicker?.id == id { cancelDiscussionPassage(pickerID: id) }
        else if discussionImportReview?.id == id { cancelDiscussionImportReview(id) }
        else if discussionExport?.id == id { cancelDiscussionExport(id) }
    }
    func requestReviewAnotherCopy() {
        guard canEditDiscussions, !discussionImportLoading, discussionPassagePicker == nil,
              discussionCopyRequest == nil, discussionImportReview == nil, discussionExport == nil else { return }
        inspector = .discussions; discussionRoute = nil
        guard fileURL != nil else { offerDiscussionCopy(); return }
        discardDiscussionImport(); discussionDecision = nil; discussionError = nil
        discussionCopyRequest = .init(version: currentDiscussionVersion)
    }
    func completeDiscussionCopyPicker(_ url: URL, request: MobileDiscussionCopyRequest) async {
        guard discussionCopyRequest?.id == request.id else { return }
        discussionCopyRequest = nil
        guard matchesDiscussionVersion(request.version) else {
            discussionError = DiscussionReconciliation.Failure.staleSource.localizedDescription; return
        }
        await reviewDiscussionCopy(url)
        guard documentGeneration == request.version.context else { return }
        guard matchesDiscussionVersion(request.version) else {
            discardDiscussionImport(); discussionError = DiscussionReconciliation.Failure.staleSource.localizedDescription; return
        }
        guard let preview = discussionImportPreview else { return }
        discussionImportReview = .init(version: request.version, preview: preview, incomingName: url.lastPathComponent)
    }
    func cancelDiscussionCopyPicker(_ requestID: UUID) {
        guard discussionCopyRequest?.id == requestID else { return }
        discussionCopyRequest = nil
    }
    func confirmDiscussionImport(_ reviewID: UUID, choices: [String: DiscussionReconciliation.Choice] = [:]) {
        guard let review = discussionImportReview, review.id == reviewID else { return }
        guard matchesDiscussionVersion(review.version) else {
            discussionError = DiscussionReconciliation.Failure.staleSource.localizedDescription; return
        }
        importDiscussions(choices: choices)
    }
    func cancelDiscussionImportReview(_ reviewID: UUID) {
        guard !fileSaving, discussionImportReview?.id == reviewID else { return }
        discardDiscussionImport()
    }
}
