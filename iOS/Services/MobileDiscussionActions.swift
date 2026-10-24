import Foundation

struct MobileDiscussionVersion {
    let context: UUID
    let snapshot: SourceFileEdit.Snapshot?
}
struct MobileDiscussionPassagePicker: Identifiable {
    let id = UUID()
    let version: MobileDiscussionVersion
    let projection: DiscussionTextProjection
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
    func confirmDiscussionPassage(_ unitID: Int) {
        guard let picker = discussionPassagePicker else { return }
        guard matchesDiscussionVersion(picker.version), !hasPendingFileUpdate,
              picker.projection.sourceID == rendered?.discussionText?.sourceID else {
            discussionError = DiscussionSession.Failure.staleSource.localizedDescription; return
        }
        guard canEditDiscussions else { return }
        guard let unit = picker.projection.units.first(where: { $0.id == unitID }),
              let selection = picker.projection.selection(unit.range, renderID: "passage-picker-" + picker.id.uuidString) else {
            discussionError = DiscussionSession.Failure.unavailable.localizedDescription; return
        }
        discussionSelectionRequest = picker.version
        discussionPassagePicker = nil
        acceptNewDiscussionSelection(selection)
    }
    func cancelDiscussionPassage() { discussionPassagePicker = nil }
    func requestAddDiscussion() {
        guard discussionPassagePicker == nil, canEditDiscussions, rendered?.discussionText != nil else { return }
        discussionSelectionRequest = currentDiscussionVersion
        discussionSelectionGeneration += 1
    }
    func acceptNewDiscussionSelection(_ selection: DiscussionSelection?) {
        guard let version = discussionSelectionRequest else { return }
        discussionSelectionRequest = nil
        guard matchesDiscussionVersion(version), canEditDiscussions, let projection = rendered?.discussionText else {
            discussionError = DiscussionSession.Failure.staleSource.localizedDescription; return
        }
        guard let selection else {
            discussionError = nil
            discussionPassagePicker = .init(version: version, projection: projection)
            return
        }
        do {
            let key = try discussions.beginDraft(selection, in: projection)
            inspector = .discussions; discussionRoute = key; discussionError = nil
        } catch { discussionError = error.localizedDescription }
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
