#if MARGINED_APP_STORE
import AppKit

extension ReaderState {
    func allowImageFolder() {
        guard let window = NSApp.keyWindow else { return }
        let panel = NSOpenPanel()
        panel.title = String(localized: "Local images")
        panel.prompt = String(localized: "Allow Folder")
        panel.message = String(localized: "Choose a folder containing this document’s images. Margined remembers access on this Mac.")
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = fileURL?.deletingLastPathComponent()
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let self, let folder = panel.url else { return }
            do {
                try SandboxImageFolders.shared.allow(folder)
                // Retry only resources from the displayed version, including paused files.
                localImageError = nil
                imageReloadGeneration += 1
            } catch {
                localImageError = error.localizedDescription
            }
        }
    }
}
#endif
