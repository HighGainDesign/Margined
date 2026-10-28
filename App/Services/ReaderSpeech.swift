import Foundation
import Observation

/// The document owns this controller, while the session owns immutable speech.
/// Receiving new source remains independent from applying it to the page.
@MainActor @Observable
final class ReaderSpeech {
    enum StartMode: String { case beginning, visible, selection }
    struct StartRequest: Equatable { let id: UUID; let mode: StartMode; let fingerprint: String; let ownership: UUID }
    private(set) var startRequest: StartRequest?
    let session: SpeechSession
    let preferences: SpeechPreferences
    private(set) var conversationID: String?
    private(set) var isHolding = false
    var showPlayer = false { didSet { if showPlayer && !oldValue { session.refreshVoices() } } }
    private(set) var message: String?
    @ObservationIgnored private weak var reader: ReaderState?
    @ObservationIgnored private let progress: SpeechProgressStore
    @ObservationIgnored private var playbackURL: URL?
    @ObservationIgnored private var playbackContext: UUID?
    @ObservationIgnored private var suspendedProse: (context: UUID, fingerprint: String, options: SpeechOptions, index: Int, offset: Int)?
    @ObservationIgnored private var lastCheckpoint = Date.distantPast
    private var latestTask: Task<Void, Never>?
    @ObservationIgnored private var latestTaskID: UUID?
    var isPreparing: Bool { latestTask != nil || startRequest != nil }

    init(reader: ReaderState, session: SpeechSession = SpeechSession(),
         preferences: SpeechPreferences = .shared, progress: SpeechProgressStore = SpeechProgressStore()) {
        self.reader = reader; self.session = session; self.preferences = preferences; self.progress = progress
        session.onProgress = { [weak self] in self?.didProgress() }
        session.onStop = { [weak self] in
            guard let self else { return }
            checkpoint(force: true)
            self.reader?.announcements.suppressRoutine = false
            if self.reader?.hasPendingFileUpdate != true { isHolding = false }
        }
    }

    var bookmark: SpeechBookmark? {
        _ = preferences.historyRevision
        guard let reader, let url = reader.fileURL, let document = reader.rendered?.speech else { return nil }
        return progress.resume(url: url, document: document)
    }

    func start(at index: Int = 0, offset: Int = 0) {
        latestTask?.cancel(); latestTask = nil; latestTaskID = nil; startRequest = nil
        showPlayer = true; message = nil
        if reader?.showChecklistConfirmation == true {
            message = String(localized: "Finish the checklist confirmation before starting Read Aloud."); return
        }
        guard let reader, !reader.isRendering, !reader.checklistSaving,
              let output = reader.rendered, output.taskSource == reader.source, let document = output.speech else {
            message = String(localized: "Wait for the document to finish loading, then try Read Aloud again."); return
        }
        if prepareOptionsIfNeeded({ $0.start(at: index, offset: offset) }) { return }
        if session.isActive { session.stop() }
        conversationID = nil; suspendedProse = nil
        playbackContext = reader.currentDiscussionVersion.context
        playbackURL = reader.isStreamingPreview ? nil : reader.fileURL
        play(document, from: index, offset: offset)
    }
    fileprivate func playConversation(_ document: SpeechDocument, threadID: String) {
        guard let reader else { return }
        let context = reader.currentDiscussionVersion.context
        if conversationID == nil, playbackContext == context, let prose = session.document,
           prose.fingerprint == reader.rendered?.speech?.fingerprint,
           prose.segments.indices.contains(session.currentIndex),
           session.currentIndex < prose.segments.count - 1 || session.offset < prose.segments[session.currentIndex].text.utf16.count {
            suspendedProse = (context, prose.fingerprint, prose.options, session.currentIndex, session.offset)
        }
        latestTask?.cancel(); latestTask = nil; latestTaskID = nil; startRequest = nil
        showPlayer = true; message = nil
        if session.isActive { session.stop() }
        else { checkpoint(force: true) }
        // Preserve prose progress before switching; conversations have no file
        // bookmark and must never replace the document's saved position.
        playbackURL = nil; playbackContext = context; conversationID = threadID
        play(document)
    }
    private func play(_ document: SpeechDocument, from index: Int = 0, offset: Int = 0) {
        isHolding = true
        session.useAssistiveTechnologySettings = preferences.useAssistiveTechnologySettings
        session.followReading = preferences.followReading
        session.setRate(preferences.rate)
        session.setVoice(preferences.voice(for: document.language))
        session.play(document, from: index, offset: offset)
    }
    func requestStart(_ mode: StartMode) {
        latestTask?.cancel(); latestTask = nil
        if mode == .beginning { start(); return }
        showPlayer = true; message = nil
        guard let reader, !reader.isRendering, let document = reader.rendered?.speech else {
            message = String(localized: "Wait for the document to finish loading, then try Read Aloud again."); return
        }
        if prepareOptionsIfNeeded({ $0.requestStart(mode) }) { return }
        startRequest = StartRequest(id: UUID(), mode: mode, fingerprint: document.fingerprint, ownership: session.playbackIntentGeneration)
    }
    func completeStart(_ request: StartRequest, elementID: String?, offset: Int) {
        guard startRequest?.id == request.id else { return }
        startRequest = nil
        guard request.ownership == session.playbackIntentGeneration, let reader,
              let document = reader.rendered?.speech, document.fingerprint == request.fingerprint else { return }
        if document.options != preferences.options { requestStart(request.mode); return }
        guard let elementID else {
            message = String(localized: "Select text in the document to choose where reading starts."); return
        }
        if request.mode == .visible, let index = document.segments.firstIndex(where: { $0.elementID == elementID }) {
            start(at: document.section(at: index)?.firstSegment ?? index)
        } else if let position = document.position(elementID: elementID, sourceOffset: offset) {
            start(at: position.index, offset: position.offset)
        } else { message = String(localized: "That selection is no longer available. Select the text again.") }
    }

