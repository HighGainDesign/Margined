import Foundation

enum TutorialPlatform: Sendable {
    case mac, sandboxedMac, mobile
    static var current: Self {
        #if os(iOS)
        .mobile
        #elseif MARGINED_APP_STORE
        .sandboxedMac
        #else
        .mac
        #endif
    }
}

enum TutorialLesson: String, CaseIterable, Identifiable, Sendable {
    case opening, quickLook, streaming, changes, discussions, checklists, images
    var id: Self { self }
    static func lessons(for platform: TutorialPlatform) -> [Self] {
        allCases.filter { platform != .mobile || $0 != .streaming }
    }
    var title: String {
        switch self {
        case .opening: String(localized: "Open and Browse")
        case .quickLook: String(localized: "Quick Look")
        case .streaming: String(localized: "Live Streaming Preview")
        case .changes: String(localized: "Review Changes")
        case .discussions: String(localized: "Discussions")
        case .checklists: String(localized: "Checklists")
        case .images: String(localized: "Local Image Folders")
        }
    }
    var symbol: String {
        switch self {
        case .opening: "folder"
        case .quickLook: "doc.viewfinder"
        case .streaming: "antenna.radiowaves.left.and.right"
        case .changes: "checklist"
        case .discussions: "bubble.left.and.bubble.right"
        case .checklists: "checkmark.square"
        case .images: "photo.on.rectangle"
        }
    }
    func explanation(for platform: TutorialPlatform) -> String {
        switch self {
        case .opening:
            String(localized: "Open a Markdown file from Files, Finder or another app. Close it to return to browsing. Your documents stay ordinary files.")
        case .quickLook:
            platform == .mobile
                ? String(localized: "On iOS 27, Files currently shows Markdown as plain text instead of using Margined’s Quick Look extension. Choose Open With → Margined or Share → Margined for the formatted document.")
                : String(localized: "Enable Margined in System Settings → Extensions → Quick Look. Select a Markdown file in Finder and press Space. Other enabled Markdown previewers may be chosen instead.")
        case .streaming:
            String(localized: "Live Streaming follows the active text from supported writing apps. Start it from Margined’s welcome screen or File menu. Drafts is one example: enable its Marked streaming option, then edit a draft. Pause holds the current text; Resume catches up.")
        case .changes:
            String(localized: "Keep a saved document open while another app or agent changes it. Margined refreshes without losing your place. Review Changes shows what changed; marking a change reviewed acknowledges it without editing the document.")
        case .discussions:
            String(localized: "Select a passage and add a discussion. Replies, author names and resolution are saved inside the Markdown file. Open the practice conversation, reply, then resolve and reopen it. Unposted replies stay protected when you close or switch documents.")
        case .checklists:
            String(localized: "Click a task box to save progress to Markdown. The first click explains the write before you agree. Each tick saves automatically and supports Undo. Other apps and agents can read the saved checkmarks.")
        case .images:
            platform == .mac
                ? String(localized: "The GitHub Mac app loads nearby images using ordinary macOS file access. Protected folders may still require system permission. Remote images stay off until you enable them for a document.")
                : String(localized: "Opening a file doesn’t grant access to nearby images. Choose a folder containing the document and its images; subfolders are included. You can choose all of Dropbox or iCloud Drive when Files permits it, or remember several smaller folders. Manage grants in Settings.")
        }
    }
}
