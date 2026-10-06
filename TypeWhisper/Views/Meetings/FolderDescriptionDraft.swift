import Foundation

/// [Perf 1C] The folder description being edited in `MeetingFolderDetailView`, kept local to the
/// view and written to `MeetingFolderMetadataStore` only at commit points (blur, submit, an idle
/// pause, disappear, switching folders) instead of on every keystroke — each write JSON-encodes the
/// whole folder map into UserDefaults and republishes the store to every observer.
///
/// Pure value logic so the "never lose the last edit" rules are unit-testable: a commit is owed
/// exactly when the text differs from what was last loaded or committed, and it always targets the
/// folder the text was typed for, even when the view has already moved on to another folder.
struct FolderDescriptionDraft: Equatable {
    struct Commit: Equatable {
        var folderPath: String
        var text: String
    }

    private(set) var folderPath: String
    var text: String
    private(set) var savedText: String

    init(folderPath: String, savedText: String) {
        self.folderPath = folderPath
        self.text = savedText
        self.savedText = savedText
    }

    var isDirty: Bool { text != savedText }

    /// The write owed for the current text, if any; marks it saved.
    mutating func takeCommit() -> Commit? {
        guard isDirty else { return nil }
        savedText = text
        return Commit(folderPath: folderPath, text: text)
    }

    /// Move to another folder: returns the previous folder's owed write, then loads the new one.
    mutating func switchFolder(to newPath: String, savedText newSaved: String) -> Commit? {
        let owed = takeCommit()
        self = FolderDescriptionDraft(folderPath: newPath, savedText: newSaved)
        return owed
    }
}
