import Foundation

/// The shared never-clobber vault write discipline (Track E, ME-3, plan D6). Extracted **verbatim**
/// from `MeetingObsidianExporter`'s private trio (`sanitizeFilename` / `uniquePath` / atomic write +
/// `createDirectory`) so exactly one implementation backs **both** the meeting exporter and Space's
/// compose-then-create quick-note. Never overwrites an existing file — a fresh note collides into
/// `"<name> 1.md"`, `"<name> 2.md"`, … — which is the *only* write mode Space and the exporter have
/// (the spec's non-negotiable invariant). A pure, `nonisolated`/`Sendable` static surface: no actor,
/// no I/O beyond the single directory-create + atomic write, unit-testable against a temp directory.
enum VaultNoteWriter {
    /// Strip characters illegal in a filename (mirrors `ObsidianPlugin.sanitizeFilename`). Idempotent —
    /// re-sanitizing an already-clean name is a no-op — so the exporter (which sanitizes when building
    /// its base name) and Space (which sanitizes a note's first line) share one rule.
    static func sanitizeFilename(_ name: String) -> String {
        let illegal = CharacterSet(charactersIn: "/:\\*?\"<>|")
        return name.components(separatedBy: illegal).joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Return `path` if free, else `<name> 1.<ext>`, `<name> 2.<ext>`, … (mirrors
    /// `ObsidianPlugin.uniquePath`) so an existing note is never overwritten.
    static func uniquePath(for path: String) -> String {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: path) else { return path }
        let dir = (path as NSString).deletingLastPathComponent
        let name = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        let ext = (path as NSString).pathExtension
        var counter = 1
        while true {
            let candidate = (dir as NSString).appendingPathComponent("\(name) \(counter).\(ext)")
            if !fileManager.fileExists(atPath: candidate) {
                return candidate
            }
            counter += 1
        }
    }

    /// Create `folderPath` (intermediates included) and atomically write `content` to a **never-clobbered**
    /// `<filename>.md` under it, returning the URL actually written. `filename` is used as-is (callers
    /// sanitize first via `sanitizeFilename`); an empty name defensively falls back to `"Untitled"`.
    /// Throws `VaultWriteError.writeFailed` on any filesystem failure so the content is never silently
    /// lost.
    static func write(content: String, toFolder folderPath: String, filename: String) throws -> URL {
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(atPath: folderPath, withIntermediateDirectories: true)
        } catch {
            throw VaultWriteError.writeFailed(error.localizedDescription)
        }
        let safe = filename.isEmpty ? "Untitled" : filename
        let filePath = (folderPath as NSString).appendingPathComponent("\(safe).md")
        let finalPath = uniquePath(for: filePath)
        do {
            try content.write(toFile: finalPath, atomically: true, encoding: .utf8)
        } catch {
            throw VaultWriteError.writeFailed(error.localizedDescription)
        }
        return URL(fileURLWithPath: finalPath)
    }
}

/// A vault write failure surfaced by `VaultNoteWriter` (permissions, disk, …). The exporter maps this
/// to its own `MeetingExportError.writeFailed`; Space keeps the draft on the page so nothing is lost.
enum VaultWriteError: LocalizedError, Equatable {
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .writeFailed(let message):
            return message
        }
    }
}
