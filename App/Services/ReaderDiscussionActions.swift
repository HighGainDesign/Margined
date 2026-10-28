import Foundation

struct ReaderDiscussionVersion {
    let context: UUID
    let snapshot: SourceFileEdit.Snapshot?
}
struct ReaderDiscussionResolution: Identifiable {
    let id = UUID()
    let threadID: String
    let version: ReaderDiscussionVersion
    let draftRevision: UUID?
}
struct ReaderDiscussionReattachment: Identifiable {
    let id = UUID()
    let threadID: String
    let originalTarget: DiscussionTarget
    let selection: DiscussionSelection
    let version: ReaderDiscussionVersion
}
struct ReaderDiscussionSelectionRequest {
    enum Intent { case add, reattach(String) }
    let intent: Intent
    let version: ReaderDiscussionVersion
}
struct ReaderDiscussionReopenReply: Identifiable {
    let id = UUID()
    let key: DiscussionSession.DraftKey
    let version: ReaderDiscussionVersion
    let draftRevision: UUID
}
struct ReaderDiscussionAuthorRequest {
    enum Action { case post(DiscussionSession.DraftKey, Bool), resolve(String, DiscussionSession.ResolveChoice), reattach(UUID), rename }
    let action: Action
    let version: ReaderDiscussionVersion
}
struct ReaderDiscussionPassagePicker: Identifiable {
    let id = UUID()
    let request: ReaderDiscussionSelectionRequest
    let projection: DiscussionTextProjection
}

struct ReaderDiscussionAcceptedAction {
    enum Kind { case resolve, reattach, reopenReply }
    let kind: Kind
    let decisionID: UUID
    let operationID: UUID
}

extension ReaderState {
    func requestReattachDiscussion(_ threadID: String) {
        guard discussionPassagePicker == nil, readyForDiscussionAction(), rendered?.discussions?.threads.contains(where: { $0.id == threadID }) == true else { return }
        discussionSelectionRequest = .init(intent: .reattach(threadID), version: currentDiscussionVersion)
        discussionSelectionGeneration += 1
    }
    func requestChangeDiscussionAuthor() { requestDiscussionAuthor(.rename) }
    func confirmDiscussionReopenReply() {
        guard let decision = discussionReopenReply, readyForDiscussionAction() else { return }
        guard matchesDiscussionVersion(decision.version), discussions.selection == decision.key,
              discussions.drafts[decision.key]?.revision == decision.draftRevision else {
            discussionError = DiscussionSession.Failure.staleSource.localizedDescription; return
        }
        postDiscussion(reopenResolved: true)
    }
    func cancelDiscussionReopenReply() { discussionReopenReply = nil }