    func resumeSaved() {
        if prepareOptionsIfNeeded({ $0.resumeSaved() }) { return }
        if conversationID != nil, let reader, let saved = suspendedProse,
           saved.context == reader.currentDiscussionVersion.context,
           saved.fingerprint == reader.rendered?.speech?.fingerprint,
           saved.options == reader.rendered?.speech?.options {
            start(at: saved.index, offset: saved.offset)
        } else if let bookmark { start(at: bookmark.index, offset: bookmark.offset) }
        else { start() }
    }
    func togglePlayback() {
        latestTask?.cancel(); latestTask = nil; latestTaskID = nil; startRequest = nil
        switch session.status {
        case .playing: session.pause()
        case .paused: session.resume()
        default:
            if let conversationID { replayConversation(conversationID) }
            else { resumeSaved() }
        }
    }
    private func replayConversation(_ id: String) {
        guard let reader, !reader.isRendering, !reader.fileSaving, !reader.showChecklistConfirmation,
              let output = reader.rendered, output.taskSource.utf8.elementsEqual(reader.source.utf8) else { return }
        guard let thread = output.discussions?.threads.first(where: { $0.id == id }) else {
            message = String(localized: "This conversation is no longer available."); return
        }
        let context = reader.currentDiscussionVersion.context, source = reader.source
        let options = preferences.options, language = reader.documentLanguageOverride, remoteImages = reader.loadRemoteImages
        let ownership = session.playbackIntentGeneration, locale = Locale.current, timeZone = TimeZone.current
        let taskID = UUID(); latestTaskID = taskID
        latestTask = Task { [weak self, weak reader] in
            guard let self, let reader else { return }
            defer {
                if latestTaskID == taskID { latestTask = nil; latestTaskID = nil }
            }
            do {
                let speech = try await MarkdownRenderer.shared.conversationSpeech(thread, loadRemoteImages: remoteImages,
                    documentLanguage: language, speechOptions: options, locale: locale, timeZone: timeZone)
                guard !Task.isCancelled, session.playbackIntentGeneration == ownership,
                      conversationID == id, context == reader.currentDiscussionVersion.context,
                      reader.source.utf8.elementsEqual(source.utf8), options == preferences.options,
                      language == reader.documentLanguageOverride, remoteImages == reader.loadRemoteImages, locale.identifier == Locale.current.identifier,
                      timeZone.identifier == TimeZone.current.identifier,
                      reader.rendered?.discussions?.threads.first(where: { $0.id == id }) == thread else { return }
                latestTask = nil
                reader.readConversation(thread: thread, document: speech, context: context)
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled, context == reader.currentDiscussionVersion.context else { return }
                message = error.localizedDescription
            }
        }
    }

