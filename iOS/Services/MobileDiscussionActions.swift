import Foundation

struct MobileDiscussionVersion {
    let context: UUID
    let snapshot: SourceFileEdit.Snapshot?
}
struct MobileDiscussionSelectionRequest {
    enum Intent { case add, reattach(String) }
    let intent: Intent
    let version: MobileDiscussionVersion
}
struct MobileDiscussionPassagePicker: Identifiable {
    let id = UUID()
    let request: MobileDiscussionSelectionRequest
    let projection: DiscussionTextProjection
    var version: MobileDiscussionVersion { request.version }
}
struct MobileDiscussionDecision: Identifiable {
    enum Kind { case resolve(String, UUID?), reopenReply(DiscussionSession.DraftKey, UUID), reattach(String, DiscussionTarget, DiscussionSelection) }
    let id = UUID()
    let version: MobileDiscussionVersion
    let kind: Kind
    var key: DiscussionSession.DraftKey {
        switch kind { case let .resolve(id, _): .thread(id); case let .reopenReply(key, _): key; case let .reattach(id, _, _): .thread(id) }
    }
    var checksDraftRevision: Bool { if case .reattach = kind { return false }; return true }
    var draftRevision: UUID? {
        switch kind { case let .resolve(_, revision): revision; case let .reopenReply(_, revision): revision; case .reattach: nil }
    }
}
enum MobileDiscussionRoute: Hashable { case list, thread(DiscussionSession.DraftKey) }

