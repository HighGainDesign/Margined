import AppKit
import Observation

@MainActor @Observable
final class ReaderState {
    typealias ChecklistWriter = @Sendable (URL, String, MarkdownTask, UInt8) async throws -> String
    private let checklistWriter: ChecklistWriter?
    @ObservationIgnored private var sourceGate = SourceFileGate()
    @ObservationIgnored private var classifyUpdateTask: Task<Void, Never>?
    @ObservationIgnored private var sourceSnapshot: SourceFileEdit.Snapshot?
    private var pendingDiskSnapshot: SourceFileEdit.Snapshot?
    @ObservationIgnored private var sourceContext = UUID()
    @ObservationIgnored private var renderedContext: UUID?
    let announcements: ReaderAnnouncements
    let discussions = DiscussionSession()
    private(set) var discussionSaving = false
    var discussionError: String?
    private(set) var discussionCopyOffered = false
    var discussionCopySaving = false
    var discussionExportedURL: URL?
    var fileSaving: Bool { checklistSaving || discussionSaving || discussionCopySaving }
    var canUndoDiscussion: Bool { !fileSaving && !isRendering && !hasPendingFileUpdate && discussions.canUndo(snapshot: sourceSnapshot) }
    var canRedoDiscussion: Bool { !fileSaving && !isRendering && !hasPendingFileUpdate && discussions.canRedo(snapshot: sourceSnapshot) }

    var showDiscussions: Bool {
        get { discussions.visible }
        set {
            if newValue { showChanges = false }
            if discussions.visible != newValue { focusIntentGeneration += 1 }
            discussions.visible = newValue
            if newValue, discussions.selection == nil, let first = rendered?.discussions?.threads.first {
                discussions.selection = .thread(first.id)
            }
        }
    }
    var discussionReopenReply: ReaderDiscussionReopenReply?
    var discussionResolution: ReaderDiscussionResolution?
    var discussionReattachment: ReaderDiscussionReattachment?
    @ObservationIgnored var discussionSelectionRequest: ReaderDiscussionSelectionRequest?
    @ObservationIgnored var discussionAuthorRequest: ReaderDiscussionAuthorRequest?
    @ObservationIgnored var discussionAcceptedAction: ReaderDiscussionAcceptedAction?
    var currentDiscussionVersion: ReaderDiscussionVersion { .init(context: sourceContext, snapshot: sourceSnapshot) }
    func matchesDiscussionVersion(_ value: ReaderDiscussionVersion) -> Bool { value.context == sourceContext && value.snapshot == sourceSnapshot }

    private(set) var discussionMargin: DiscussionMarginSnapshot?
    private(set) var discussionPassageID: String?
    var discussionPassageGeneration = 0
    func goToDiscussion(_ threadID: String) {
        guard rendered?.discussionText?.anchorResults[threadID]?.status == .attached else { return }
        openDiscussion(threadID)
        navigationReturnTarget = .discussion(threadID)
        discussionPassageID = threadID; discussionPassageGeneration += 1; focusIntentGeneration += 1
    }
    func acceptDiscussionMargin(_ value: DiscussionMarginSnapshot) {
        guard value.sourceID == rendered?.discussionText?.sourceID else { return }
        if discussionMargin != value { discussionMargin = value }
    }

    var discussionPassagePicker: ReaderDiscussionPassagePicker?
    private(set) var discussionCardFocusGeneration = 0
    private(set) var discussionCardFocusIntent: Int?
    var inspectorDiscussionThreads: [DiscussionThread] {
        let included = Set(filteredDiscussionThreads.map(\.id))
        return (rendered?.discussions?.threads ?? []).filter {
            included.contains($0.id) || discussions.drafts[.thread($0.id)]?.body.isEmpty == false
        }
    }
    func confirmDiscussionPassage(_ unitID: Int) {
        guard let picker = discussionPassagePicker else { return }
        guard matchesDiscussionVersion(picker.request.version), !hasPendingFileUpdate,
              picker.projection.sourceID == rendered?.discussionText?.sourceID else {
            discussionError = DiscussionSession.Failure.staleSource.localizedDescription; return
        }
        guard readyForDiscussionAction() else { return }
        guard let unit = picker.projection.units.first(where: { $0.id == unitID }),
              let selection = picker.projection.selection(unit.range, renderID: "passage-picker-" + picker.id.uuidString) else {
            discussionError = DiscussionSession.Failure.unavailable.localizedDescription; return
        }
        discussionSelectionRequest = picker.request
        discussionPassagePicker = nil
        acceptNewDiscussionSelection(selection)
    }
    func cancelDiscussionPassage() { discussionPassagePicker = nil }
    func selectNextDiscussion(backwards: Bool = false) {
        let threads = filteredDiscussionThreads
        guard !isRendering, !threads.isEmpty else { return }
        let index: Int
        if case let .thread(id) = discussions.selection, let current = threads.firstIndex(where: { $0.id == id }) {
            index = (current + (backwards ? -1 : 1) + threads.count) % threads.count
        } else { index = backwards ? threads.count - 1 : 0 }
        openDiscussion(threads[index].id)
        focusSelectedDiscussion()
    }
    func focusSelectedDiscussion() {
        guard case let .thread(id) = discussions.selection,
              inspectorDiscussionThreads.contains(where: { $0.id == id }) else { return }
        focusIntentGeneration += 1
        discussionCardFocusIntent = focusIntentGeneration
        discussionCardFocusGeneration += 1
    }