    func waitForPreparation() async { await latestTask?.value }

    func stop() { latestTask?.cancel(); latestTask = nil; latestTaskID = nil; startRequest = nil; session.stop() }
    func close(discardHold: Bool = false) {
        stop(); showPlayer = false
        // Closing playback controls must not hide a pending-version decision.
        // Only a document closing/switching may discard its display hold.
        if discardHold {
            isHolding = false; conversationID = nil; playbackContext = nil; suspendedProse = nil
        }
    }
    func showLatest(read: Bool = false) {
        let oldSection = session.document?.section(at: session.currentIndex)?.id
        stop(); isHolding = false; conversationID = nil; playbackContext = nil; suspendedProse = nil
        guard let reader else { return }
        reader.applyPendingPlaybackVersion()
        guard read else { return }
        let ownership = session.playbackIntentGeneration
        let taskID = UUID(); latestTaskID = taskID
        latestTask = Task { [weak self, weak reader] in
            guard let self, let reader else { return }
            defer {
                if latestTaskID == taskID { latestTask = nil; latestTaskID = nil }
            }
            while reader.isRendering {
                do { try await Task.sleep(for: .milliseconds(10)) } catch { return }
            }
            guard !Task.isCancelled, ownership == session.playbackIntentGeneration else { return }
            latestTask = nil
            let index = reader.rendered?.speech?.sections.first(where: { $0.id == oldSection })?.firstSegment ?? 0
            start(at: index)
        }
    }
    func setRate(_ rate: Double) { preferences.rate = rate; session.setRate(preferences.rate) }
    func setVoice(_ id: String?) {
        preferences.setVoice(id, for: session.document?.language ?? reader?.rendered?.documentLanguage)
        session.setVoice(id)
    }
    func setFollowReading(_ follow: Bool) { preferences.followReading = follow; session.followReading = follow }
    func clearHistory() { progress.clear(); preferences.historyRevision += 1 }

    /// Content choices affect preparation, never an utterance already in flight.
    /// Queue the original intent after a fresh render; Stop/close cancels it.
    private func prepareOptionsIfNeeded(_ resume: @escaping @MainActor (ReaderSpeech) -> Void) -> Bool {
        guard let reader, let document = reader.rendered?.speech, document.options != preferences.options else { return false }
        latestTask?.cancel(); latestTask = nil; latestTaskID = nil; startRequest = nil
        if session.isActive { session.stop() }
        let source = reader.source, ownership = session.playbackIntentGeneration
        reader.render()
        let taskID = UUID(); latestTaskID = taskID
        latestTask = Task { [weak self, weak reader] in
            guard let self, let reader else { return }
            defer {
                if latestTaskID == taskID { latestTask = nil; latestTaskID = nil }
            }
            while reader.isRendering {
                do { try await Task.sleep(for: .milliseconds(10)) } catch { return }
            }
            guard !Task.isCancelled, ownership == session.playbackIntentGeneration,
                  reader.source == source, reader.rendered?.speech?.options == preferences.options else { return }
            latestTask = nil
            resume(self)
        }
        return true
    }

    private func didProgress() {
        reader?.announcements.suppressRoutine = session.isActive
        if session.isActive { checkpoint(force: session.status == .paused) }
    }
    private func checkpoint(force: Bool) {
        guard force || Date().timeIntervalSince(lastCheckpoint) >= 2,
              let playbackURL, let document = session.document else { return }
        progress.save(url: playbackURL, document: document, index: session.currentIndex, offset: session.offset)
        lastCheckpoint = Date()
    }
}

extension ReaderState {
    func readConversation(thread: DiscussionThread, document: SpeechDocument, context: UUID) {
        guard context == currentDiscussionVersion.context, !isRendering,
              !checklistSaving, !discussionSaving, !showChecklistConfirmation,
              let output = rendered, output.taskSource.utf8.elementsEqual(source.utf8),
              output.discussions?.threads.first(where: { $0.id == thread.id }) == thread,
              !document.segments.isEmpty, document.options == speech.preferences.options else { return }
        speech.playConversation(document, threadID: thread.id)
    }
}
