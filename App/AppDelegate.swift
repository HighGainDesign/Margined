import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSMenuItemValidation {
    private var welcome: NSWindowController?
    private var settings: NSWindowController?
    private var setup: SetupWindowController?

    func applicationWillFinishLaunching(_ notification: Notification) {
        buildMenus()
        _ = NSDocumentController.shared
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate(ignoringOtherApps: true)
        #if MARGINED_BENCHMARK
        if ViewingBenchmarkSession.startIfRequested() { return }
        #endif
        Task { @MainActor in
            await Task.yield()
            showStartupTips()
        }
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        // AppKit calls this when launching without a document to open.
        #if MARGINED_BENCHMARK
        if ProcessInfo.processInfo.environment["MARGINED_BENCHMARK_REQUEST"] != nil { return false }
        #endif
        showWelcome()
        return false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            let documents = NSDocumentController.shared.documents
            if documents.isEmpty { showWelcome() }
            else { documents.forEach { $0.showWindows() } }
        }
        return true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            if url.isFileURL {
                NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { [weak self] _, _, error in
                    if let error { NSApp.presentError(error) }
                    else { self?.welcome?.close() }
                }
            } else {
                if url.scheme?.lowercased() == "margined", url.host == "stream" {
                    showLiveStreamingPreview()
                    continue
                }
                do {
                    let request = try PreviewRequest(url: url)
                    let document = MarkdownDocument(preview: request)
                    NSDocumentController.shared.addDocument(document)
                    document.makeWindowControllers()
                    document.showWindows()
                    welcome?.close()
                } catch { NSApp.presentError(error) }
            }
        }
        application.activate(ignoringOtherApps: true)
    }

    func showWelcome() {
        guard NSDocumentController.shared.documents.isEmpty else {
            documentDidOpen()
            return
        }
        if welcome == nil {
            let view = WelcomeView(open: { NSDocumentController.shared.openDocument(nil) },
                                   liveStreaming: { [weak self] in self?.showLiveStreamingPreview() })
            let window = NSWindow(contentViewController: NSHostingController(rootView: view))
            window.title = String(localized: "Margined")
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.contentMinSize = NSSize(width: 480, height: 380)
            window.setContentSize(NSSize(width: 520, height: 440))
            window.center()
            welcome = NSWindowController(window: window)
        }
        welcome?.showWindow(nil)
    }

    func documentDidOpen() {
        welcome?.close()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        func saving() -> Bool {
            NSDocumentController.shared.documents.compactMap { $0 as? MarkdownDocument }.contains { $0.reader.fileSaving }
        }
        guard saving() else { return confirmDiscardDiscussionDrafts() ? .terminateNow : .terminateCancel }
        Task {
            while saving() { try? await Task.sleep(for: .milliseconds(10)) }
            sender.reply(toApplicationShouldTerminate: confirmDiscardDiscussionDrafts())
        }
        return .terminateLater
    }

    private func confirmDiscardDiscussionDrafts() -> Bool {
        let readers = NSDocumentController.shared.documents.compactMap { ($0 as? MarkdownDocument)?.reader }
        guard readers.contains(where: { $0.discussions.hasUnpostedDrafts }) else { return true }
        let alert = NSAlert()
        alert.messageText = String(localized: "Discard unposted replies and quit?")
        alert.informativeText = String(localized: "Keep Margined open to finish your comments and replies, or discard the unposted text and quit.")
        alert.alertStyle = .warning
        alert.addButton(withTitle: String(localized: "Keep Open"))
        alert.addButton(withTitle: String(localized: "Discard Drafts and Quit")).hasDestructiveAction = true
        guard alert.runModal() == .alertSecondButtonReturn else { return false }
        for reader in readers { reader.discussions.discardDrafts() }
        return true
    }

    func showLiveStreamingPreview() {
        if let document = NSDocumentController.shared.documents.compactMap({ $0 as? MarkdownDocument })
            .first(where: { $0.reader.isStreamingPreview }) {
            document.reader.streamPaused = false
            document.showWindows()
        } else {
            let document = MarkdownDocument(streamingPreview: true)
            NSDocumentController.shared.addDocument(document)
            document.makeWindowControllers()
            document.showWindows()
        }
        welcome?.close()
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func liveStreamingPreview(_ sender: Any?) { showLiveStreamingPreview() }

    @objc private func showSettings(_ sender: Any?) {
        if settings == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView()))
            window.title = String(localized: "Margined Settings")
            window.styleMask = [.titled, .closable, .resizable]
            window.minSize = NSSize(width: 600, height: 540)
            window.setContentSize(NSSize(width: 600, height: 680))
            window.center()
            settings = NSWindowController(window: window)
        }
        settings?.showWindow(nil)
    }

    func showStartupTips(force: Bool = false) {
        if let setup, setup.window?.isVisible == true {
            setup.showWindow(nil)
            return
        }
        guard force || StartupTips.shouldShow() else { return }
        let controller = SetupWindowController()
        setup = controller
        controller.showWindow(nil)
    }

    private var reader: ReaderState? {
        (NSDocumentController.shared.currentDocument as? MarkdownDocument)?.reader
    }

    @objc private func find(_ sender: Any?) { reader?.showFind = true }
    @objc private func reload(_ sender: Any?) { reader?.reload() }
    @objc private func toggleFileUpdates(_ sender: Any?) {
        guard let reader else { return }
        reader.setFileUpdatesPaused(!reader.fileUpdatesPaused)
    }
    func openSpeechSettings() { SettingsNavigation.shared.page = .speech; showSettings(nil) }
    @objc private func toggleSpeech(_ sender: Any?) { reader?.speech.showPlayer = true; reader?.speech.togglePlayback() }
    @objc private func stopSpeech(_ sender: Any?) { reader?.existingSpeech?.stop() }
    @objc private func speakBeginning(_ sender: Any?) { reader?.speech.requestStart(.beginning) }
    @objc private func speakSection(_ sender: Any?) { reader?.speech.requestStart(.visible) }
    @objc private func speakSelection(_ sender: Any?) { reader?.speech.requestStart(.selection) }
    @objc private func nextSpeechSection(_ sender: Any?) { reader?.existingSpeech?.session.nextSection() }
    @objc private func previousSpeechSection(_ sender: Any?) { reader?.existingSpeech?.session.previousSection() }
    @objc private func focusDocument(_ sender: Any?) { reader?.focusDocument() }
    @objc private func returnToNavigation(_ sender: Any?) { reader?.returnToNavigation() }
    @objc private func nextUncheckedTask(_ sender: Any?) { reader?.jumpToUncheckedTask() }
    @objc private func previousUncheckedTask(_ sender: Any?) { reader?.jumpToUncheckedTask(backwards: true) }
    @objc private func nextChange(_ sender: Any?) { reader?.jumpToChange(focus: true) }
    @objc private func previousChange(_ sender: Any?) { reader?.jumpToChange(backwards: true, focus: true) }
    @objc private func zoomIn(_ sender: Any?) { reader?.changeZoom(by: 0.1) }
    private var undoActions: ReaderUndo { ReaderUndo(responder: NSApp.keyWindow?.firstResponder, reader: reader) }
    @objc private func undoCheckbox(_ sender: Any?) { undoActions.undo() }
    @objc private func redoCheckbox(_ sender: Any?) { undoActions.redo() }
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(toggleSpeech(_:)) {
            menuItem.title = reader?.existingSpeech?.session.status == .playing ? String(localized: "Pause Reading") : String(localized: "Read Aloud")
        }
        let speechActions: [Selector] = [#selector(toggleSpeech(_:)), #selector(speakBeginning(_:)), #selector(speakSection(_:)), #selector(speakSelection(_:))]
        if speechActions.contains(menuItem.action ?? #selector(toggleSpeech(_:))) && menuItem.action != nil {
            return reader?.rendered?.speech?.segments.isEmpty == false && reader?.isRendering == false && reader?.checklistSaving == false && reader?.showChecklistConfirmation == false
        }
        if menuItem.action == #selector(stopSpeech(_:)) { return reader?.existingSpeech?.session.isActive == true }
        if menuItem.action == #selector(nextSpeechSection(_:)) || menuItem.action == #selector(previousSpeechSection(_:)) { return reader?.existingSpeech?.session.isActive == true }
        if menuItem.action == #selector(focusDocument(_:)) { return reader?.rendered != nil }
        if menuItem.action == #selector(returnToNavigation(_:)) { return reader?.navigationReturnTarget != nil }
        if menuItem.action == #selector(nextUncheckedTask(_:)) || menuItem.action == #selector(previousUncheckedTask(_:)) {
            return (reader?.rendered?.checkboxCount ?? 0) > 0
        }
        if menuItem.action == #selector(nextChange(_:)) || menuItem.action == #selector(previousChange(_:)) {
            return (reader?.changes.count ?? 0) > 0
        }
        if menuItem.action == #selector(toggleFileUpdates(_:)) {
            menuItem.title = reader?.fileUpdatesPaused == true ? String(localized: "Resume Updates") : String(localized: "Pause Updates")
            return reader?.fileURL != nil && reader?.isStreamingPreview == false
        }
        if menuItem.action == #selector(undoCheckbox(_:)) {
            menuItem.title = undoActions.isEditingText ? String(localized: "Undo") : String(localized: "Undo Checkbox Change")
            return undoActions.canUndo
        }
        if menuItem.action == #selector(redoCheckbox(_:)) {
            menuItem.title = undoActions.isEditingText ? String(localized: "Redo") : String(localized: "Redo Checkbox Change")
            return undoActions.canRedo
        }
        return true
    }

    @objc private func zoomOut(_ sender: Any?) { reader?.changeZoom(by: -0.1) }
    @objc private func actualSize(_ sender: Any?) { reader?.zoom = 1 }
    @objc private func toggleOutline(_ sender: Any?) { reader?.showOutline.toggle() }
    @objc private func reviewChanges(_ sender: Any?) {
        guard let reader, reader.fileURL != nil else { return }
        reader.showChanges.toggle()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        for url in NSDocumentController.shared.recentDocumentURLs {
            let item = NSMenuItem(title: url.lastPathComponent, action: #selector(openRecent(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = url
            item.toolTip = url.path
            menu.addItem(item)
        }
        if !menu.items.isEmpty { menu.addItem(.separator()) }
        add(String(localized: "Clear Menu"), to: menu, action: #selector(NSDocumentController.clearRecentDocuments(_:)))
    }

    @objc private func openRecent(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        application(NSApp, open: [url])
    }

    private func buildMenus() {
        let bar = NSMenu()
        let app = NSMenu(title: String(localized: "Margined"))
        add(String(localized: "About Margined"), to: app, action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)))
        app.addItem(.separator())
        add(String(localized: "Settings…"), to: app, action: #selector(showSettings(_:)), key: ",", target: self)
        app.addItem(.separator())
        let services = NSMenu(title: String(localized: "Services"))
        let serviceItem = NSMenuItem(title: String(localized: "Services"), action: nil, keyEquivalent: "")
        serviceItem.submenu = services
        app.addItem(serviceItem)
        NSApp.servicesMenu = services
        app.addItem(.separator())
        add(String(localized: "Hide Margined"), to: app, action: #selector(NSApplication.hide(_:)), key: "h")
        add(String(localized: "Hide Others"), to: app, action: #selector(NSApplication.hideOtherApplications(_:)), key: "h", modifiers: [.command, .option])
        add(String(localized: "Show All"), to: app, action: #selector(NSApplication.unhideAllApplications(_:)))
        app.addItem(.separator())
        add(String(localized: "Quit Margined"), to: app, action: #selector(NSApplication.terminate(_:)), key: "q")
        attach(app, to: bar)

        let file = NSMenu(title: String(localized: "File"))
        add(String(localized: "Open…"), to: file, action: #selector(NSDocumentController.openDocument(_:)), key: "o")
        add(String(localized: "Live Streaming Preview"), to: file, action: #selector(liveStreamingPreview(_:)), target: self)
        let recent = NSMenu(title: String(localized: "Open Recent"))
        recent.delegate = self
        add(String(localized: "Clear Menu"), to: recent, action: #selector(NSDocumentController.clearRecentDocuments(_:)))
        let recentItem = NSMenuItem(title: String(localized: "Open Recent"), action: nil, keyEquivalent: "")
        recentItem.submenu = recent
        file.addItem(recentItem)
        file.addItem(.separator())
        add(String(localized: "Close Window"), to: file, action: #selector(NSWindow.performClose(_:)), key: "w")
        file.addItem(.separator())
        add(String(localized: "Print…"), to: file, action: #selector(NSDocument.printDocument(_:)), key: "p")
        attach(file, to: bar)

        let edit = NSMenu(title: String(localized: "Edit"))
        add(String(localized: "Undo Checkbox Change"), to: edit, action: #selector(undoCheckbox(_:)), key: "z", target: self)
        add(String(localized: "Redo Checkbox Change"), to: edit, action: #selector(redoCheckbox(_:)), key: "z", modifiers: [.command, .shift], target: self)
        edit.addItem(.separator())
        add(String(localized: "Copy"), to: edit, action: #selector(NSText.copy(_:)), key: "c")
        add(String(localized: "Select All"), to: edit, action: #selector(NSText.selectAll(_:)), key: "a")
        edit.addItem(.separator())
        add(String(localized: "Find…"), to: edit, action: #selector(find(_:)), key: "f", target: self)
        attach(edit, to: bar)

        let view = NSMenu(title: String(localized: "View"))
        add(String(localized: "Reload"), to: view, action: #selector(reload(_:)), key: "r", target: self)
        add(String(localized: "Pause Updates"), to: view, action: #selector(toggleFileUpdates(_:)), key: "p", modifiers: [.command, .option], target: self)
        add(String(localized: "Review Changes"), to: view, action: #selector(reviewChanges(_:)), key: "r", modifiers: [.command, .shift], target: self)
        add(String(localized: "Toggle Outline"), to: view, action: #selector(toggleOutline(_:)), key: "o", modifiers: [.command, .option], target: self)
        view.addItem(.separator())
        add(String(localized: "Focus Document"), to: view, action: #selector(focusDocument(_:)), key: "d", modifiers: [.command, .option], target: self)
        add(String(localized: "Return to Navigation"), to: view, action: #selector(returnToNavigation(_:)), key: "u", modifiers: [.command, .option], target: self)
        add(String(localized: "Next Unchecked Task"), to: view, action: #selector(nextUncheckedTask(_:)), key: "j", modifiers: [.command, .option], target: self)
        add(String(localized: "Previous Unchecked Task"), to: view, action: #selector(previousUncheckedTask(_:)), key: "j", modifiers: [.command, .option, .shift], target: self)
        add(String(localized: "Next Unreviewed Change"), to: view, action: #selector(nextChange(_:)), key: "]", modifiers: [.command, .option], target: self)
        add(String(localized: "Previous Unreviewed Change"), to: view, action: #selector(previousChange(_:)), key: "[", modifiers: [.command, .option], target: self)
        view.addItem(.separator())
        add(String(localized: "Zoom In"), to: view, action: #selector(zoomIn(_:)), key: "+", target: self)
        add(String(localized: "Zoom Out"), to: view, action: #selector(zoomOut(_:)), key: "-", target: self)
        add(String(localized: "Actual Size"), to: view, action: #selector(actualSize(_:)), key: "0", target: self)
        attach(view, to: bar)

        let speech = NSMenu(title: String(localized: "Read Aloud"))
        add(String(localized: "Read Aloud"), to: speech, action: #selector(toggleSpeech(_:)), key: "l", modifiers: [.command, .option], target: self)
        add(String(localized: "Stop Reading"), to: speech, action: #selector(stopSpeech(_:)), key: "k", modifiers: [.command, .option], target: self)
        speech.addItem(.separator())
        add(String(localized: "From the Beginning"), to: speech, action: #selector(speakBeginning(_:)), target: self)
        add(String(localized: "From Current Section"), to: speech, action: #selector(speakSection(_:)), target: self)
        add(String(localized: "From Selection"), to: speech, action: #selector(speakSelection(_:)), target: self)
        speech.addItem(.separator())
        add(String(localized: "Previous Section"), to: speech, action: #selector(previousSpeechSection(_:)), target: self)
        add(String(localized: "Next Section"), to: speech, action: #selector(nextSpeechSection(_:)), target: self)
        attach(speech, to: bar)

        let window = NSMenu(title: String(localized: "Window"))
        add(String(localized: "Minimize"), to: window, action: #selector(NSWindow.performMiniaturize(_:)), key: "m")
        add(String(localized: "Zoom"), to: window, action: #selector(NSWindow.performZoom(_:)))
        attach(window, to: bar)
        NSApp.windowsMenu = window
        NSApp.mainMenu = bar
    }

    private func add(_ title: String, to menu: NSMenu, action: Selector, key: String = "",
                     modifiers: NSEvent.ModifierFlags = [.command], target: AnyObject? = nil) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.target = target
        menu.addItem(item)
    }

    private func attach(_ menu: NSMenu, to bar: NSMenu) {
        let item = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
        item.submenu = menu
        bar.addItem(item)
    }
}