extension MobileReaderState {
    var discussionNavigationPath: [MobileDiscussionRoute] {
        get {
            guard inspector == .discussions else { return [] }
            return [.list] + (discussionRoute.map { [.thread($0)] } ?? [])
        }
        set {
            switch newValue.last {
            case .thread(let key): inspector = .discussions; discussionRoute = key; discussions.selection = key
            case .list: inspector = .discussions; discussionRoute = nil
            case nil: inspector = nil; discussionRoute = nil
            }
        }
    }
    var filteredDiscussionThreads: [DiscussionThread] {
        (rendered?.discussions?.threads ?? []).filter { thread in
            switch discussions.filter {
            case .all: true
            case .open: thread.state == .open
            case .resolved: thread.state == .resolved
            case .unattached: rendered?.discussionText?.anchorResults[thread.id]?.status != .attached
            }
        }
    }
    var inspectorDiscussionThreads: [DiscussionThread] {
        let included = Set(filteredDiscussionThreads.map(\.id))
        return (rendered?.discussions?.threads ?? []).filter {
            included.contains($0.id) || discussions.drafts[.thread($0.id)]?.body.isEmpty == false
        }
    }
    func matchesDiscussionVersion(_ version: MobileDiscussionVersion) -> Bool {
        version.context == documentGeneration && version.snapshot == currentDiscussionVersion.snapshot
    }
    func confirmDiscussionPassage(_ unitID: Int, pickerID: UUID) {
        guard let picker = discussionPassagePicker, picker.id == pickerID else { return }
        guard matchesDiscussionVersion(picker.version), !hasPendingFileUpdate,
              picker.projection.sourceID == rendered?.discussionText?.sourceID else {
            discussionError = DiscussionSession.Failure.staleSource.localizedDescription; return
        }
        guard canEditDiscussions else { return }
        guard let unit = picker.projection.units.first(where: { $0.id == unitID }),
              let selection = picker.projection.selection(unit.range, renderID: "passage-picker-" + picker.id.uuidString) else {
            discussionError = DiscussionSession.Failure.unavailable.localizedDescription; return
        }
        discussionSelectionRequest = picker.request
        discussionPassagePicker = nil
        acceptNewDiscussionSelection(selection)
    }
    func cancelDiscussionPassage(pickerID: UUID) {
        guard discussionPassagePicker?.id == pickerID else { return }
        discussionPassagePicker = nil
    }
    func requestReattachDiscussion(_ threadID: String) {
        guard discussionPassagePicker == nil, canEditDiscussions,
              rendered?.discussions?.threads.contains(where: { $0.id == threadID }) == true else { return }
        guard fileURL != nil else { offerDiscussionCopy(); return }
        discussionDecision = nil
        discussionSelectionRequest = .init(intent: .reattach(threadID), version: currentDiscussionVersion)
        discussionSelectionGeneration += 1
    }
    func proposeDiscussionReattachment(_ threadID: String, selection: DiscussionSelection) {
        guard canEditDiscussions, let projection = rendered?.discussionText,
              let thread = rendered?.discussions?.threads.first(where: { $0.id == threadID }),
              projection.selection(selection.range, renderID: selection.renderID) == selection else {
            discussionError = DiscussionSession.Failure.staleSource.localizedDescription; return
        }
        discussionDecision = .init(version: currentDiscussionVersion, kind: .reattach(threadID, thread.target, selection))
        openDiscussion(threadID); discussionError = nil
    }
    func confirmDiscussionReattachment(_ decisionID: UUID) {
        guard let decision = discussionDecision, decision.id == decisionID,
              case let .reattach(threadID, _, selection) = decision.kind,
              canConfirmDiscussionDecision(decision),
              let document = rendered?.discussions, let projection = rendered?.discussionText else { return }
        do {
            let operation = try discussions.prepareReattach(threadID: threadID, selection: selection,
                projection: projection, in: document, snapshot: decision.version.snapshot)
            commitDiscussion(operation, decisionID: decisionID)
        } catch { discussionError = error.localizedDescription }
    }
    func requestResolveDiscussion(_ threadID: String) {
        guard canEditDiscussions, rendered?.discussions?.threads.contains(where: { $0.id == threadID && $0.state == .open }) == true else { return }
        let revision = discussions.drafts[.thread(threadID)]?.revision
        if discussions.drafts[.thread(threadID)]?.body.isEmpty == false {
            discussionDecision = .init(version: currentDiscussionVersion, kind: .resolve(threadID, revision))
            discussionError = nil
        } else { resolveDiscussion(threadID, choice: .discardDraft) }
    }
    func confirmDiscussionResolution(_ decisionID: UUID, choice: DiscussionSession.ResolveChoice) {
        guard let decision = discussionDecision, decision.id == decisionID,
              case let .resolve(threadID, _) = decision.kind else { return }
        if choice == .keepOpen { cancelDiscussionDecision(decisionID); return }
        guard canConfirmDiscussionDecision(decision) else { return }
        resolveDiscussion(threadID, choice: choice, decisionID: decisionID)
    }
    func confirmDiscussionReopenReply(_ decisionID: UUID) {
        guard let decision = discussionDecision, decision.id == decisionID,
              case let .reopenReply(key, _) = decision.kind,
              discussions.selection == key, canConfirmDiscussionDecision(decision) else { return }
        postDiscussion(reopenResolved: true, decisionID: decisionID)
    }
    func cancelDiscussionDecision(_ decisionID: UUID) {
        guard !fileSaving, discussionDecision?.id == decisionID else { return }
        discussionDecision = nil
    }
    func canConfirmDiscussionDecision(_ decision: MobileDiscussionDecision) -> Bool {
        guard canEditDiscussions else { return false }
        guard matchesDiscussionVersion(decision.version) else {
            discussionError = DiscussionSession.Failure.staleSource.localizedDescription; return false
        }
        guard !decision.checksDraftRevision || discussions.drafts[decision.key]?.revision == decision.draftRevision else {
            discussionError = String(localized: "Your reply changed. Review it before confirming again."); return false
        }
        return true
    }
    func reopenDiscussion(_ threadID: String) {
        guard canEditDiscussions, let document = rendered?.discussions,
              document.threads.contains(where: { $0.id == threadID && $0.state == .resolved }) else { return }
        guard fileURL != nil else { offerDiscussionCopy(); return }
        do { commitDiscussion(try discussions.prepareReopen(threadID: threadID, in: document, snapshot: currentDiscussionVersion.snapshot)) }
        catch { discussionError = error.localizedDescription }
    }
    func requestAddDiscussion() {
        guard discussionPassagePicker == nil, canEditDiscussions, rendered?.discussionText != nil else { return }
        discussionSelectionRequest = .init(intent: .add, version: currentDiscussionVersion)
        discussionSelectionGeneration += 1
    }
    func acceptNewDiscussionSelection(_ selection: DiscussionSelection?) {
        guard let request = discussionSelectionRequest else { return }
        discussionSelectionRequest = nil
        guard matchesDiscussionVersion(request.version), canEditDiscussions, let projection = rendered?.discussionText else {
            discussionError = DiscussionSession.Failure.staleSource.localizedDescription; return
        }
        guard let selection else {
            discussionError = nil
            discussionPassagePicker = .init(request: request, projection: projection)
            return
        }
        switch request.intent {
        case let .reattach(threadID): proposeDiscussionReattachment(threadID, selection: selection)
        case .add:
            do {
                let key = try discussions.beginDraft(selection, in: projection)
                inspector = .discussions; discussionRoute = key; discussionError = nil
            } catch { discussionError = error.localizedDescription }
        }
    }
    func openDiscussion(_ threadID: String) {
        guard rendered?.discussions?.threads.contains(where: { $0.id == threadID }) == true else { return }
        if !filteredDiscussionThreads.contains(where: { $0.id == threadID }) { discussions.filter = .all }
        discussions.selection = .thread(threadID); discussionRoute = .thread(threadID); inspector = .discussions
    }
    func backToDiscussionList() { discussionRoute = nil; inspector = .discussions }
    func hideDiscussions() { inspector = nil; discussionRoute = nil }
    func acceptDiscussionMargin(_ value: DiscussionMarginSnapshot) {
        guard value.sourceID == rendered?.discussionText?.sourceID else { return }
        discussionMargin = value
    }
}
