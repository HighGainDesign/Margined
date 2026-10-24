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
    enum Inspector: Equatable { case changes, discussions }
    var inspector: Inspector?
    var discussionRoute: DiscussionSession.DraftKey?
    var discussionDecision: MobileDiscussionDecision?
    var discussionCopyRequest: MobileDiscussionCopyRequest?
    var discussionImportReview: MobileDiscussionImportReview?
    var discussionPassagePicker: MobileDiscussionPassagePicker?
    var discussionSelectionGeneration = 0
    var discussionSelectionRequest: MobileDiscussionSelectionRequest?
    var discussionMargin: DiscussionMarginSnapshot?
    var discussionUsesMargin = false
    var currentDiscussionVersion: MobileDiscussionVersion {
        .init(context: openGeneration, snapshot: snapshot?.sourceSnapshot)
    }
    private(set) var discussionSaving = false
    var discussionError: String?
    private(set) var discussionCopyOffered = false
    var fileSaving: Bool { checklistSaving || discussionSaving }
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
        !isOpening && !isRendering && !fileSaving && !showChecklistConfirmation && !hasPendingFileUpdate
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
                discussionSaving = false; apply(saved)
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
    private var speechRequestedFingerprint: String?
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
    var canUndoChecklist: Bool { canWrite && !undoStack.isEmpty }
    var canRedoChecklist: Bool { canWrite && !redoStack.isEmpty }
    var canWrite: Bool {
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
        playback.documentWillChange(ownerID: id)
        renderTask?.cancel(); classifyUpdateTask?.cancel(); isRendering = false
        discardDiscussionImport()
        inspector = nil; discussionRoute = nil; discussionSelectionRequest = nil; discussionMargin = nil
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
    private func classifyHeldUpdate(_ value: MobileDocumentSnapshot, displayed: MobileDocumentSnapshot) {
        classifyUpdateTask?.cancel()
        let generation = openGeneration
        classifyUpdateTask = Task { [weak self] in
            let same = (try? await MarkdownRenderer.shared.hasSameReadingContent(displayed.source, value.source)) == true
            guard let self, !Task.isCancelled, generation == openGeneration,
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
        playback.releaseVersionHold(ownerID: id)
        fileUpdatesPaused = false
        if let value = pendingSnapshot { apply(value) }
        if readAloud {
            let generation = openGeneration
            Task { [weak self] in
                guard let self else { return }
                await waitForRendering()
                guard generation == openGeneration else { return }
                startSpeech(mode: "beginning")
            }
        }
    }

    @discardableResult
    func requestTaskChecked(_ id: Int, checked: Bool) -> Bool {
        guard canWrite, let snapshot, rendered?.taskSource.utf8.elementsEqual(source.utf8) == true,
              let task = rendered?.tasks.first(where: { $0.id == id }), task.checked != checked else { return false }
        if checklistMode { save(task: task, marker: checked ? 120 : 32, history: .normal) }
        else {
            pendingConsent = Consent(leaseID: snapshot.leaseID, source: source, task: task, checked: checked)
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
        save(task: consent.task, marker: consent.checked ? 120 : 32, history: .normal)
    }
    func stopSavingCheckmarks() { checklistMode = false; cancelChecklistConfirmation() }
    func undoChecklist() { if canUndoChecklist, let operation = undoStack.last { save(task: operation.task, marker: operation.marker, history: .undo) } }
    func redoChecklist() { if canRedoChecklist, let operation = redoStack.last { save(task: operation.task, marker: operation.marker, history: .redo) } }

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
                let inverse = Operation(task: MarkdownTask(id: task.id, utf8Offset: task.utf8Offset, marker: marker, label: task.label), marker: task.marker)
                switch history {
                case .normal: undoStack.append(inverse); redoStack.removeAll()
                case .undo: undoStack.removeLast(); redoStack.append(inverse)
                case .redo: redoStack.removeLast(); undoStack.append(inverse)
                }
                if undoStack.count > 100 { undoStack.removeFirst() }
                apply(updated)
            } catch {
                guard let self, snapshot?.leaseID == captured.leaseID else { return }
                checklistSaving = false; errorMessage = error.localizedDescription
                undoStack.removeAll(); redoStack.removeAll()
                await refresh()
            }
        }
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

    func navigate(to id: String) { navigationTarget = id; navigationGeneration += 1 }
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

    func speechOptionsChanged() { if !playbackHolding { render() } }
    func startSpeech(mode: String = "visible") {
        guard !isRendering, !checklistSaving, !showChecklistConfirmation,
              let document = rendered?.speech, rendered?.taskSource.utf8.elementsEqual(source.utf8) == true else { return }
        if document.options != playback.preferences.options {
            playback.stop()
            render()
            let generation = openGeneration, text = source
            Task { [weak self] in
                guard let self else { return }
                await waitForRendering()
                guard generation == openGeneration, source.utf8.elementsEqual(text.utf8) else { return }
                startSpeech(mode: mode)
            }
            return
        }
        speechStartMode = mode; speechRequestedFingerprint = document.fingerprint
        let request = UUID(); speechStartRequest = request
        if mode == "beginning" { completeSpeechStart(requestID: request, elementID: nil, offset: 0) }
    }
    func completeSpeechStart(requestID: UUID, elementID: String?, offset: Int) {
        guard speechStartRequest == requestID else { return }
        speechStartRequest = nil
        guard !isRendering, !checklistSaving, !showChecklistConfirmation, rendered?.taskSource.utf8.elementsEqual(source.utf8) == true,
              let document = rendered?.speech, document.fingerprint == speechRequestedFingerprint else {
            errorMessage = String(localized: "Wait for the document to finish loading, then try Read Aloud again."); return
        }
        if speechStartMode == "beginning" {
            playback.play(document: document, title: title, url: fileURL, ownerID: id)
        } else if let elementID, let position = document.position(elementID: elementID, sourceOffset: offset) {
            playback.play(document: document, title: title, url: fileURL, from: position.index, offset: position.offset, ownerID: id)
        } else {
            errorMessage = String(localized: "Select text in the document to choose where reading starts.")
        }
        if hasPendingFileUpdate { playback.notePendingVersion(ownerID: id) }
    }
    func resumeSpeechPosition() {
        guard !isRendering, !checklistSaving, !showChecklistConfirmation, let document = rendered?.speech else { return }
        if document.options != playback.preferences.options { startSpeech(mode: "beginning"); return }
        let saved = playback.savedPosition(document: document, url: fileURL)
        playback.play(document: document, title: title, url: fileURL, from: saved?.index ?? 0, offset: saved?.offset ?? 0, ownerID: id)
        if hasPendingFileUpdate { playback.notePendingVersion(ownerID: id) }
    }
    func waitForRendering() async { await renderTask?.value }
    func waitForSaving() async { await saveTask?.value }
    private struct Consent { let leaseID: UUID; let source: String; let task: MarkdownTask; let checked: Bool }
    private struct Operation { let task: MarkdownTask; let marker: UInt8 }
    private enum History: Equatable { case normal, undo, redo }
}