    func requestDiscussionAuthor(_ action: ReaderDiscussionAuthorRequest.Action) {
        discussionAuthorRequest = .init(action: action, version: currentDiscussionVersion)
        showDiscussionAuthorPrompt = true; showDiscussions = true; discussionError = nil
    }
    var discussionAuthorButtonTitle: String {
        switch discussionAuthorRequest?.action {
        case .resolve: String(localized: "Use Name and Resolve")
        case .reattach: String(localized: "Use Name and Attach")
        case .rename: String(localized: "Save Name")
        default: String(localized: "Use Name and Post")
        }
    }
    func finishDiscussionAuthor(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        discussions.displayName = trimmed
        ReaderPreferences.defaults.set(trimmed, forKey: "discussionDisplayName")
        showDiscussionAuthorPrompt = false
        guard let request = discussionAuthorRequest else { return }
        discussionAuthorRequest = nil
        if case .rename = request.action { return }
        guard matchesDiscussionVersion(request.version) else { discussionError = DiscussionSession.Failure.staleSource.localizedDescription; return }
        switch request.action {
        case let .post(key, reopen):
            guard discussions.selection == key else { discussionError = DiscussionSession.Failure.unavailable.localizedDescription; return }
            postDiscussion(reopenResolved: reopen)
        case let .resolve(id, choice): resolveDiscussion(id, choice: choice)
        case let .reattach(id):
            guard discussionReattachment?.id == id else { return }
            confirmDiscussionReattachment()
        case .rename: break
        }
    }
    func requestResolveDiscussion(_ threadID: String) {
        guard readyForDiscussionAction(), rendered?.discussions?.threads.contains(where: { $0.id == threadID }) == true else { return }
        let draft = discussions.drafts[.thread(threadID)]
        if draft?.body.isEmpty == false {
            discussionResolution = .init(threadID: threadID, version: currentDiscussionVersion, draftRevision: draft?.revision)
        } else { resolveDiscussion(threadID, choice: .discardDraft) }
    }
    func confirmDiscussionResolution(_ choice: DiscussionSession.ResolveChoice) {
        guard let decision = discussionResolution else { return }
        if choice == .keepOpen { cancelDiscussionResolution(); return }
        guard readyForDiscussionAction(), matchesDiscussionVersion(decision.version),
              discussions.drafts[.thread(decision.threadID)]?.revision == decision.draftRevision else {
            discussionError = DiscussionSession.Failure.staleSource.localizedDescription; return
        }
        resolveDiscussion(decision.threadID, choice: choice)
    }
    func cancelDiscussionResolution() { discussionResolution = nil }
    func reopenDiscussion(_ threadID: String) {
        guard readyForDiscussionAction(), let document = rendered?.discussions else { return }
        do { commitDiscussion(try discussions.prepareReopen(threadID: threadID, in: document, snapshot: currentDiscussionVersion.snapshot)) }
        catch { discussionError = error.localizedDescription }
    }
    func proposeDiscussionReattachment(_ threadID: String, selection: DiscussionSelection) {
        guard readyForDiscussionAction(), let projection = rendered?.discussionText,
              let thread = rendered?.discussions?.threads.first(where: { $0.id == threadID }) else { return }
        guard selection.sourceID == projection.sourceID,
              projection.selection(selection.range, renderID: selection.renderID) == selection else {
            discussionError = DiscussionSession.Failure.staleSource.localizedDescription; return
        }
        discussionReattachment = .init(threadID: threadID, originalTarget: thread.target, selection: selection, version: currentDiscussionVersion)
        showDiscussions = true; discussionError = nil
    }
    func confirmDiscussionReattachment() {
        guard let decision = discussionReattachment, readyForDiscussionAction(),
              let document = rendered?.discussions, let projection = rendered?.discussionText else { return }
        guard matchesDiscussionVersion(decision.version) else { discussionError = DiscussionSession.Failure.staleSource.localizedDescription; return }
        do {
            let operation = try discussions.prepareReattach(threadID: decision.threadID, selection: decision.selection,
                projection: projection, in: document, snapshot: decision.version.snapshot)
            discussionAcceptedAction = .init(kind: .reattach, decisionID: decision.id, operationID: operation.id)
            commitDiscussion(operation)
        } catch {
            if (error as? DiscussionSession.Failure) == .displayNameRequired { requestDiscussionAuthor(.reattach(decision.id)) }
            else { discussionError = error.localizedDescription }
        }
    }
    func cancelDiscussionReattachment() { discussionReattachment = nil }
    func readyForDiscussionAction() -> Bool {
        guard !fileSaving, !isRendering, !hasPendingFileUpdate, !showChecklistConfirmation else { return false }
        guard fileURL != nil, !isStreamingPreview, currentDiscussionVersion.snapshot != nil else { offerDiscussionCopy(); return false }
        return true
    }
    func didSaveDiscussionAction(_ operation: DiscussionSession.Pending) {
        if operation.kind == .post, discussions.selection == operation.key, discussions.drafts[operation.key] == nil {
            discussions.selection = .thread(operation.threadID)
        }
        guard let accepted = discussionAcceptedAction, accepted.operationID == operation.id else { return }
        switch accepted.kind {
        case .resolve: if discussionResolution?.id == accepted.decisionID { discussionResolution = nil }
        case .reattach: if discussionReattachment?.id == accepted.decisionID { discussionReattachment = nil }
        case .reopenReply: if discussionReopenReply?.id == accepted.decisionID { discussionReopenReply = nil }
        }
        discussionAcceptedAction = nil
    }
    func resetDiscussionActions() {
        discussionResolution = nil; discussionReattachment = nil; discussionReopenReply = nil
        discussionSelectionRequest = nil; discussionPassagePicker = nil
        discussionAcceptedAction = nil; discussionAuthorRequest = nil; showDiscussionAuthorPrompt = false
    }
}
