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
    private var openGeneration = UUID()
    @ObservationIgnored private var renderTask: Task<Void, Never>?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    private var pendingConsent: Consent?
    private var undoStack: [Operation] = []
    private var redoStack: [Operation] = []

    init(access: MobileDocumentAccess = MobileDocumentAccess(), playback: MobilePlaybackOwner = MobilePlaybackOwner(),
         defaults: UserDefaults = ReaderPreferences.defaults) {
        self.access = access; self.playback = playback; self.defaults = defaults
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
        fileURL != nil && !isOpening && !isRendering && !checklistSaving &&
        !showChecklistConfirmation && !hasPendingFileUpdate && !playbackHolding
    }

    func open(url: URL) async {
        let inFlightSave = saveTask
        let generation = UUID(); openGeneration = generation
        resetForOpen(); isOpening = true
        await inFlightSave?.value
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
            let request = try PreviewRequest(url: url)
            let inFlightSave = saveTask
            let generation = UUID(); openGeneration = generation
            resetForOpen(); isOpening = true
            await inFlightSave?.value
            guard generation == openGeneration else { return }
            await access.close()
            guard generation == openGeneration else { return }
            source = request.text; title = request.title; hasDocument = true; isOpening = false
            render()
        } catch { errorMessage = error.localizedDescription }
    }

    func close() async {
        let inFlightSave = saveTask
        let generation = UUID(); openGeneration = generation
        resetForOpen(); hasDocument = false
        await inFlightSave?.value
        guard generation == openGeneration else { return }
        await access.close()
    }

    private func resetForOpen() {
        playback.documentWillChange(ownerID: id)
        renderTask?.cancel(); isRendering = false
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
        currentChangeIndex = 0; imageReloadGeneration += 1
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
        guard value.data != current.data || pendingSnapshot != nil else { return }
        externalRevision += 1; undoStack.removeAll(); redoStack.removeAll()
        cancelChecklistConfirmation()
        errorMessage = nil
        if fileUpdatesPaused || playbackHolding {
            pendingSnapshot = value.data == current.data ? nil : value
            if playback.ownerID == id {
                if pendingSnapshot != nil { playback.notePendingVersion(ownerID: id) }
                else { playback.clearPendingVersion(ownerID: id) }
            }
        } else { apply(value) }
    }

    private func apply(_ value: MobileDocumentSnapshot) {
        snapshot = value; pendingSnapshot = nil
        fileURL = value.url; title = value.url.lastPathComponent
        guard source != value.source else { return }
        source = value.source; currentChangeIndex = 0; render()
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
        guard canWrite, let snapshot, rendered?.taskSource == source,
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
        guard snapshot?.leaseID == consent.leaseID, source == consent.source, !hasPendingFileUpdate else {
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
                let updated = try await access.write(leaseID: captured.leaseID, task: task, marker: marker, expectedSource: expected)
                guard let self, snapshot?.leaseID == captured.leaseID else { return }
                checklistSaving = false
                guard revision == externalRevision, source == expected, access.snapshot?.data == updated.data else {
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
        renderTask = Task { [weak self] in
            do {
                let output = try await MarkdownRenderer.shared.render(text, title: name, wide: wide, baseline: baseline,
                    reviewedUnits: units, loadRemoteImages: remote, appearance: appearance, mapTasks: mapTasks,
                    prepareSpeech: true, speechOptions: options)
                guard let self, !Task.isCancelled, generation == openGeneration, source == text else { return }
                rendered = output; isRendering = false
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
              let document = rendered?.speech, rendered?.taskSource == source else { return }
        if document.options != playback.preferences.options {
            playback.stop()
            render()
            let generation = openGeneration, text = source
            Task { [weak self] in
                guard let self else { return }
                await waitForRendering()
                guard generation == openGeneration, source == text else { return }
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
        guard !isRendering, !checklistSaving, !showChecklistConfirmation, rendered?.taskSource == source,
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
