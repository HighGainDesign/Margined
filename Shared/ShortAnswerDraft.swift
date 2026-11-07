import Foundation
import Observation

/// A focused editor owns one mapped field in one exact displayed file version.
@MainActor @Observable
final class ShortAnswerDraft: Identifiable {
    let id = UUID()
    let field: MarkdownTextResponse
    let expected: SourceFileEdit.Snapshot
    let context: UUID
    var text: String { didSet { error = nil } }
    var error: String?
    var saving = false
    var stale = false
    @ObservationIgnored var endEditing: (() -> Void)?

    init(field: MarkdownTextResponse, expected: SourceFileEdit.Snapshot, context: UUID) {
        self.field = field; self.expected = expected; self.context = context
        text = field.plainValue
    }

    var validationMessage: String? {
        if text.utf8.elementsEqual(field.plainValue.utf8) { return nil }
        do { _ = try MarkdownResponses.normalizedAnswer(text); return nil }
        catch { return error.localizedDescription }
    }
}
