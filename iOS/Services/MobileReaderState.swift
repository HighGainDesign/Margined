import Foundation
import Observation
import UIKit

/// One document's displayed version. File and playback lifetimes are owned by
/// their services; asynchronous results are fenced by document/lease identity.
@MainActor @Observable
final class MobileReaderState {
    let id = UUID()
    let playback: MobilePlaybackOwner
    let access: MobileDocumentAccess
    let discussions = DiscussionSession()
    var answerDraft: ShortAnswerDraft?
    var answerFocusReturnGeneration = 0
    func answerEditorDidDismiss() { answerFocusReturnGeneration &+= 1 }
    var canSaveAnswer: Bool {
        guard let draft = answerDraft, !draft.saving, draft.validationMessage == nil else { return false }
        return answerUnavailableReason == nil
    }
    var answerUnavailableReason: String? {
        guard let draft = answerDraft else { return nil }
        guard !draft.stale, let current = snapshot, draft.context == current.leaseID,
              fileURL == draft.expected.url, current.sourceSnapshot == draft.expected,
              (try? draft.expected.source.utf8.elementsEqual(source.utf8)) == true else {
            return String(localized: "The file changed. Copy your answer, close this editor, then reopen it in the latest version.")
        }
        if playbackHolding { return String(localized: "Stop Read Aloud before saving this answer.") }
        if hasPendingFileUpdate { return String(localized: "A newer file version is waiting. Copy your answer and reopen it in the latest version.") }
        if !answerFileReady { return String(localized: "Wait for the file to finish updating before saving this answer.") }
        return nil
    }
    @discardableResult
    func beginAnswer(_ id: Int) -> Bool {
        guard canWrite, let captured = snapshot, let output = rendered,
              output.taskSource.utf8.elementsEqual(source.utf8), captured.source.utf8.elementsEqual(source.utf8),
              let field = output.responses.answers.first(where: { $0.id == id }) else { return false }
        answerDraft = .init(field: field, expected: captured.sourceSnapshot, context: captured.leaseID)
        return true
    }
    func saveAnswer() {
        guard let draft = answerDraft, !draft.saving else { return }
        guard canSaveAnswer else { draft.error = answerUnavailableReason ?? draft.validationMessage; return }
        do {
            let edit = try MarkdownResponses.answerEdit(source: source, field: draft.field, text: draft.text)
            if edit.splices.isEmpty { answerDraft = nil; return }
            if !saveResponse(edit, history: .normal, draft: draft) { draft.error = errorMessage ?? answerUnavailableReason }
        } catch { draft.error = error.localizedDescription }
    }
    func cancelAnswer() { if answerDraft?.saving != true { answerDraft = nil } }
    enum Inspector: Hashable { case changes, discussions }
    var inspector: Inspector? {
        didSet {
            if inspector != oldValue {
                discussionPresentationGeneration = UUID()
                if inspector != .discussions { endDiscussionEditing() }
            }
        }
    }
    var discussionRoute: DiscussionSession.DraftKey? {
        didSet { if discussionRoute != oldValue { discussionPresentationGeneration = UUID() } }
    }
    @ObservationIgnored private(set) var discussionPresentationGeneration = UUID()
    var discussionSheetExpanded = false
    var discussionFocus: MobileDiscussionFocus?
    var discussionEditingDismissal = 0
    @ObservationIgnored var discussionComposerSelections: [DiscussionSession.DraftKey: NSRange] = [:]
    @ObservationIgnored var discussionEndEditing: (() -> Void)?
    @ObservationIgnored var discussionHistoryPositions: [String: DiscussionHistoryPresentationState] = [:]

    func endDiscussionEditing() { discussionEditingDismissal += 1; discussionEndEditing?(); discussionEndEditing = nil; discussionFocus = nil }
    func discussionHistoryPosition(for thread: String) -> DiscussionHistoryPresentationState {
        if let value = discussionHistoryPositions[thread] { return value }
        let value = DiscussionHistoryPresentationState()
        discussionHistoryPositions[thread] = value
        return value
    }
    var discussionPassageRequest: MobileDiscussionPassageRequest?
    var discussionDecision: MobileDiscussionDecision?
    var discussionCopyRequest: MobileDiscussionCopyRequest?
    var discussionImportReview: MobileDiscussionImportReview?
    var discussionExport: MobileDiscussionExport?
    var discussionExportResult: MobileDiscussionExportResult?
    var discussionShare: MobileDiscussionShare?
    var discussionCopyOpenRequest: UUID?
    private(set) var discussionCopySaving = false
    var discussionPassagePicker: MobileDiscussionPassagePicker?
    var discussionSelectionGeneration = 0
    var discussionSelectionRequest: MobileDiscussionSelectionRequest?
    var discussionMargin: DiscussionMarginSnapshot?
    @ObservationIgnored private(set) var discussionLayoutGeneration = UUID()
    var discussionUsesMargin = false {
        didSet {
            if discussionUsesMargin != oldValue { discussionLayoutGeneration = UUID() }
        }
    }
    var currentDiscussionVersion: MobileDiscussionVersion {
        .init(context: openGeneration, snapshot: snapshot?.sourceSnapshot)
    }
    private(set) var discussionSaving = false
    var discussionError: String?
    private(set) var discussionCopyOffered = false
    var fileSaving: Bool { checklistSaving || discussionSaving || discussionCopySaving }
    var canUndoDiscussion: Bool { canEditDiscussions && discussions.canUndo(snapshot: snapshot?.sourceSnapshot) }
    var canRedoDiscussion: Bool { canEditDiscussions && discussions.canRedo(snapshot: snapshot?.sourceSnapshot) }
    private(set) var discussionImportPreview: DiscussionImportPreview?
    private(set) var discussionImportLoading = false
    @ObservationIgnored private var discussionImportSnapshot: SourceFileEdit.Snapshot?
    @ObservationIgnored private var discussionImportRequest = UUID()

