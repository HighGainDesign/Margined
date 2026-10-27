import AppKit
import QuickLookUI
import Foundation

private struct HostCommand: Decodable, Sendable {
    let action: String
    let path: String?
    let token: String?
}

@MainActor
final class SystemViewingHost: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private var preview: QLPreviewView?
    private var previous: NSRunningApplication?
    private var closing = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        previous = NSWorkspace.shared.frontmostApplication
        let frame = NSRect(x: 0, y: 0, width: 850, height: 700)
        let window = NSWindow(contentRect: frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        guard let preview = QLPreviewView(frame: frame, style: .normal) else { finish(); return }
        self.window = window; self.preview = preview
        preview.autostarts = false; window.contentView = preview
        window.title = "Margined — Quick Look benchmark"
        window.center(); window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        emit(["phase": "host-ready", "pid": getpid(), "window": window.windowNumber,
              "host_ready_ns": DispatchTime.now().uptimeNanoseconds])
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(360)); self?.finish()
        }
        Task.detached { [weak self] in
            while let line = readLine() {
                guard let command = try? JSONDecoder().decode(HostCommand.self, from: Data(line.utf8)) else { continue }
                await self?.handle(command)
            }
            await self?.finish()
        }
    }

    private func handle(_ command: HostCommand) {
        guard !closing else { return }
        switch command.action {
        case "open":
            guard let path = command.path, let token = command.token,
                  UUID(uuidString: token) != nil else { return }
            let url = URL(fileURLWithPath: path)
            guard url.pathExtension == "marginedqlbench14" ||
                (url.pathExtension == "txt" && url.lastPathComponent.hasPrefix("negative-raw-")) else { return }
            let start = DispatchTime.now().uptimeNanoseconds
            preview?.previewItem = url as NSURL
            emit(["phase": "requested", "pid": getpid(), "token": token,
                  "file": url.lastPathComponent, "request_ns": start])
        case "status":
            guard let window else { return }
            emit(["phase": "status", "pid": getpid(), "token": command.token ?? "",
                  "window": window.windowNumber, "active": NSApp.isActive,
                  "visible": window.isVisible, "onSpace": window.isOnActiveSpace,
                  "unoccluded": window.occlusionState.contains(.visible),
                  "windowWidth": window.frame.width, "windowHeight": window.frame.height,
                  "contentWidth": preview?.bounds.width ?? 0, "contentHeight": preview?.bounds.height ?? 0,
                  "scale": window.backingScaleFactor])
        case "end":
            guard let window, let preview else { return }
            window.makeFirstResponder(preview)
            let delivered = NSApp.sendAction(NSSelectorFromString("scrollToEndOfDocument:"), to: nil, from: nil)
            emit(["phase": "end-requested", "pid": getpid(), "token": command.token ?? "", "delivered": delivered])
        case "page-down": pageDown(command.token ?? "")
        case "close": finish()
        default: break
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) {
        closePreview()
        emit(["phase": "will-terminate", "pid": getpid()])
        if let previous, !previous.isTerminated, previous.processIdentifier != getpid() {
            previous.activate(options: [])
        }
    }
    /// Deliver ordinary AppKit events only to this host's own active window.
    /// This does not post system input or request Accessibility permission.
    private func pageDown(_ token: String) {
        guard let window, let preview, NSApp.isActive, window.isVisible else { return }
        let views = descendants(preview)
        let candidates = views.filter {
            !$0.isHidden && $0.acceptsFirstResponder &&
            $0.bounds.width > preview.bounds.width / 2 &&
            $0.bounds.height > preview.bounds.height / 2
        }
        if let target = candidates.last { _ = window.makeFirstResponder(target) }
        let point = preview.convert(NSPoint(x: preview.bounds.midX, y: preview.bounds.midY), to: nil)
        let time = ProcessInfo.processInfo.systemUptime
        var sent = 0
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            if let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                timestamp: time, windowNumber: window.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0) {
                window.sendEvent(event); sent += 1
            }
        }
        let character = String(UnicodeScalar(UInt32(NSPageDownFunctionKey))!)
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            if let event = NSEvent.keyEvent(with: type, location: point,
                modifierFlags: [.function, .numericPad], timestamp: time,
                windowNumber: window.windowNumber, context: nil, characters: character,
                charactersIgnoringModifiers: character, isARepeat: false, keyCode: 121) {
                window.sendEvent(event); sent += 1
            }
        }
        emit(["phase": "page-down-requested", "pid": getpid(), "token": token,
              "ownWindow": window.windowNumber, "eventsSent": sent,
              "firstResponder": window.firstResponder.map { String(describing: type(of: $0)) } ?? "none",
              "views": views.prefix(64).map { view in
                  ["class": String(describing: type(of: view)), "acceptsFirstResponder": view.acceptsFirstResponder,
                   "width": view.bounds.width, "height": view.bounds.height] as [String: Any]
              }])
    }
    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants($0) }
    }

    private func closePreview() {
        guard let preview else { return }
        self.preview = nil
        preview.close()
    }

    private func finish() {
        guard !closing else { return }; closing = true
        closePreview(); window?.orderOut(nil)
        emit(["phase": "closing", "pid": getpid()]); NSApp.terminate(nil)
    }
    private func emit(_ value: [String: Any]) {
        if let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) {
            FileHandle.standardOutput.write(data); FileHandle.standardOutput.write(Data([10]))
        }
    }
}

@main
struct SystemViewingCheck {
    @MainActor static func main() {
        let app = NSApplication.shared, delegate = SystemViewingHost()
        app.delegate = delegate; app.setActivationPolicy(.regular); app.run()
        withExtendedLifetime(delegate) {}
    }
}
