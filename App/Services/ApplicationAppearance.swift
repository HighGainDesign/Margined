import AppKit

/// An application override includes native title bars, panels and windows that
/// do not contain a document. A nil override restores the system appearance.
@MainActor
final class ApplicationAppearance {
    private var observer: NSObjectProtocol?

    func start() {
        stop()
        apply()
        observer = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification,
            object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.apply() }
            }
    }

    func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
    }

    private func apply() {
        let appearance: NSAppearance?
        switch ReaderPreferences.appearance(in: ReaderPreferences.defaults) {
        case .system: appearance = nil
        case .light: appearance = NSAppearance(named: .aqua)
        case .dark: appearance = NSAppearance(named: .darkAqua)
        }
        if NSApp.appearance?.name != appearance?.name { NSApp.appearance = appearance }
    }
}