    func reviewDiscussionCopy(_ url: URL) async {
        guard canEditDiscussions,
              let document = rendered?.discussions, document.source.utf8.elementsEqual(source.utf8) else { return }
        guard fileURL != nil, let captured = snapshot?.sourceSnapshot else { offerDiscussionCopy(); return }
        discardDiscussionImport()
        let request = discussionImportRequest, context = openGeneration
        discussionImportLoading = true; discussionError = nil
        defer { if discussionImportRequest == request { discussionImportLoading = false } }
        do {
            let incoming = try await DiscussionCopy.read(url)
            guard discussionImportRequest == request, openGeneration == context else { return }
            guard snapshot?.sourceSnapshot == captured, source.utf8.elementsEqual(document.source.utf8) else {
                throw DiscussionReconciliation.Failure.staleSource
            }
            discussionImportPreview = DiscussionReconciliation.preview(current: document, incoming: incoming)
            discussionImportSnapshot = captured
        } catch is CancellationError {
        } catch {
            guard discussionImportRequest == request, openGeneration == context else { return }
            discussionError = error.localizedDescription
        }
    }
    func importDiscussions(choices: [String: DiscussionReconciliation.Choice] = [:]) {
        guard canEditDiscussions, !discussionImportLoading,
              let preview = discussionImportPreview else { return }
        do {
            guard let captured = discussionImportSnapshot, snapshot?.sourceSnapshot == captured,
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
        discussionImportReview = nil
    }

    func postDiscussion(reopenResolved: Bool = false, decisionID: UUID? = nil) {
        guard canEditDiscussions, let document = rendered?.discussions,
              document.source.utf8.elementsEqual(source.utf8) else { return }
        guard fileURL != nil else { offerDiscussionCopy(); return }
        discussionCopyOffered = false
        do {
            let operation = try discussions.preparePost(in: document, snapshot: snapshot?.sourceSnapshot, reopenResolved: reopenResolved)
            defaults.set(discussions.displayName, forKey: "discussionDisplayName")
            commitDiscussion(operation, decisionID: decisionID)
        } catch {
            if (error as? DiscussionSession.Failure) == .reopenRequired,
               let key = discussions.selection, let draft = discussions.drafts[key] {
                discussionDecision = .init(version: currentDiscussionVersion, kind: .reopenReply(key, draft.revision))
                discussionError = nil; return
            }
            discussionError = error.localizedDescription
            if (error as? DiscussionSession.Failure) == .savedCopyRequired { discussionCopyOffered = true }
        }
    }
    func undoDiscussion() {
        guard canUndoDiscussion, let snapshot else { return }
        do { commitDiscussion(try discussions.prepareUndo(snapshot: snapshot.sourceSnapshot)) }
        catch { discussionError = error.localizedDescription }
    }
    func redoDiscussion() {
        guard canRedoDiscussion, let snapshot else { return }
        do { commitDiscussion(try discussions.prepareRedo(snapshot: snapshot.sourceSnapshot)) }
        catch { discussionError = error.localizedDescription }
    }
    func resolveDiscussion(_ threadID: String, choice: DiscussionSession.ResolveChoice, decisionID: UUID? = nil) {
        guard canEditDiscussions, let document = rendered?.discussions else { return }
        guard fileURL != nil else { offerDiscussionCopy(); return }
        do {
            if let operation = try discussions.prepareResolve(threadID: threadID, in: document, snapshot: snapshot?.sourceSnapshot, choice: choice) {
                commitDiscussion(operation, decisionID: decisionID)
            }
        } catch {
            discussionError = error.localizedDescription
            if (error as? DiscussionSession.Failure) == .savedCopyRequired { discussionCopyOffered = true }
        }
    }
    var canEditDiscussions: Bool {
        answerDraft == nil && !isOpening && !isRendering && !fileSaving && !showChecklistConfirmation && !hasPendingFileUpdate
    }
    func offerDiscussionCopy() {
        discussionCopyOffered = true
        discussionError = DiscussionSession.Failure.savedCopyRequired.localizedDescription
    }
    func commitDiscussion(_ operation: DiscussionSession.Pending, decisionID: UUID? = nil) {
        guard canEditDiscussions, let captured = snapshot, captured.sourceSnapshot == operation.expected else {
            discussions.failed(operation, error: SourceFileEdit.Failure.changed)
            discussionError = SourceFileEdit.Failure.changed.localizedDescription
            return
        }
        let generation = openGeneration, revision = externalRevision
        discussionSaving = true; discussionError = nil; discussionCopyOffered = false
        saveTask = Task { [weak self, access, discussions] in
            do {
                let saved = try await access.replace(expected: captured, with: operation.replacement)
                guard let self, generation == openGeneration else {
                    discussions.failed(operation, error: CancellationError()); return
                }
                guard revision == externalRevision, access.snapshot == saved else { throw SourceFileEdit.Failure.changed }
                try discussions.saved(operation, as: saved.sourceSnapshot)
                if let decisionID, discussionDecision?.id == decisionID { discussionDecision = nil }
                if operation.kind == .post, discussions.selection == operation.key,
                   discussions.drafts[operation.key] == nil {
                    discussions.selection = .thread(operation.threadID)
                    // Promote only the destination still being read. Back or a
                    // different thread opened during the save keeps its place.
                    if discussionRoute == operation.key { discussionRoute = .thread(operation.threadID) }
                }
                if operation.kind == .importDiscussions { discardDiscussionImport() }
                discussionSaving = false; receive(saved)
            } catch {
                discussions.failed(operation, error: error)
                guard let self, generation == openGeneration else { return }
                discussionSaving = false; discussionError = error.localizedDescription; discussionCopyOffered = true
                await refresh()
            }
        }
    }
    var showDraftDiscardConfirmation = false
    private enum DocumentTransition { case open(URL), preview(URL), close }
    private var pendingTransition: DocumentTransition?
    private var transitionRequest = UUID()
    func cancelDocumentTransition() {
        transitionRequest = UUID(); pendingTransition = nil; showDraftDiscardConfirmation = false
    }
    func confirmDiscardDrafts() async {
        guard let transition = pendingTransition else { return }
        pendingTransition = nil; showDraftDiscardConfirmation = false
        discussions.discardDrafts()
        switch transition {
        case let .open(url): await open(url: url)
        case let .preview(url): await openPreview(url: url)
        case .close: await close()
        }
    }
    @ObservationIgnored private let defaults: UserDefaults
    private(set) var source = ""
    private(set) var title = "Margined"
    private(set) var fileURL: URL?
    private(set) var rendered: RenderedMarkdown?
    var printRequest: MobilePrintRequest?
    private(set) var hasDocument = false
    private(set) var isOpening = false
    private(set) var isRendering = false
    private(set) var checklistSaving = false
    var checklistMode = false
    var showChecklistConfirmation = false
    var errorMessage: String? {
        didSet {
            if let errorMessage, errorMessage != oldValue, UIAccessibility.isVoiceOverRunning {
                UIAccessibility.post(notification: .announcement, argument: errorMessage)
            }
        }
    }
    var localImageError: String? {
        didSet {
            if let localImageError, localImageError != oldValue, UIAccessibility.isVoiceOverRunning {
                UIAccessibility.post(notification: .announcement, argument: localImageError)
            }
        }
    }
    var zoom = 1.0
    var wide: Bool
    var appearance: DocumentAppearance
    var loadRemoteImages = false
    var imageReloadGeneration = 0
    var navigationGeneration = 0
    var navigationTarget: String?
    var searchGeneration = 0
    var searchText = ""
    var searchBackwards = false
    var searchMatch: Bool?
    var speechStartRequest: UUID?
    var speechStartMode = "visible"
    private var speechPreparationTask: Task<Void, Never>?
    @ObservationIgnored private var speechPreparationIntent = UUID()
    private var speechRequestedOwnership: (owner: UUID, intent: UUID)?
    var speechPreparing: Bool { speechPreparationTask != nil || speechStartRequest != nil }
    private var speechRequestedFingerprint: String?
    private var suspendedProse: (context: UUID, fingerprint: String, options: SpeechOptions, index: Int, offset: Int)?
    private(set) var fileUpdatesPaused = false
    private(set) var currentChangeIndex = 0
    private var snapshot: MobileDocumentSnapshot?
    private var pendingSnapshot: MobileDocumentSnapshot?
    private var reviewedSource: String?
    private var reviewedUnits: [ReadingUnit]?
    private var externalRevision = 0
    private var fileUpdateNeedsReviewReset = false
    private var openGeneration = UUID()
    @ObservationIgnored private var classifyUpdateTask: Task<Void, Never>?
    @ObservationIgnored private var renderTask: Task<Void, Never>?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    private var pendingConsent: Consent?
    private var undoStack: [Operation] = []
    private var redoStack: [Operation] = []

    init(access: MobileDocumentAccess = MobileDocumentAccess(), playback: MobilePlaybackOwner = MobilePlaybackOwner(),
         defaults: UserDefaults = ReaderPreferences.defaults) {
        self.access = access; self.playback = playback; self.defaults = defaults
        discussions.displayName = defaults.string(forKey: "discussionDisplayName") ?? ""
        wide = defaults.object(forKey: "fullWidthByDefault") as? Bool ?? true
        appearance = ReaderPreferences.appearance(in: defaults)
        access.onChange = { [weak self] in self?.receive($0) }
        access.onError = { [weak self] in self?.errorMessage = $0.localizedDescription }
    }

    var documentGeneration: UUID { openGeneration }
    var playbackHolding: Bool { playback.ownerID == id && playback.playbackHolding }
    var hasPendingFileUpdate: Bool { pendingSnapshot != nil }
    var changes: ChangeSummary { rendered?.changes ?? ChangeSummary() }
    var selectedChange: DocumentChange? {
        changes.entries.isEmpty ? nil : changes.entries[min(currentChangeIndex, changes.count - 1)]
    }
    var undoFileTitle: String { undoStack.last?.isResponse == true ? String(localized: "Undo Response Change") : String(localized: "Undo Checkbox Change") }
    var redoFileTitle: String { redoStack.last?.isResponse == true ? String(localized: "Redo Response Change") : String(localized: "Redo Checkbox Change") }
    var canUndoChecklist: Bool { canWrite && !undoStack.isEmpty }
    var canRedoChecklist: Bool { canWrite && !redoStack.isEmpty }
    var canWrite: Bool { answerDraft == nil && answerFileReady }
    private var answerFileReady: Bool {
        fileURL != nil && !isOpening && !isRendering && !fileSaving &&
        !showChecklistConfirmation && !hasPendingFileUpdate && !playbackHolding
    }

    func open(url: URL) async {
        let request = UUID(); transitionRequest = request
        let inFlightSave = saveTask
        await inFlightSave?.value
        guard transitionRequest == request else { return }
        if discussions.hasUnpostedDrafts {
            pendingTransition = .open(url); showDraftDiscardConfirmation = true; return
        }
        let generation = UUID(); openGeneration = generation
        resetForOpen(); isOpening = true
        guard generation == openGeneration else { return }
        do {
            let value = try await access.open(url: url)
            guard openGeneration == generation else { return }
            let latest = access.snapshot.flatMap { $0.leaseID == value.leaseID ? $0 : nil } ?? value
            snapshot = latest; fileURL = latest.url; title = latest.url.lastPathComponent
            source = latest.source; reviewedSource = latest.source; hasDocument = true
            isOpening = false; render()
        } catch {
            guard openGeneration == generation else { return }
            isOpening = false; errorMessage = error.localizedDescription
        }
    }

    func openPreview(url: URL) async {
        do {
            let preview = try PreviewRequest(url: url)
            let request = UUID(); transitionRequest = request
            let inFlightSave = saveTask
            await inFlightSave?.value
            guard transitionRequest == request else { return }
            if discussions.hasUnpostedDrafts {
                pendingTransition = .preview(url); showDraftDiscardConfirmation = true; return
            }
            let generation = UUID(); openGeneration = generation
            resetForOpen(); isOpening = true
            guard generation == openGeneration else { return }
            await access.close()
            guard generation == openGeneration else { return }
            source = preview.text; title = preview.title; hasDocument = true; isOpening = false
            render()
        } catch { errorMessage = error.localizedDescription }
    }

    func close() async {
        let request = UUID(); transitionRequest = request
        // Hide an accepted close immediately, while the immutable lease and
        // session continue draining its accepted save. A draft stays visible
        // until its save succeeds or the user explicitly discards it.
        if !discussions.hasUnpostedDrafts { hasDocument = false; fileURL = nil }
        let inFlightSave = saveTask
        await inFlightSave?.value
        guard transitionRequest == request else { return }
        if discussions.hasUnpostedDrafts {
            pendingTransition = .close; showDraftDiscardConfirmation = true; return
        }
        let generation = UUID(); openGeneration = generation
        resetForOpen(); hasDocument = false
        guard generation == openGeneration else { return }
        await access.close()
    }

    private func resetForOpen() {
        answerDraft?.stale = true
        cancelSpeechPreparation()
        suspendedProse = nil
        printRequest = nil
        playback.documentWillChange(ownerID: id)
        renderTask?.cancel(); classifyUpdateTask?.cancel(); isRendering = false
        discardDiscussionImport()
        if let export = discussionExport { cancelDiscussionExport(export.id) }
        if let share = discussionShare { finishDiscussionShare(share.id) }
        inspector = nil; discussionRoute = nil; discussionSelectionRequest = nil; discussionMargin = nil
        discussionSheetExpanded = false; discussionFocus = nil; discussionEndEditing = nil
        discussionComposerSelections.removeAll(); discussionHistoryPositions.removeAll()
        discussionPassagePicker = nil; discussionDecision = nil
        discussionCopyRequest = nil
        discussions.resetDocument(); discussionSaving = false; discussionError = nil; discussionCopyOffered = false
        pendingTransition = nil; showDraftDiscardConfirmation = false
        fileURL = nil; snapshot = nil; pendingSnapshot = nil
        reviewedSource = nil; reviewedUnits = nil; rendered = nil
        source = ""; title = "Margined"; hasDocument = false; isOpening = false
        wide = defaults.object(forKey: "fullWidthByDefault") as? Bool ?? true
        appearance = ReaderPreferences.appearance(in: defaults)
        checklistMode = false; checklistSaving = false; pendingConsent = nil
        showChecklistConfirmation = false; fileUpdatesPaused = false
        undoStack.removeAll(); redoStack.removeAll(); externalRevision += 1
        errorMessage = nil; localImageError = nil; loadRemoteImages = false
        discussionPassageRequest = nil
        navigationTarget = nil; navigationGeneration += 1
        searchText = ""; searchMatch = nil; searchGeneration += 1
        speechStartRequest = nil; speechRequestedFingerprint = nil
        currentChangeIndex = 0; fileUpdateNeedsReviewReset = false; imageReloadGeneration += 1
    }

    func refresh() async {
        guard fileURL != nil else { return }
        let generation = openGeneration
        do {
            let value = try await access.refresh()
            guard generation == openGeneration else { return }
            receive(value)
        } catch is CancellationError { }
        catch { if generation == openGeneration { errorMessage = error.localizedDescription } }
    }

    func setPresented(_ visible: Bool) async {
        await access.setPresented(visible)
        if visible { await refresh() }
    }

    func retryLocalImages() { localImageError = nil; imageReloadGeneration += 1 }

    func addFolderAccess(_ url: URL) async {
        let generation = openGeneration
        do {
            try await access.addFolderAccess(url)
            guard generation == openGeneration else { return }
            localImageError = nil; imageReloadGeneration += 1
        } catch is CancellationError { }
        catch { if generation == openGeneration { errorMessage = error.localizedDescription } }
    }

    private func receive(_ value: MobileDocumentSnapshot) {
        guard let current = snapshot, value.leaseID == current.leaseID else { return }
        fileURL = value.url; title = value.url.lastPathComponent
        guard value != current || pendingSnapshot != nil else { return }
        answerDraft?.stale = true
        externalRevision += 1; undoStack.removeAll(); redoStack.removeAll()
        cancelChecklistConfirmation()
        errorMessage = nil
        if fileUpdatesPaused || playbackHolding {
            pendingSnapshot = value == current ? nil : value
            if !fileUpdatesPaused, playbackHolding, pendingSnapshot != nil {
                classifyHeldUpdate(value, displayed: current)
            } else if playback.ownerID == id {
                if pendingSnapshot != nil { playback.notePendingVersion(ownerID: id) }
                else { playback.clearPendingVersion(ownerID: id) }
            }
        } else { apply(value) }
    }
    func waitForFileUpdateClassification() async { await classifyUpdateTask?.value }

    private func classifyHeldUpdate(_ value: MobileDocumentSnapshot, displayed: MobileDocumentSnapshot) {
        classifyUpdateTask?.cancel()
        let generation = openGeneration, conversation = playback.conversationID, spoken = playback.spokenDocument
        classifyUpdateTask = Task { [weak self] in
            let same: Bool
            if let conversation, let spoken {
                same = (try? await MarkdownRenderer.shared.hasSameConversationReadingContent(value.source,
                    threadID: conversation, spoken: spoken)) == true
            } else { same = (try? await MarkdownRenderer.shared.hasSameReadingContent(displayed.source, value.source)) == true }
            guard let self, !Task.isCancelled, generation == openGeneration,
                  playback.ownerID == id, playback.conversationID == conversation, playback.spokenDocument == spoken,
                  snapshot == displayed, pendingSnapshot == value, !fileUpdatesPaused else { return }
            if same {
                playback.clearPendingVersion(ownerID: id)
                apply(value)
            } else { playback.notePendingVersion(ownerID: id) }
        }
    }

    private func apply(_ value: MobileDocumentSnapshot) {
        snapshot = value; pendingSnapshot = nil
        guard hasDocument else { return }
        fileURL = value.url; title = value.url.lastPathComponent
        guard !source.utf8.elementsEqual(value.source.utf8) else { return }
        source = value.source; fileUpdateNeedsReviewReset = true; render()
    }

    func setFileUpdatesPaused(_ paused: Bool) {
        fileUpdatesPaused = paused
        if !paused, !playbackHolding, let value = pendingSnapshot { apply(value) }
    }

    func showLatest(readAloud: Bool = false) {
        cancelSpeechPreparation()
        playback.releaseVersionHold(ownerID: id)
        fileUpdatesPaused = false
        if let value = pendingSnapshot { apply(value) }
        if readAloud { prepareSpeechStartAfterRendering(mode: "beginning") }
    }

    @discardableResult
    func requestTaskChecked(_ id: Int, checked: Bool) -> Bool {
        guard canWrite, let snapshot, let output = rendered, output.taskSource.utf8.elementsEqual(source.utf8),
              let task = output.tasks.first(where: { $0.id == id }),
              task.checked != checked || output.responses.choices.contains(where: { $0.hasConflict && $0.tasks.contains(task) }) else { return false }
        let response: MarkdownResponseEdit?
        do { response = try choiceEdit(for: task, checked: checked) }
        catch { errorMessage = error.localizedDescription; return false }
        if checklistMode {
            if let response { saveResponse(response, history: .normal) }
            else { save(task: task, marker: checked ? 120 : 32, history: .normal) }
        }
        else {
            pendingConsent = Consent(leaseID: snapshot.leaseID, source: source, task: task, checked: checked, response: response)
            showChecklistConfirmation = true
        }
        return true
    }

    func cancelChecklistConfirmation() { showChecklistConfirmation = false; pendingConsent = nil }
    func confirmChecklistSaving() {
        guard let consent = pendingConsent else { return }
        cancelChecklistConfirmation()
        guard snapshot?.leaseID == consent.leaseID, source.utf8.elementsEqual(consent.source.utf8), !hasPendingFileUpdate else {
            errorMessage = ChecklistError.changed.localizedDescription; return
        }
        checklistMode = true
        if let response = consent.response { saveResponse(response, history: .normal, allowRendering: true) }
        else { save(task: consent.task, marker: consent.checked ? 120 : 32, history: .normal) }
    }
    func stopSavingCheckmarks() { checklistMode = false; cancelChecklistConfirmation() }
    func undoChecklist() {
        guard canUndoChecklist, let operation = undoStack.last else { return }
        switch operation {
        case let .marker(task, marker): save(task: task, marker: marker, history: .undo)
        case let .response(edit): saveResponse(edit, history: .undo)
        }
    }
    func redoChecklist() {
        guard canRedoChecklist, let operation = redoStack.last else { return }
        switch operation {
        case let .marker(task, marker): save(task: task, marker: marker, history: .redo)
        case let .response(edit): saveResponse(edit, history: .redo)
        }
    }

    private func save(task: MarkdownTask, marker: UInt8, history: History) {
        guard canWrite, checklistMode || history != .normal, let captured = snapshot else { return }
        let expected = source, revision = externalRevision
        checklistSaving = true; errorMessage = nil
        saveTask = Task { [weak self, access] in
            do {
                let updated = try await access.write(expected: captured, task: task, marker: marker)
                guard let self, snapshot?.leaseID == captured.leaseID else { return }
                checklistSaving = false
                guard revision == externalRevision, source.utf8.elementsEqual(expected.utf8), access.snapshot?.data == updated.data else {
                    undoStack.removeAll(); redoStack.removeAll()
                    errorMessage = ChecklistError.changed.localizedDescription; return
                }
                let inverse = Operation.marker(task: MarkdownTask(id: task.id, utf8Offset: task.utf8Offset, marker: marker, label: task.label), marker: task.marker)
                switch history {
                case .normal: undoStack.append(inverse); redoStack.removeAll()
                case .undo: undoStack.removeLast(); redoStack.append(inverse)
                case .redo: redoStack.removeLast(); undoStack.append(inverse)
                }
                trimChecklistHistory()
                apply(updated)
            } catch {
                guard let self, snapshot?.leaseID == captured.leaseID else { return }
                checklistSaving = false; errorMessage = error.localizedDescription
                undoStack.removeAll(); redoStack.removeAll()
                await refresh()
            }
        }
    }

    private func choiceEdit(for task: MarkdownTask, checked: Bool) throws -> MarkdownResponseEdit? {
        guard let group = rendered?.responses.choices.first(where: { $0.tasks.contains(where: { $0.id == task.id }) }) else { return nil }
        return try MarkdownResponses.choiceEdit(source: source, group: group, taskID: task.id, checked: checked)
    }

    private func trimChecklistHistory() {
        while undoStack.count + redoStack.count > 100 ||
              undoStack.reduce(0, { $0 + $1.byteCount }) + redoStack.reduce(0, { $0 + $1.byteCount }) > 16 * 1_024 * 1_024 {
            if !undoStack.isEmpty { undoStack.removeFirst() }
            else if !redoStack.isEmpty { redoStack.removeFirst() }
            else { break }
        }
    }

    @discardableResult
    private func saveResponse(_ edit: MarkdownResponseEdit, history: History, allowRendering: Bool = false, draft: ShortAnswerDraft? = nil) -> Bool {
        let ready = answerFileReady || (allowRendering && fileURL != nil && !isOpening && !fileSaving &&
            !showChecklistConfirmation && !hasPendingFileUpdate && !playbackHolding)
        guard ready, answerDraft == nil || answerDraft === draft,
              let captured = snapshot, edit.source.utf8.elementsEqual(source.utf8),
              captured.source.utf8.elementsEqual(source.utf8), !edit.splices.isEmpty else { return false }
        let inverse: MarkdownResponseEdit, replacement: Data
        do { inverse = try edit.inverse(); replacement = try edit.apply(to: captured.data) }
        catch { errorMessage = error.localizedDescription; return false }
        let revision = externalRevision
        checklistSaving = true; errorMessage = nil
        draft?.saving = true; draft?.error = nil
        saveTask = Task { [weak self, access] in
            do {
                let updated = try await access.replace(expected: captured, with: replacement)
                guard let self, snapshot?.leaseID == captured.leaseID else { draft?.saving = false; draft?.stale = true; return }
                checklistSaving = false
                guard revision == externalRevision, source.utf8.elementsEqual(edit.source.utf8), access.snapshot == updated else {
                    undoStack.removeAll(); redoStack.removeAll()
                    errorMessage = ChecklistError.changed.localizedDescription
                    draft?.saving = false; draft?.stale = true; draft?.error = errorMessage; return
                }
                switch history {
                case .normal: undoStack.append(.response(inverse)); redoStack.removeAll()
                case .undo: if !undoStack.isEmpty { undoStack.removeLast() }; redoStack.append(.response(inverse))
                case .redo: if !redoStack.isEmpty { redoStack.removeLast() }; undoStack.append(.response(inverse))
                }
                trimChecklistHistory()
                apply(updated)
                draft?.saving = false
                if let draft, answerDraft === draft { answerDraft = nil }
            } catch {
                draft?.saving = false; draft?.error = error.localizedDescription
                guard let self, snapshot?.leaseID == captured.leaseID else { draft?.stale = true; return }
                checklistSaving = false; errorMessage = error.localizedDescription
                undoStack.removeAll(); redoStack.removeAll()
                await refresh()
            }
        }
        return true
    }

    func render() {
        renderTask?.cancel()
        guard hasDocument else { return }
        isRendering = true
        let text = source, name = title, wide = wide, remote = loadRemoteImages, appearance = appearance
        let baseline = reviewedSource, units = reviewedUnits, mapTasks = fileURL != nil
        let generation = openGeneration, options = playback.preferences.options
        let previousProjection = fileURL != nil ? rendered?.discussionText : nil
        let previousDiscussions = fileURL != nil ? rendered?.discussions : nil
        renderTask = Task { [weak self] in
            do {
                let output = try await MarkdownRenderer.shared.render(text, title: name, wide: wide, baseline: baseline,
                    reviewedUnits: units, loadRemoteImages: remote, appearance: appearance, mapTasks: mapTasks,
                    prepareSpeech: true, speechOptions: options, previousDiscussionProjection: previousProjection, previousDiscussions: previousDiscussions)
                guard let self, !Task.isCancelled, generation == openGeneration, source.utf8.elementsEqual(text.utf8) else { return }
                #if MARGINED_BENCHMARK
                MobileViewingBenchmarkSession.current?.didRender(reader: self, output: output)
                #endif
                let sameReview = rendered?.changes.entries == output.changes.entries
                rendered = output; isRendering = false
                if fileUpdateNeedsReviewReset && !sameReview { currentChangeIndex = 0 }
                fileUpdateNeedsReviewReset = false
                if let projection = output.discussionText { discussions.acceptProjection(projection) }
                currentChangeIndex = output.changes.count == 0 ? 0 : min(currentChangeIndex, output.changes.count - 1)
            } catch {
                guard let self, !Task.isCancelled, generation == openGeneration else { return }
                errorMessage = error.localizedDescription; isRendering = false
            }
        }
    }

    func navigate(to id: String) {
        discussionPassageRequest = nil
        navigationTarget = id; navigationGeneration += 1
    }
    func find(backwards: Bool = false) { searchBackwards = backwards; searchGeneration += 1 }
    func changeZoom(by amount: Double) { zoom = min(2, max(0.6, zoom + amount)) }
    func selectChange(_ index: Int) { currentChangeIndex = max(0, min(index, changes.count - 1)) }
    func stepChange(backwards: Bool = false) {
        guard changes.count > 0 else { return }
        currentChangeIndex = (currentChangeIndex + (backwards ? -1 : 1) + changes.count) % changes.count
    }
    func showSelectedChange() { if let target = selectedChange?.targetID { navigate(to: target) } }
    func markAllReviewed() { reviewedSource = source; reviewedUnits = nil; currentChangeIndex = 0; render() }
    func markCurrentChangeReviewed() {
        guard !isRendering, let change = selectedChange, var baseline = rendered?.comparisonBaseline else { return }
        let offset = change.baselineOffset
        switch change.kind {
        case .added:
            guard offset <= baseline.count, let value = change.replacement else { return }; baseline.insert(value, at: offset)
        case .edited:
            guard baseline.indices.contains(offset), let value = change.replacement else { return }; baseline[offset] = value
        case .removed:
            guard baseline.indices.contains(offset) else { return }; baseline.remove(at: offset)
        }
        reviewedUnits = baseline; render()
    }

    func readConversation(thread: DiscussionThread, document: SpeechDocument, context: UUID) {
        guard context == documentGeneration, hasDocument, !isRendering,
              !fileSaving, !showChecklistConfirmation,
              let output = rendered, output.taskSource.utf8.elementsEqual(source.utf8),
              output.discussions?.threads.first(where: { $0.id == thread.id }) == thread,
              !document.segments.isEmpty, document.options == playback.preferences.options else { return }
        cancelSpeechPreparation()
        if playback.ownerID == id, playback.conversationID == nil, let prose = playback.session.document,
           prose.fingerprint == output.speech?.fingerprint,
           prose.segments.indices.contains(playback.session.currentIndex),
           playback.session.currentIndex < prose.segments.count - 1 || playback.session.offset < prose.segments[playback.session.currentIndex].text.utf16.count {
            suspendedProse = (documentGeneration, prose.fingerprint, prose.options,
                              playback.session.currentIndex, playback.session.offset)
        }
        // The existing owner checkpoints prose before replacing its immutable
        // content. A conversation never writes progress under the document URL.
        playback.play(document: document, title: title, url: nil, ownerID: id, conversationID: thread.id)
        if hasPendingFileUpdate { playback.notePendingVersion(ownerID: id) }
    }

    func speechOptionsChanged() { if !playbackHolding { render() } }
    func startSpeech(mode: String = "visible") {
        cancelSpeechPreparation()
        guard !isRendering, !checklistSaving, !showChecklistConfirmation,
              let document = rendered?.speech, rendered?.taskSource.utf8.elementsEqual(source.utf8) == true else { return }
        if document.options != playback.preferences.options {
            playback.stop()
            render()
            prepareSpeechStartAfterRendering(mode: mode)
            return
        }
        speechStartMode = mode; speechRequestedFingerprint = document.fingerprint
        speechRequestedOwnership = (playback.ownershipGeneration, playback.session.playbackIntentGeneration)
        let request = UUID(); speechStartRequest = request
        if mode == "beginning" { completeSpeechStart(requestID: request, elementID: nil, offset: 0) }
    }
    func completeSpeechStart(requestID: UUID, elementID: String?, offset: Int) {
        guard speechStartRequest == requestID else { return }
        speechStartRequest = nil
        let ownership = speechRequestedOwnership; speechRequestedOwnership = nil
        guard ownership?.owner == playback.ownershipGeneration, ownership?.intent == playback.session.playbackIntentGeneration else { return }
        guard !isRendering, !checklistSaving, !showChecklistConfirmation, rendered?.taskSource.utf8.elementsEqual(source.utf8) == true,
              let document = rendered?.speech, document.fingerprint == speechRequestedFingerprint else {
            errorMessage = String(localized: "Wait for the document to finish loading, then try Read Aloud again."); return
        }
        if speechStartMode == "beginning" {
            suspendedProse = nil
            playback.play(document: document, title: title, url: fileURL, ownerID: id)
        } else if let elementID, let position = document.position(elementID: elementID, sourceOffset: offset) {
            suspendedProse = nil
            playback.play(document: document, title: title, url: fileURL, from: position.index, offset: position.offset, ownerID: id)
        } else {
            errorMessage = String(localized: "Select text in the document to choose where reading starts.")
        }
        if hasPendingFileUpdate { playback.notePendingVersion(ownerID: id) }
    }
    func waitForSpeechPreparation() async { await speechPreparationTask?.value }
    func stopSpeech() {
        cancelSpeechPreparation()
        if playback.ownerID == id { playback.stop() }
    }

    func toggleSpeechPlayback() {
        cancelSpeechPreparation()
        if playback.ownerID == id, playback.session.status == .playing { playback.pause() }
        else if playback.ownerID == id, playback.session.status == .paused { playback.resume() }
        else if playback.ownerID == id, let conversationID = playback.conversationID {
            replayConversation(conversationID)
        } else { resumeSpeechPosition() }
    }

    func resumeSpeechPosition() {
        cancelSpeechPreparation()
        guard !isRendering, !checklistSaving, !showChecklistConfirmation, let document = rendered?.speech else { return }
        if document.options != playback.preferences.options { startSpeech(mode: "beginning"); return }
        let saved = playback.savedPosition(document: document, url: fileURL)
        var index = saved?.index ?? 0, offset = saved?.offset ?? 0
        if playback.ownerID == id, playback.conversationID != nil, let suspended = suspendedProse,
           suspended.context == documentGeneration, suspended.fingerprint == document.fingerprint,
           suspended.options == document.options {
            index = suspended.index; offset = suspended.offset
        }
        suspendedProse = nil
        playback.play(document: document, title: title, url: fileURL, from: index, offset: offset, ownerID: id)
        if hasPendingFileUpdate { playback.notePendingVersion(ownerID: id) }
    }
    private func cancelSpeechPreparation() {
        speechPreparationTask?.cancel(); speechPreparationTask = nil
        speechPreparationIntent = UUID()
        speechStartRequest = nil; speechRequestedFingerprint = nil; speechRequestedOwnership = nil
    }

    private func prepareSpeechStartAfterRendering(mode: String) {
        let generation = openGeneration, text = source, intent = speechPreparationIntent
        let ownership = playback.ownershipGeneration
        speechPreparationTask = Task { [weak self] in
            guard let self else { return }
            defer { if intent == speechPreparationIntent { speechPreparationTask = nil } }
            await waitForRendering()
            guard !Task.isCancelled, intent == speechPreparationIntent, generation == openGeneration,
                  ownership == playback.ownershipGeneration, source.utf8.elementsEqual(text.utf8) else { return }
            speechPreparationTask = nil
            startSpeech(mode: mode)
        }
    }

    private func replayConversation(_ threadID: String) {
        guard !isRendering, !fileSaving, !showChecklistConfirmation,
              let output = rendered, output.taskSource.utf8.elementsEqual(source.utf8) else { return }
        guard let thread = output.discussions?.threads.first(where: { $0.id == threadID }) else {
            errorMessage = String(localized: "This conversation is no longer available."); return
        }
        let generation = openGeneration, text = source, intent = speechPreparationIntent
        let ownership = playback.ownershipGeneration, options = playback.preferences.options
        let locale = Locale.current, timeZone = TimeZone.current, remoteImages = loadRemoteImages
        speechPreparationTask = Task { [weak self] in
            guard let self else { return }
            defer { if intent == speechPreparationIntent { speechPreparationTask = nil } }
            do {
                let speech = try await MarkdownRenderer.shared.conversationSpeech(thread, loadRemoteImages: remoteImages,
                    speechOptions: options, locale: locale, timeZone: timeZone)
                guard !Task.isCancelled, intent == speechPreparationIntent, generation == openGeneration,
                      playback.ownerID == id, playback.conversationID == threadID,
                      playback.ownershipGeneration == ownership, source.utf8.elementsEqual(text.utf8),
                      options == playback.preferences.options, remoteImages == loadRemoteImages, locale.identifier == Locale.current.identifier,
                      timeZone.identifier == TimeZone.current.identifier,
                      rendered?.discussions?.threads.first(where: { $0.id == threadID }) == thread else { return }
                speechPreparationTask = nil
                readConversation(thread: thread, document: speech, context: generation)
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled, intent == speechPreparationIntent, generation == openGeneration else { return }
                errorMessage = error.localizedDescription
            }
        }
    }

    func waitForRendering() async { await renderTask?.value }
    func makeDiscussionCopyReader() -> MobileReaderState { MobileReaderState(playback: playback, defaults: defaults) }
    func performDiscussionFileSave(_ action: @escaping @MainActor () async -> Void) {
        // Set the gate before creating the task: close/open must wait for an accepted save.
        discussionCopySaving = true
        saveTask = Task { [self] in
            await action()
            discussionCopySaving = false
        }
    }
    func waitForSaving() async { await saveTask?.value }
    private struct Consent { let leaseID: UUID; let source: String; let task: MarkdownTask; let checked: Bool; let response: MarkdownResponseEdit? }
    private enum Operation {
        case marker(task: MarkdownTask, marker: UInt8)
        case response(MarkdownResponseEdit)
        var isResponse: Bool { if case .response = self { true } else { false } }
        var byteCount: Int {
            switch self {
            case let .marker(task, _): task.label.utf8.count + 32
            case let .response(edit): edit.source.utf8.count + edit.splices.reduce(0) { $0 + $1.replacement.utf8.count + 32 }
            }
        }
    }
    private enum History: Equatable { case normal, undo, redo }
}
