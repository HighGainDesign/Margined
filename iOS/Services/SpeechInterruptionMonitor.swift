import Foundation
@preconcurrency import AVFAudio

/// Match the shared driver's Mac monitor API while using iOS audio-session
/// notifications. An ended interruption never resumes speech automatically.
@MainActor
final class SpeechInterruptionMonitor {
    private let interrupted: (String) -> Void
    private let notificationCenter: NotificationCenter
    private var observers: [NSObjectProtocol] = []
    private var generation = UUID()

    init(notificationCenter: NotificationCenter = .default, interrupted: @escaping (String) -> Void) {
        self.notificationCenter = notificationCenter
        self.interrupted = interrupted
    }
    func start() {
        stop()
        let current = generation
        // Both observers deliver on the main operation queue. Pause immediately
        // there, before a completion callback can enqueue another utterance.
        observers.append(notificationCenter.addObserver(forName: AVAudioSession.interruptionNotification,
            object: nil, queue: .main) { [weak self] note in
                let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? NSNumber)?.uintValue
                guard type == AVAudioSession.InterruptionType.began.rawValue else { return }
                MainActor.assumeIsolated {
                    guard let self, self.generation == current else { return }
                    self.interrupted(String(localized: "Reading paused after an audio interruption."))
                }
            })
        observers.append(notificationCenter.addObserver(forName: AVAudioSession.routeChangeNotification,
            object: nil, queue: .main) { [weak self] note in
                let reason = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? NSNumber)?.uintValue
                guard reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue else { return }
                MainActor.assumeIsolated {
                    guard let self, self.generation == current else { return }
                    self.interrupted(String(localized: "Audio output changed. Resume reading when you are ready."))
                }
            })
    }
    func stop() {
        generation = UUID()
        for observer in observers { notificationCenter.removeObserver(observer) }
        observers.removeAll()
    }
}
