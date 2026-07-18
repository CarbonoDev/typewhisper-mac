import Foundation

/// The in-memory quick-note draft (Track E, ME-3, plan D1): a compose-then-create buffer that exists
/// **before any file does**. `folderPath` is the vault-relative Space folder the note will land in (the
/// currently viewed `.spaceFolder` route); `text` is the raw markdown the user is typing. Committing
/// performs exactly one never-clobber creation write via `VaultNoteWriter`; there is no path until then.
struct SpaceDraftState: Equatable {
    /// The vault-relative folder the committed note lands in (`""` = the Space root).
    var folderPath: String
    /// The raw markdown being composed.
    var text: String
}

/// Pure, SwiftUI-free draft logic (Track E, ME-3). Kept a static surface (like `SpaceSelection` /
/// `SpaceReveal`) so filename derivation and the discard decision are unit-testable without the view,
/// the view model, or a live vault. Never touches disk.
enum SpaceDraft {
    /// The on-disk fallback filename for a draft with no usable first line (owner-approved default,
    /// plan owner-veto 4). Deliberately **not** localized — like the exporter's `"Meeting"` fallback, a
    /// vault filename stays stable across UI languages.
    static let fallbackFilename = "Untitled"

    /// The first non-empty line of `text`, with a leading markdown heading marker (`#`, `##`, …) stripped
    /// and trimmed — the note's emerging title. `nil` when every line is blank or only heading markers, so
    /// the caller falls back to a localized placeholder (display) or `fallbackFilename` (filename).
    static func firstLineTitle(_ text: String) -> String? {
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            while line.hasPrefix("#") { line.removeFirst() }
            line = line.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            return line
        }
        return nil
    }

    /// The sanitized filename base (no extension) for a draft: the first-line title with illegal
    /// characters stripped (`VaultNoteWriter.sanitizeFilename`), falling back to `fallbackFilename` when
    /// there is no usable line or sanitization empties it (e.g. a first line of only `"/"`).
    static func filename(from text: String) -> String {
        guard let title = firstLineTitle(text) else { return fallbackFilename }
        let sanitized = VaultNoteWriter.sanitizeFilename(title)
        return sanitized.isEmpty ? fallbackFilename : sanitized
    }

    /// Whether `text` carries content worth confirming before a **deliberate** discard. Empty (only
    /// whitespace/newlines) ⇒ no confirmation (frictionless, plan §D1); non-empty ⇒ confirm so a typed
    /// draft is never silently lost via the explicit Discard affordance. (Navigate-away auto-commits
    /// instead — never-clobber makes that safe — so it needs no dialog.)
    static func shouldConfirmDiscard(_ text: String) -> Bool {
        !isEmpty(text)
    }

    /// Whether `text` has no committable content (only whitespace/newlines). An empty draft is
    /// discarded silently and creates no file.
    static func isEmpty(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
