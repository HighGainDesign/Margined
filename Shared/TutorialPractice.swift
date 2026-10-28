import Foundation

/// A capability for one freshly generated disposable file, never an arbitrary
/// document selected by the user. Its writer retains the original inode/bytes.
struct TutorialPractice: Sendable {
    let lesson: TutorialLesson
    let url: URL
    private let baseline: SourceFileEdit.Snapshot
    private let replacement: Data?
    private let gate: SourceFileGate

    static func make(lesson: TutorialLesson, under root: URL, platform: TutorialPlatform = .mac) throws -> Self {
        let directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let url = directory.appendingPathComponent("Practice.md")
        var source = "# \(lesson.title)\n\n\(String(localized: "This is a disposable practice document. Your own files are unchanged."))\n\n"
        var replacement: Data?
        switch lesson {
        case .checklists:
            source += "- [ ] \(String(localized: "Try a checkmark, then Undo."))\n- [ ] \(String(localized: "Close and reopen to check your saved progress."))\n"
        case .changes:
            source += String(localized: "Keep this document open. Choose Save Example Change in the practice bar, then open Review Changes.") + "\n\n"
            let before = String(localized: "The next release includes a document browser.")
            let after = String(localized: "The next release includes a document browser and a guided tour.")
            replacement = Data((source + after + "\n").utf8)
            source += before + "\n"
        case .discussions:
            let quote = String(localized: "This passage has a conversation attached to it.")
            source += quote + "\n"
            let parsed = try DiscussionCodec.parse(source), id = UUID().uuidString.lowercased()
            let date = ISO8601DateFormatter().string(from: Date())
            let thread = DiscussionThread(id: "t-" + id, state: .open,
                target: .init(type: "TextQuoteSelector", exact: quote, prefix: "", suffix: "", section: lesson.title),
                messages: [
                    .init(id: "m1-" + id, author: "Alex", created: date,
                          body: String(localized: "Could we make this passage clearer?"), inReplyTo: nil),
                    .init(id: "m2-" + id, author: "Sam", created: date,
                          body: String(localized: "Yes. Add your own reply, then try resolving this discussion."), inReplyTo: "m1-" + id)
                ], resolvedBy: nil, resolved: nil, attachmentHistory: [])
            source = try MarkdownSource.decode(MarkdownSourceEdits.apply(DiscussionEdits.splices(for: .newThread(thread), in: parsed),
                to: Data(source.utf8), expectedSource: source))
        case .images:
            for (name, color) in [("warm", "#d99b00"), ("cool", "#1976d2")] {
                let folder = directory.appendingPathComponent("images/" + name, isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try Data("<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"240\" height=\"120\"><rect width=\"240\" height=\"120\" rx=\"18\" fill=\"\(color)\"/></svg>".utf8)
                    .write(to: folder.appendingPathComponent("marker.svg"), options: .withoutOverwriting)
            }
            source += "![\(lesson.title)](images/warm/marker.svg)\n\n![\(lesson.title)](images/cool/marker.svg)\n"
        default:
            source += lesson.explanation(for: platform) + "\n"
        }
        try Data(source.utf8).write(to: url, options: .withoutOverwriting)
        return Self(lesson: lesson, url: url, baseline: try SourceFileEdit.read(url), replacement: replacement, gate: SourceFileGate())
    }

    func saveExampleChange() async throws {
        guard let replacement else { throw SourceFileEdit.Failure.changed }
        let baseline = baseline
        _ = try await gate.enqueue { try SourceFileEdit.commit(replacement, expected: baseline) }.value()
    }
}
