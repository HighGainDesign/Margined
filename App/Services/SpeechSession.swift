import Foundation
import Observation

@MainActor
final class SpeechCoordinator {
    static let shared = SpeechCoordinator()
    private weak var owner: SpeechSession?
    private(set) var intentGeneration = UUID()
    func claim(_ session: SpeechSession) {
        if let owner, owner !== session { owner.stop() }
        owner = session; intentGeneration = UUID()
    }
    func noteIntent(_ session: SpeechSession) { if owner === session { intentGeneration = UUID() } }
    func release(_ session: SpeechSession) { if owner === session { owner = nil } }
}

@MainActor @Observable
final class SpeechSession {
    enum Status: Equatable { case idle, playing, paused, finished, failed }
    private(set) var status = Status.idle
    private(set) var document: SpeechDocument?
    private(set) var currentIndex = 0
    private(set) var offset = 0
    private(set) var rate = 1.0
    private(set) var selectedVoiceID: String?
    private(set) var resolvedVoice: SpeechVoice?
    private(set) var availableVoices: [SpeechVoice] = []
    private(set) var notice: String?
    var followReading = true
    @ObservationIgnored var onStop: (() -> Void)?
    @ObservationIgnored var onProgress: (() -> Void)?
    @ObservationIgnored private let driver: any SpeechDriver
    @ObservationIgnored private let voices: @MainActor () -> [SpeechVoice]
    @ObservationIgnored private let coordinator: SpeechCoordinator
    @ObservationIgnored private var token: UUID?
    @ObservationIgnored private var spokenOffset = 0
    @ObservationIgnored private var needsRestart = false

    init(driver: any SpeechDriver = SystemSpeechDriver(), voices: @escaping @MainActor () -> [SpeechVoice] = SystemSpeechDriver.availableVoices,
         coordinator: SpeechCoordinator = .shared) {
        self.driver = driver; self.voices = voices; self.coordinator = coordinator
        driver.eventHandler = { [weak self] event in self?.receive(event) }
    }

    var playbackIntentGeneration: UUID { coordinator.intentGeneration }

    var currentSegment: SpeechSegment? {
        guard let document, document.segments.indices.contains(currentIndex) else { return nil }
        return document.segments[currentIndex]
    }
    var isActive: Bool { status == .playing || status == .paused }

    var useAssistiveTechnologySettings: Bool {
        get { driver.useAssistiveTechnologySettings }
        set {
            guard driver.useAssistiveTechnologySettings != newValue else { return }
            driver.useAssistiveTechnologySettings = newValue; reconfigure()
        }
    }

    func play(_ document: SpeechDocument, from index: Int = 0, offset: Int = 0) {
        invalidate()
        self.document = document
        currentIndex = max(0, min(index, document.segments.count - 1))
        self.offset = max(0, offset); notice = nil
        guard !document.segments.isEmpty else {
            status = .idle; notice = String(localized: "There is no readable text in this document."); coordinator.release(self); onStop?(); return
        }
        resolveVoice()
        guard resolvedVoice != nil else {
            status = .failed
            #if os(iOS)
            notice = String(localized: "No system voice is available. Add a voice in Settings.")
            #else
            notice = String(localized: "No system voice is available. Add a voice in System Settings.")
            #endif
            onStop?(); return
        }
        coordinator.claim(self)
        enqueue()
    }

    func pause() {
        guard status == .playing else { return }
        coordinator.noteIntent(self)
        if !driver.pause() {
            // The synthesizer may still be starting. Cancel its queue so a
            // fast Pause cannot turn into speech later without another Play.
            invalidate(); needsRestart = true
        }
        status = .paused; onProgress?()
    }
    func resume() {
        guard status == .paused else { return }
        coordinator.claim(self)
        if needsRestart { enqueue() }
        else if driver.resume() { status = .playing }
        else { needsRestart = true; enqueue() }
    }
    func stop() {
        coordinator.noteIntent(self)
        invalidate(); status = .idle; coordinator.release(self); onProgress?(); onStop?()
    }
    func setRate(_ value: Double) {
        let value = value.isFinite ? (min(2, max(0.5, value)) * 100).rounded() / 100 : 1
        guard rate != value else { return }
        rate = value; reconfigure()
    }
    func setVoice(_ id: String?) {
        guard selectedVoiceID != id else { return }
        selectedVoiceID = id
        if document != nil { resolveVoice() }
        reconfigure()
    }
    func nextSection() {
        guard isActive, let document else { return }
        if let next = document.sections.first(where: { $0.firstSegment > currentIndex }) { seek(next.firstSegment) }
        else { finish() }
    }
    func previousSection() {
        guard isActive else { return }
        guard let document, !document.sections.isEmpty else { seek(0); return }
        let section = document.sections.lastIndex(where: { $0.firstSegment <= currentIndex }) ?? 0
        seek(document.sections[max(0, section - 1)].firstSegment)
    }
    func seek(_ index: Int, offset: Int = 0) {
        guard isActive, let document, document.segments.indices.contains(index) else { return }
        let wasPaused = status == .paused
        coordinator.noteIntent(self)
        invalidate(); currentIndex = index; self.offset = max(0, offset)
        if wasPaused { status = .paused; needsRestart = true }
        else { coordinator.claim(self); enqueue() }
        onProgress?()
    }