    var showDiscussionAuthorPrompt = false
    var discussionSelectionGeneration = 0
    var discussionComposerFocusGeneration = 0
    func requestAddDiscussion() {
        guard discussionPassagePicker == nil, readyForDiscussionAction(), rendered?.discussionText != nil else { return }
        discussionSelectionRequest = .init(intent: .add, version: currentDiscussionVersion)
        discussionSelectionGeneration += 1
    }
    func acceptNewDiscussionSelection(_ selection: DiscussionSelection?) {
        guard let request = discussionSelectionRequest else { return }
        discussionSelectionRequest = nil
        guard matchesDiscussionVersion(request.version), !isRendering else {
            discussionError = DiscussionSession.Failure.staleSource.localizedDescription; return
        }
        guard let projection = rendered?.discussionText else { return }
        guard let selection else {
            showDiscussions = true; discussionError = nil
            discussionPassagePicker = .init(request: request, projection: projection)
            return
        }
        switch request.intent {
        case let .reattach(id): proposeDiscussionReattachment(id, selection: selection)
        case .add:
            do {
                _ = try discussions.beginDraft(selection, in: projection)
                showDiscussions = true; discussionError = nil
                discussionComposerFocusGeneration += 1
            } catch { discussionError = error.localizedDescription }
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
    func openDiscussion(_ threadID: String) {
        guard let thread = rendered?.discussions?.threads.first(where: { $0.id == threadID }) else { return }
        let included: Bool
        switch discussions.filter {
        case .all: included = true
        case .open: included = thread.state == .open
        case .resolved: included = thread.state == .resolved
        case .unattached: included = rendered?.discussionText?.anchorResults[threadID]?.status != .attached
        }
        if !included { discussions.filter = .all }
        discussions.selection = .thread(threadID); showDiscussions = true
    }
    func confirmDiscussionAuthor(_ name: String) { finishDiscussionAuthor(name) }
    func cancelDiscussionAuthor() { discussionAuthorRequest = nil; showDiscussionAuthorPrompt = false }

    private(set) var discussionImportPreview: DiscussionImportPreview?
    private(set) var discussionImportLoading = false
    @ObservationIgnored private var discussionImportSnapshot: SourceFileEdit.Snapshot?
    @ObservationIgnored private var discussionImportRequest = UUID()

    func reviewDiscussionCopy(_ url: URL) async {
        guard !fileSaving && !isRendering && !hasPendingFileUpdate && !showChecklistConfirmation,
              let document = rendered?.discussions, document.source.utf8.elementsEqual(source.utf8) else { return }
        guard fileURL != nil, !isStreamingPreview, let captured = sourceSnapshot else { offerDiscussionCopy(); return }
        discardDiscussionImport()
        let request = discussionImportRequest, context = sourceContext
        discussionImportLoading = true; discussionError = nil
        defer { if discussionImportRequest == request { discussionImportLoading = false } }
        do {
            let incoming = try await DiscussionCopy.read(url)
            guard discussionImportRequest == request, sourceContext == context else { return }
            guard sourceSnapshot == captured, source.utf8.elementsEqual(document.source.utf8) else {
                throw DiscussionReconciliation.Failure.staleSource
            }
            discussionImportPreview = DiscussionReconciliation.preview(current: document, incoming: incoming)
            discussionImportSnapshot = captured
        } catch is CancellationError {
        } catch {
            guard discussionImportRequest == request, sourceContext == context else { return }
            discussionError = error.localizedDescription
        }
    }
    func importDiscussions(choices: [String: DiscussionReconciliation.Choice] = [:]) {
        guard !fileSaving && !isRendering && !hasPendingFileUpdate && !showChecklistConfirmation, !discussionImportLoading,
              let preview = discussionImportPreview else { return }
        do {
            guard let captured = discussionImportSnapshot, sourceSnapshot == captured,
                  source.utf8.elementsEqual(preview.current.source.utf8) else {
                throw DiscussionReconciliation.Failure.staleSource
            }
            if let operation = try discussions.prepareImport(preview, snapshot: captured, choices: choices) {
                commitDiscussion(operation)
            } else {
                discardDiscussionImport()
            }
        } catch { discussionError = error.localizedDescription }
    }
    func discardDiscussionImport() {
        discussionImportRequest = UUID()
        discussionImportPreview = nil; discussionImportSnapshot = nil; discussionImportLoading = false
    }

    func postDiscussion(reopenResolved: Bool = false) {
        guard !fileSaving, !isRendering, !hasPendingFileUpdate, !showChecklistConfirmation,
              let document = rendered?.discussions, document.source.utf8.elementsEqual(source.utf8) else { return }
        guard fileURL != nil, !isStreamingPreview else { offerDiscussionCopy(); return }
        discussionCopyOffered = false
        do {
            let operation = try discussions.preparePost(in: document, snapshot: sourceSnapshot, reopenResolved: reopenResolved)
            if reopenResolved, let decision = discussionReopenReply, decision.key == operation.key {
                discussionAcceptedAction = .init(kind: .reopenReply, decisionID: decision.id, operationID: operation.id)
            }
            ReaderPreferences.defaults.set(discussions.displayName, forKey: "discussionDisplayName")
            commitDiscussion(operation)
        } catch {
            if (error as? DiscussionSession.Failure) == .displayNameRequired, let key = discussions.selection {
                requestDiscussionAuthor(.post(key, reopenResolved))
            } else if (error as? DiscussionSession.Failure) == .reopenRequired,
                      let key = discussions.selection, let draft = discussions.drafts[key] {
                discussionReopenReply = .init(key: key, version: currentDiscussionVersion, draftRevision: draft.revision)
                discussionError = nil
            } else {
                discussionError = error.localizedDescription
                if (error as? DiscussionSession.Failure) == .savedCopyRequired { discussionCopyOffered = true }
            }
        }
    }
    func undoDiscussion() {
        guard canUndoDiscussion, let sourceSnapshot else { return }
        do { commitDiscussion(try discussions.prepareUndo(snapshot: sourceSnapshot)) }
        catch { discussionError = error.localizedDescription }
    }
    func redoDiscussion() {
        guard canRedoDiscussion, let sourceSnapshot else { return }
        do { commitDiscussion(try discussions.prepareRedo(snapshot: sourceSnapshot)) }
        catch { discussionError = error.localizedDescription }
    }
    func resolveDiscussion(_ threadID: String, choice: DiscussionSession.ResolveChoice) {
        guard !fileSaving, !isRendering, !hasPendingFileUpdate, !showChecklistConfirmation,
              let document = rendered?.discussions else { return }
        guard fileURL != nil, !isStreamingPreview else { offerDiscussionCopy(); return }
        do {
            if let operation = try discussions.prepareResolve(threadID: threadID, in: document, snapshot: sourceSnapshot, choice: choice) {
                if let decision = discussionResolution, decision.threadID == threadID {
                    discussionAcceptedAction = .init(kind: .resolve, decisionID: decision.id, operationID: operation.id)
                }
                commitDiscussion(operation)
            }
        } catch {
            if (error as? DiscussionSession.Failure) == .displayNameRequired { requestDiscussionAuthor(.resolve(threadID, choice)) }
            else {
                discussionError = error.localizedDescription
                if (error as? DiscussionSession.Failure) == .savedCopyRequired { discussionCopyOffered = true }
            }
        }
    }
    func offerDiscussionCopy() {
        discussionCopyOffered = true
        discussionError = DiscussionSession.Failure.savedCopyRequired.localizedDescription
    }
    func commitDiscussion(_ operation: DiscussionSession.Pending) {
        guard !fileSaving, fileURL == operation.expected.url, sourceSnapshot == operation.expected else {
            discussions.failed(operation, error: SourceFileEdit.Failure.changed)
            discussionError = SourceFileEdit.Failure.changed.localizedDescription
            return
        }
        let context = sourceContext, revision = externalFileRevision
        let writing = sourceGate.enqueue { try SourceFileEdit.commit(operation.replacement, expected: operation.expected) }
        discussionSaving = true; discussionError = nil; discussionCopyOffered = false
        Task { [weak self, discussions] in
            do {
                let saved = try await writing.value()
                guard let self, sourceContext == context else {
                    discussions.failed(operation, error: CancellationError()); return
                }
                guard revision == externalFileRevision else { throw SourceFileEdit.Failure.changed }
                try discussions.saved(operation, as: saved)
                didSaveDiscussionAction(operation)
                if operation.kind == .importDiscussions { discardDiscussionImport() }
                discussionSaving = false
                receiveDiskSnapshot(saved)
            } catch {
                discussions.failed(operation, error: error)
                guard let self, sourceContext == context else { return }
                discussionSaving = false; discussionError = error.localizedDescription; discussionCopyOffered = true
                reload()
            }
        }
    }
    private var speechModel: ReaderSpeech?
    @ObservationIgnored private let speechFactory: (@MainActor (ReaderState) -> ReaderSpeech)?
    var speech: ReaderSpeech {
        if let speechModel { return speechModel }
        let model = speechFactory?(self) ?? ReaderSpeech(reader: self)
        speechModel = model
        return model
    }
    var existingSpeech: ReaderSpeech? { speechModel }
    var playbackHolding: Bool { speechModel?.isHolding ?? false }
    private var pendingChangesAnnouncement = false
    private var fileUpdateNeedsReviewReset = false
    private var pendingReviewAnnouncement = false

    init(announcements: ReaderAnnouncements = ReaderAnnouncements(),
         checklistWriter: ChecklistWriter? = nil, speechFactory: (@MainActor (ReaderState) -> ReaderSpeech)? = nil) {
        self.announcements = announcements
        self.checklistWriter = checklistWriter
        self.speechFactory = speechFactory
        discussions.displayName = ReaderPreferences.defaults.string(forKey: "discussionDisplayName") ?? ""
    }
    var source = ""
    var title = "Markdown"
    var fileURL: URL? {
        didSet {
            guard fileURL != oldValue else { return }
            speechModel?.close(discardHold: true)
            _ = sourceGate.close(); sourceGate = SourceFileGate()
            discardDiscussionImport()
            discussionMargin = nil; discussionPassageID = nil
            resetDiscussionActions()
            discussionCardFocusIntent = nil
            sourceSnapshot = nil; pendingDiskSnapshot = nil; discussionCopyOffered = false
            sourceContext = UUID(); renderedContext = nil
            externalFileRevision += 1
            cancelChecklistConfirmation()
            checklistMode = false
            checklistSaving = false; pendingChecklistSource = nil
            checklistUndo.removeAll(); checklistRedo.removeAll()
            localImageError = nil
            fileUpdatesPaused = false; pendingFileSource = nil; pendingStreamName = nil
            documentLanguageOverride = nil
        }
    }
    var rendered: RenderedMarkdown?
    var errorMessage: String? {
        didSet { report(errorMessage, oldValue: oldValue, topic: .refreshFailure) }
    }
    var showOutline = false { didSet { if showOutline != oldValue { focusIntentGeneration += 1 } } }
    private var findVisible = false
    private(set) var findFocusGeneration = 0
    private(set) var focusIntentGeneration = 0
    // Cmd-F is a focus request even when the Find bar is already visible.
    var showFind: Bool {
        get { findVisible }
        set {
            findVisible = newValue
            if newValue { findFocusGeneration += 1; focusIntentGeneration += 1 }
        }
    }
    var showChanges = false {
        didSet {
            if showChanges { discussions.visible = false }
            if showChanges != oldValue { focusIntentGeneration += 1 }
        }
    }
    var searchText = "" { didSet { if searchText != oldValue { announcements.cancel(topic: .search) } } }
    var searchBackwards = false
    var searchGeneration = 0
    var searchFound = true {
        didSet {
            if !searchFound && !searchText.isEmpty {
                announcements.schedule(String(localized: "No matches for “\(searchText)”"), topic: .search)
            } else { announcements.cancel(topic: .search) }
        }
    }
    var selectedHeading: String?
    private(set) var navigationRequest: ReaderNavigation?
    private(set) var navigationReturnTarget: ReaderNavigation.ReturnTarget?
    private(set) var returnFocusGeneration = 0
    var navigationGeneration = 0
    var currentChangeIndex = -1
    private(set) var fileUpdatesPaused = false
    private var pendingFileSource: String?
    private var pendingStreamName: String?
    var hasPendingFileUpdate: Bool { pendingFileSource != nil || pendingDiskSnapshot != nil }
    var lastRefreshed: Date?
    var isStreamingPreview = false
    var streamPaused = false
    var streamIsReceiving = false
    var streamSourceName: String?
    var streamError: String? {
        didSet { report(streamError, oldValue: oldValue, topic: .streamFailure) }
    }
    var checklistMode = false { didSet { checklistError = nil } }
    var showChecklistConfirmation = false
    private(set) var pendingChecklistConfirmation: ChecklistConfirmation?
    private(set) var checklistSaving = false
    var checklistError: String? {
        didSet { report(checklistError, oldValue: oldValue, topic: .saveFailure) }
    }
    private var pendingChecklistSource: String?
    private var externalFileRevision = 0
    private var checklistUndo: [ChecklistOperation] = []
    private var checklistRedo: [ChecklistOperation] = []

    var canUndoChecklist: Bool { !playbackHolding && !hasPendingFileUpdate && checklistMode && !fileSaving && !isRendering && !checklistUndo.isEmpty }
    var canRedoChecklist: Bool { !playbackHolding && !hasPendingFileUpdate && checklistMode && !fileSaving && !isRendering && !checklistRedo.isEmpty }
    var zoom = 1.0
    var wide = UserDefaults.standard.object(forKey: "wideLayout") as? Bool ?? true
    var documentAppearance = DocumentAppearance.system
    var documentLanguageOverride: String?
    var loadRemoteImages = false
    var localImageError: String? {
        didSet { report(localImageError, oldValue: oldValue, topic: .imageFailure) }
    }
    var imageReloadGeneration = 0
    private var renderTask: Task<Void, Never>?
    private var readTask: Task<Void, Never>?
    private var reviewedSource: String?
    private var reviewedUnits: [ReadingUnit]?
    private var advanceAfterReview = false
    private(set) var isRendering = false

    var changes: ChangeSummary { rendered?.changes ?? ChangeSummary() }
    var selectedChange: DocumentChange? {
        guard !changes.entries.isEmpty else { return nil }
        return changes.entries[min(max(0, currentChangeIndex), changes.count - 1)]
    }

    private func report(_ message: String?, oldValue: String?, topic: ReaderAnnouncements.Topic) {
        guard message != oldValue else { return }
        if let message { announcements.schedule(message, topic: topic) }
        else { announcements.cancel(topic: topic) }
    }

    private func announceReview() {
        if let change = selectedChange {
            let index = max(0, currentChangeIndex) + 1
            let position = String(localized: "Change \(index) of \(changes.count). \(change.kind.localizedTitle).")
            let remaining = String(localized: "\(changes.count) changes remaining.")
            announcements.schedule(position + " " + remaining, topic: .review)
        } else {
            announcements.schedule(String(localized: "All changes reviewed."), topic: .review)
        }
    }

    func navigate(to id: String, focus: Bool = true, returnTo: ReaderNavigation.ReturnTarget? = nil) {
        requestNavigation(.element(id), focus: focus, returnTo: returnTo ?? .outline(id))
    }

    func focusDocument() {
        requestNavigation(.readingPosition, focus: true, returnTo: showFind ? .find : nil)
    }

    func jumpToUncheckedTask(backwards: Bool = false) {
        requestNavigation(.uncheckedTask(backwards: backwards), focus: true, returnTo: showFind ? .find : nil)
    }

    private func requestNavigation(_ destination: ReaderNavigation.Destination, focus: Bool, returnTo: ReaderNavigation.ReturnTarget?) {
        if focus {
            focusIntentGeneration += 1
            navigationReturnTarget = returnTo
        }
        navigationRequest = ReaderNavigation(destination: destination, focus: focus, focusIntent: focusIntentGeneration)
        navigationGeneration += 1
    }

    func returnToNavigation() {
        guard let target = navigationReturnTarget else { return }
        focusIntentGeneration += 1
        switch target {
        case .find: showFind = true
        case .outline: showOutline = true
        case .review: showChanges = true
        case let .discussion(id):
            guard rendered?.discussions?.threads.contains(where: { $0.id == id }) == true else {
                navigationReturnTarget = nil; return
            }
            openDiscussion(id)
            focusSelectedDiscussion()
        }
        returnFocusGeneration += 1
    }

    func jumpToChange(backwards: Bool = false, focus: Bool = false) {
        let entries = changes.entries
        guard !entries.isEmpty else { return }
        if currentChangeIndex < 0 { currentChangeIndex = backwards ? entries.count - 1 : 0 }
        else { currentChangeIndex = (currentChangeIndex + (backwards ? -1 : 1) + entries.count) % entries.count }
        if let target = entries[currentChangeIndex].targetID { navigate(to: target, focus: focus, returnTo: .review) }
        else if focus {
            navigationReturnTarget = .review
            returnToNavigation()
        }
        announceReview()
    }

    func markReviewed() {
        pendingReviewAnnouncement = true
        reviewedSource = source
        reviewedUnits = nil
        advanceAfterReview = false
        currentChangeIndex = -1
        render()
    }

    func markCurrentChangeReviewed() {
        guard !isRendering, let change = selectedChange,
              var baseline = rendered?.comparisonBaseline else { return }
        let offset = change.baselineOffset
        switch change.kind {
        case .added:
            guard offset <= baseline.count, let replacement = change.replacement else { return }
            baseline.insert(replacement, at: offset)
        case .edited:
            guard baseline.indices.contains(offset), let replacement = change.replacement else { return }
            baseline[offset] = replacement
        case .removed:
            guard baseline.indices.contains(offset) else { return }
            baseline.remove(at: offset)
        }
        pendingReviewAnnouncement = true
        reviewedUnits = baseline
        currentChangeIndex = max(0, currentChangeIndex)
        advanceAfterReview = true
        render()
    }

    /// Keep polling while paused, but retain only the latest on-disk contents.
    /// Invalidate write history immediately even though the displayed page stays put.
    func installLoadedSnapshot(_ snapshot: SourceFileEdit.Snapshot?) {
        guard let snapshot, snapshot.url == fileURL, (try? snapshot.source.utf8.elementsEqual(source.utf8)) == true else { return }
        sourceSnapshot = snapshot
    }

    private func receiveDiskSnapshot(_ snapshot: SourceFileEdit.Snapshot) {
        guard snapshot.url == fileURL, let text = try? snapshot.source else { return }
        if let displayed = sourceSnapshot, displayed != snapshot {
            checklistUndo.removeAll(); checklistRedo.removeAll()
        }
        if fileUpdatesPaused || playbackHolding {
            pendingDiskSnapshot = snapshot == sourceSnapshot ? nil : snapshot
        } else { sourceSnapshot = snapshot; pendingDiskSnapshot = nil }
        receiveFileUpdate(text)
    }

    private func applyPendingDiskSnapshot() {
        if let pendingDiskSnapshot {
            sourceSnapshot = pendingDiskSnapshot; self.pendingDiskSnapshot = nil
        }
    }

    func receiveFileUpdate(_ text: String) {
        guard fileURL != nil, !isStreamingPreview else { return }
        // Even a return to identical text is a new external version. Only the
        // in-flight marker result may be observed without superseding its save.
        if (pendingChecklistSource?.utf8.elementsEqual(text.utf8) != true) { externalFileRevision += 1 }
        if !text.utf8.elementsEqual(source.utf8) && (pendingChecklistSource?.utf8.elementsEqual(text.utf8) != true) {
            checklistUndo.removeAll(); checklistRedo.removeAll()
        }
        if fileUpdatesPaused || playbackHolding {
            let hadPending = hasPendingFileUpdate
            pendingFileSource = text.utf8.elementsEqual(source.utf8) ? nil : text
            if hasPendingFileUpdate {
                announcements.schedule(String(localized: "A newer saved version is waiting. Resume updates to read it."), topic: .updates)
            } else if hadPending {
                announcements.schedule(String(localized: "The saved file matches the displayed version."), topic: .updates)
            }
            errorMessage = nil
            if !fileUpdatesPaused, playbackHolding { classifyHeldUpdate(text) }
        } else {
            acceptFileUpdate(text)
        }
    }
    func waitForFileUpdateClassification() async { await classifyUpdateTask?.value }

    private func classifyHeldUpdate(_ text: String) {
        classifyUpdateTask?.cancel()
        let displayed = source, context = sourceContext, revision = externalFileRevision
        let conversation = existingSpeech?.conversationID, spoken = existingSpeech?.session.document
        classifyUpdateTask = Task { [weak self] in
            let same: Bool
            if let conversation, let spoken {
                same = (try? await MarkdownRenderer.shared.hasSameConversationReadingContent(text,
                    threadID: conversation, spoken: spoken)) == true
            } else { same = (try? await MarkdownRenderer.shared.hasSameReadingContent(displayed, text)) == true }
            guard let self, !Task.isCancelled, sourceContext == context, externalFileRevision == revision,
                  existingSpeech?.conversationID == conversation, existingSpeech?.session.document == spoken,
                  !fileUpdatesPaused, source.utf8.elementsEqual(displayed.utf8), same,
                  pendingFileSource?.utf8.elementsEqual(text.utf8) == true || source.utf8.elementsEqual(text.utf8) else { return }
            applyPendingDiskSnapshot(); pendingFileSource = nil
            announcements.cancel(topic: .updates)
            acceptFileUpdate(text)
        }
    }

    func setFileUpdatesPaused(_ paused: Bool) {
        guard fileURL != nil, !isStreamingPreview else { return }
        guard fileUpdatesPaused != paused else { return }
        fileUpdatesPaused = paused
        announcements.schedule(paused ? String(localized: "File updates paused.") : String(localized: "File updates resumed."), topic: .updates)
        if !paused, !playbackHolding { applyPendingDiskSnapshot() }
        if !paused, !playbackHolding, let latest = pendingFileSource {
            pendingFileSource = nil
            acceptFileUpdate(latest)
        }
    }

    func acceptFileUpdate(_ text: String) {
        if (try? sourceSnapshot?.source.utf8.elementsEqual(text.utf8)) != true { sourceSnapshot = nil }
        if pendingFileSource?.utf8.elementsEqual(text.utf8) == true { pendingFileSource = nil }
        errorMessage = nil
        if !text.utf8.elementsEqual(source.utf8) && (pendingChecklistSource?.utf8.elementsEqual(text.utf8) != true) {
            checklistUndo.removeAll(); checklistRedo.removeAll()
        }
        if reviewedSource == nil { reviewedSource = source }
        lastRefreshed = Date()
        guard !text.utf8.elementsEqual(source.utf8) else { errorMessage = nil; return }
        if (pendingChecklistSource?.utf8.elementsEqual(text.utf8) != true) { pendingChangesAnnouncement = true }
        source = text
        fileUpdateNeedsReviewReset = true
        render()
    }

    struct ChecklistConfirmation {
        let id = UUID()
        let fileURL: URL
        let source: String
        let task: MarkdownTask
        let checked: Bool
    }

    @discardableResult
    func requestTaskChecked(_ id: Int, checked: Bool) -> Bool {
        guard !playbackHolding, !hasPendingFileUpdate, !fileSaving, !isRendering, !showChecklistConfirmation,
              !isStreamingPreview, let fileURL, let rendered, rendered.taskSource.utf8.elementsEqual(source.utf8),
              let task = rendered.tasks.first(where: { $0.id == id }), task.checked != checked else { return false }
        if checklistMode { setTaskChecked(id, checked: checked) }
        else {
            pendingChecklistConfirmation = ChecklistConfirmation(fileURL: fileURL, source: source, task: task, checked: checked)
            showChecklistConfirmation = true
        }
        return true
    }

    func cancelChecklistConfirmation() {
        showChecklistConfirmation = false
        pendingChecklistConfirmation = nil
    }

    func confirmChecklistSaving() {
        guard let pending = pendingChecklistConfirmation else { return }
        cancelChecklistConfirmation()
        guard pending.fileURL == fileURL, !isStreamingPreview else { return }
        checklistMode = true
        guard pending.source.utf8.elementsEqual(source.utf8), !hasPendingFileUpdate else {
            checklistError = ChecklistError.changed.localizedDescription
            reload()
            return
        }
        // The consented gesture already has a validated source descriptor.
        // An appearance-only render need not discard that first change.
        performChecklistChange(task: pending.task, marker: pending.checked ? 120 : 32, history: .normal, allowRendering: true)
    }

    func setTaskChecked(_ id: Int, checked: Bool) {
        guard !playbackHolding, !hasPendingFileUpdate, let rendered, rendered.taskSource.utf8.elementsEqual(source.utf8),
              let task = rendered.tasks.first(where: { $0.id == id }), task.checked != checked else { return }
        performChecklistChange(task: task, marker: checked ? 120 : 32, history: .normal)
    }

    func undoChecklist() {
        guard canUndoChecklist, let operation = checklistUndo.last else { return }
        performChecklistChange(task: operation.task, marker: operation.marker, history: .undo)
    }

    func redoChecklist() {
        guard canRedoChecklist, let operation = checklistRedo.last else { return }
        performChecklistChange(task: operation.task, marker: operation.marker, history: .redo)
    }

    private func performChecklistChange(task: MarkdownTask, marker: UInt8, history: ChecklistHistory, allowRendering: Bool = false) {
        guard !playbackHolding, !hasPendingFileUpdate, checklistMode, !fileSaving, (!isRendering || allowRendering), !isStreamingPreview, let fileURL else { return }
        let expected = source
        let revision = externalFileRevision
        do {
            pendingChecklistSource = try MarkdownSource.decode(MarkdownTasks.patch(Data(expected.utf8), expectedSource: expected, task: task, marker: marker))
        } catch { checklistError = error.localizedDescription; return }
        checklistSaving = true
        checklistError = nil
        let writer = checklistWriter
        let operation: SourceFileGate.Operation<SourceFileEdit.Snapshot>?
        if writer == nil, let snapshot = sourceSnapshot,
           (try? snapshot.source.utf8.elementsEqual(expected.utf8)) == true {
            operation = sourceGate.enqueue { try SourceFileEdit.setMarker(marker, at: task.utf8Offset, was: task.marker, expected: snapshot) }
        } else { operation = nil }
        Task { [weak self] in
            do {
                let saved: SourceFileEdit.Snapshot?
                let updated: String
                if let writer { updated = try await writer(fileURL, expected, task, marker); saved = nil }
                else if let operation { saved = try await operation.value(); updated = try saved!.source }
                else { throw SourceFileEdit.Failure.changed }
                guard let self, self.fileURL == fileURL else { return }
                // A newer file reception may have completed while the committed
                // write's result was travelling back to the UI actor.
                guard externalFileRevision == revision, source.utf8.elementsEqual(expected.utf8) || source.utf8.elementsEqual(updated.utf8) else {
                    checklistSaving = false; pendingChecklistSource = nil
                    checklistUndo.removeAll(); checklistRedo.removeAll()
                    checklistError = ChecklistError.changed.localizedDescription
                    return
                }
                let newerVersionWaiting = pendingFileSource != nil && pendingFileSource?.utf8.elementsEqual(updated.utf8) != true
                sourceSnapshot = saved
                acceptFileUpdate(updated)
                let inverse = ChecklistOperation(task: MarkdownTask(id: task.id, utf8Offset: task.utf8Offset, marker: marker, label: task.label), marker: task.marker)
                if newerVersionWaiting {
                    checklistUndo.removeAll(); checklistRedo.removeAll()
                } else {
                    switch history {
                    case .normal: checklistUndo.append(inverse); checklistRedo.removeAll()
                    case .undo: if !checklistUndo.isEmpty { checklistUndo.removeLast() }; checklistRedo.append(inverse)
                    case .redo: if !checklistRedo.isEmpty { checklistRedo.removeLast() }; checklistUndo.append(inverse)
                    }
                }
                if checklistUndo.count > 100 { checklistUndo.removeFirst() }
                checklistSaving = false
                pendingChecklistSource = nil
            } catch {
                guard let self, self.fileURL == fileURL else { return }
                checklistSaving = false
                pendingChecklistSource = nil
                checklistError = error.localizedDescription
                checklistUndo.removeAll(); checklistRedo.removeAll()
                reload()
            }
        }
    }

    private enum ChecklistHistory { case normal, undo, redo }
    private struct ChecklistOperation { let task: MarkdownTask; let marker: UInt8 }

    func render() {
        #if MARGINED_BENCHMARK
        ViewingBenchmarkSession.current?.recordOpening("render_enqueued_ns", source: source)
        #endif
        renderTask?.cancel()
        isRendering = true
        let text = source, title = title, wide = wide, loadRemoteImages = loadRemoteImages
        let appearance = documentAppearance, language = documentLanguageOverride
        let baseline = fileURL == nil ? nil : reviewedSource
        let units = fileURL == nil ? nil : reviewedUnits
        let context = sourceContext
        let previousProjection = renderedContext == context && fileURL != nil ? rendered?.discussionText : nil
        let previousDiscussions = renderedContext == context && fileURL != nil ? rendered?.discussions : nil
        let initialRead = sourceSnapshot == nil && !hasPendingFileUpdate ? fileURL.map { url in
            sourceGate.enqueue { try SourceFileEdit.read(url) }
        } : nil
        renderTask = Task { [weak self] in
            #if MARGINED_BENCHMARK
            ViewingBenchmarkSession.current?.recordOpening("render_task_started_ns", source: text)
            #endif
            do {
                if let initialRead, let captured = try? await initialRead.value(),
                   let self, sourceContext == context, source.utf8.elementsEqual(text.utf8),
                   (try? captured.source.utf8.elementsEqual(text.utf8)) == true, !hasPendingFileUpdate {
                    sourceSnapshot = captured
                }
                #if MARGINED_BENCHMARK
                ViewingBenchmarkSession.current?.recordOpening("renderer_requested_ns", source: text)
                #endif
                let output = try await MarkdownRenderer.shared.render(text, title: title, wide: wide, baseline: baseline, reviewedUnits: units, loadRemoteImages: loadRemoteImages, appearance: appearance, mapTasks: self?.fileURL != nil, documentLanguage: language, prepareSpeech: true, speechOptions: self?.speechModel?.preferences.options ?? SpeechPreferences.shared.options, previousDiscussionProjection: previousProjection, previousDiscussions: previousDiscussions)
                guard !Task.isCancelled, self?.sourceContext == context else { return }
                let sameReview = self?.rendered?.changes.entries == output.changes.entries
                self?.renderedContext = context
                self?.rendered = output
                if let projection = output.discussionText { self?.discussions.acceptProjection(projection) }
                self?.errorMessage = nil
                self?.isRendering = false
                #if MARGINED_BENCHMARK
                ViewingBenchmarkSession.current?.didRender(source: text, output: output)
                #endif
                if let self {
                    if fileUpdateNeedsReviewReset && !sameReview { currentChangeIndex = -1 }
                    fileUpdateNeedsReviewReset = false
                    currentChangeIndex = output.changes.count == 0 ? -1 : min(max(0, currentChangeIndex), output.changes.count - 1)
                    if pendingReviewAnnouncement {
                        pendingReviewAnnouncement = false
                        pendingChangesAnnouncement = false
                        announceReview()
                    } else if pendingChangesAnnouncement {
                        pendingChangesAnnouncement = false
                        if !sameReview { announcements.schedule(String(localized: "\(output.changes.count) unreviewed changes available."), topic: .changes) }
                    }
                    if advanceAfterReview {
                        advanceAfterReview = false
                        if let target = selectedChange?.targetID { navigate(to: target, focus: false) }
                    }
                }
            } catch {
                guard !Task.isCancelled, self?.sourceContext == context else { return }
                self?.errorMessage = error.localizedDescription
                self?.isRendering = false
            }
        }
    }

    /// Poll the pathname, rather than an inode, to support atomic saves by agents/editors.
    /// The SwiftUI task cancels when its document window closes.
    func watchFile() async {
        #if MARGINED_BENCHMARK
        ViewingBenchmarkSession.current?.recordOpening("watch_started_ns", source: source)
        #endif
        if isStreamingPreview { await watchStream(); return }
        if reviewedSource == nil { reviewedSource = source }
        render()
        guard let fileURL else { return }
        var lastStamp = FileStamp(url: fileURL)
        while !Task.isCancelled {
            do { try await Task.sleep(for: .seconds(1)) } catch { return }
            let stamp = FileStamp(url: fileURL)
            guard !fileSaving, stamp != lastStamp || errorMessage != nil else { continue }
            let reading = sourceGate.enqueue { try SourceFileEdit.read(fileURL) }
            do {
                let snapshot = try await reading.value()
                guard !Task.isCancelled, self.fileURL == fileURL else { return }
                // A save during the asynchronous read makes that snapshot obsolete.
                guard FileStamp(url: fileURL) == stamp else { continue }
                lastStamp = stamp
                receiveDiskSnapshot(snapshot)
            } catch {
                guard !Task.isCancelled else { return }
                errorMessage = String(localized: "Could not refresh: \(error.localizedDescription)")
            }
        }
    }

    func watchStream(_ stream: MarkdownStream = MarkdownStream()) async {
        render()
        var lastCount: Int?
        while !Task.isCancelled && isStreamingPreview {
            if !streamPaused {
                do {
                    if let snapshot = try stream.read(after: lastCount) {
                        lastCount = snapshot.count
                        streamError = nil
                        switch snapshot.update {
                        case .waiting:
                            streamIsReceiving = false
                            if !playbackHolding { streamSourceName = nil }
                        case .text(let text, let sourceName):
                            receiveStreamUpdate(text, sourceName: sourceName)
                        }
                    }
                } catch {
                    lastCount = stream.pasteboard.changeCount
                    streamIsReceiving = false
                    streamError = String(localized: "Could not read live preview: \(error.localizedDescription)")
                }
            }
            do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
        }
    }

    func receiveStreamUpdate(_ text: String, sourceName: String?) {
        guard isStreamingPreview else { return }
        streamIsReceiving = true; lastRefreshed = Date()
        if playbackHolding {
            if source.utf8.elementsEqual(text.utf8) && streamSourceName == sourceName {
                pendingFileSource = nil; pendingStreamName = nil
            } else {
                pendingFileSource = text; pendingStreamName = sourceName
            }
        } else {
            streamSourceName = sourceName
            if !source.utf8.elementsEqual(text.utf8) { source = text; render() }
        }
    }

    func applyPendingPlaybackVersion() {
        applyPendingDiskSnapshot()
        guard let latest = pendingFileSource else { return }
        pendingFileSource = nil
        if isStreamingPreview {
            let name = pendingStreamName; pendingStreamName = nil
            receiveStreamUpdate(latest, sourceName: name)
        } else { acceptFileUpdate(latest) }
    }

    func reload() {
        #if MARGINED_APP_STORE
        SandboxImageFolders.shared.refresh()
        #endif
        localImageError = nil
        imageReloadGeneration += 1
        guard let fileURL else { render(); return }
        readTask?.cancel()
        readTask = Task { [weak self] in
            do {
                let stamp = FileStamp(url: fileURL)
                let reading = self?.sourceGate.enqueue { try SourceFileEdit.read(fileURL) }
                guard let reading else { return }
                let snapshot = try await reading.value()
                guard !Task.isCancelled, let self, self.fileURL == fileURL else { return }
                guard FileStamp(url: fileURL) == stamp else { self.reload(); return }
                receiveDiskSnapshot(snapshot)
            } catch {
                guard !Task.isCancelled else { return }
                self?.errorMessage = error.localizedDescription
            }
        }
    }

    func changeZoom(by amount: Double) { zoom = min(2.0, max(0.6, zoom + amount)) }

    func stop() {
        resetDiscussionActions()
        discussionCardFocusIntent = nil
        discussionMargin = nil; discussionPassageID = nil
        discardDiscussionImport()
        classifyUpdateTask?.cancel()
        sourceContext = UUID()
        _ = sourceGate.close()
        speechModel?.close(discardHold: true)
        cancelChecklistConfirmation()
        checklistMode = false
        pendingFileSource = nil; pendingStreamName = nil
        streamPaused = true
        isStreamingPreview = false
        renderTask?.cancel()
        isRendering = false
        readTask?.cancel()
        announcements.cancel()
    }
}

private struct FileStamp: Equatable {
    let modified: Date?
    let size: UInt64?
    let inode: UInt64?

    init(url: URL) {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        modified = attributes?[.modificationDate] as? Date
        size = attributes?[.size] as? UInt64
        inode = attributes?[.systemFileNumber] as? UInt64
    }
}
