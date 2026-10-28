import AppKit

/// Resolves the active editor before falling back to the document’s last valid file edit.
@MainActor
struct ReaderUndo {
    let responder: NSResponder?
    let reader: ReaderState?

    private var editor: NSTextView? {
        guard let editor = responder as? NSTextView, editor.isEditable else { return nil }
        return editor
    }

    var isEditingText: Bool { editor != nil }
    var canUndo: Bool { editor.map { $0.undoManager?.canUndo == true } ?? (reader?.canUndoDiscussion == true || reader?.canUndoChecklist == true) }
    var canRedo: Bool { editor.map { $0.undoManager?.canRedo == true } ?? (reader?.canRedoDiscussion == true || reader?.canRedoChecklist == true) }

    func undo() {
        if let editor { if editor.undoManager?.canUndo == true { editor.undoManager?.undo() } }
        else if reader?.canUndoDiscussion == true { reader?.undoDiscussion() }
        else { reader?.undoChecklist() }
    }

    func redo() {
        if let editor { if editor.undoManager?.canRedo == true { editor.undoManager?.redo() } }
        else if reader?.canRedoDiscussion == true { reader?.redoDiscussion() }
        else { reader?.redoChecklist() }
    }
}