    func refreshVoices() {
        let previous = resolvedVoice?.id
        resolveVoice()
        guard isActive else { return }
        if resolvedVoice == nil {
            invalidate(); status = .failed; coordinator.release(self)
            #if os(iOS)
            notice = String(localized: "No system voice is available. Add a voice in Settings.")
            #else
            notice = String(localized: "No system voice is available. Add a voice in System Settings.")
            #endif
            onStop?()
        } else if previous != resolvedVoice?.id { reconfigure() }
    }

    private func resolveVoice() {
        let available = voices()
        availableVoices = available
        if let selectedVoiceID, let chosen = available.first(where: { $0.id == selectedVoiceID }) {
            resolvedVoice = chosen; notice = nil; return
        }
        let language = document?.language?.lowercased()
        let family = language?.split(separator: "-").first.map(String.init)
        let matching = available.filter {
            guard let family else { return true }
            return $0.language.lowercased().split(separator: "-").first.map(String.init) == family
        }.sorted { left, right in
            let leftExact = left.language.lowercased() == language, rightExact = right.language.lowercased() == language
            if leftExact != rightExact { return leftExact }
            if left.quality != right.quality { return left.quality > right.quality }
            return left.id < right.id
        }
        resolvedVoice = language == nil ? available.first : (matching.first ?? available.first)
        if selectedVoiceID != nil { notice = String(localized: "The selected voice is unavailable. Using an available system voice.") }
        else if matching.isEmpty && language != nil { notice = String(localized: "No voice matches this language. Choose another voice or add one in System Settings.") }
    }

    private func reconfigure() {
        guard isActive else { return }
        let paused = status == .paused
        invalidate()
        if paused { needsRestart = true }
        else { enqueue() }
    }
    private func invalidate() { token = nil; driver.stop(); needsRestart = false }
    private func enqueue() {
        guard let segment = currentSegment else { finish(); return }
        let string = segment.text as NSString
        let proposed = min(max(0, offset), string.length)
        offset = proposed < string.length ? string.rangeOfComposedCharacterSequence(at: proposed).location : proposed
        if offset == string.length {
            if let document, currentIndex + 1 < document.segments.count { currentIndex += 1; offset = 0; enqueue() }
            else { finish() }
            return
        }
        spokenOffset = offset
        let next = UUID(); token = next; status = .playing; needsRestart = false
        driver.speak(string.substring(from: offset), voice: resolvedVoice, rate: rate, token: next)
        onProgress?()
    }
    private func finish() {
        if let document, !document.segments.isEmpty {
            currentIndex = document.segments.count - 1; offset = document.segments[currentIndex].text.utf16.count
        }
        invalidate(); status = .finished; coordinator.release(self); onProgress?(); onStop?()
    }
    private func receive(_ event: SpeechDriverEvent) {
        switch event {
        case .started(let id): guard id == token else { return }
        case .range(let id, let range):
            guard id == token, isActive, let segment = currentSegment else { return }
            offset = min(segment.text.utf16.count, spokenOffset + max(0, range.location)); onProgress?()
        case .finished(let id):
            guard id == token, status == .playing, let document else { return }
            if currentIndex + 1 < document.segments.count { currentIndex += 1; offset = 0; enqueue() }
            else { finish() }
        case .cancelled(let id):
            guard id == token, isActive else { return }
            token = nil; status = .paused; needsRestart = true; onProgress?()
        case .voicesChanged(let id):
            guard id == token else { return }
            refreshVoices()
        case .interrupted(let id, let message):
            guard id == token, isActive else { return }
            invalidate(); status = .paused; needsRestart = true; notice = message; onProgress?()
        case .failed(let id, let message):
            guard id == token else { return }
            invalidate(); status = .failed; notice = message; coordinator.release(self); onStop?()
        }
    }
}
