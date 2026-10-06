import Foundation

/// First-party tags and folders (plan D6/D7, M3/M4) and their bulk mutators (LX-2 D5).
extension MeetingService {
    // MARK: - First-party tags (plan D6, M3)

    /// Bulk-rename a tag across every meeting that carries it, in a **single** `save()` +
    /// `fetchMeetings()` (plan D6 — not O(n) per-meeting `update()` calls). Case-folded match; the
    /// replacement is re-run through the trim/dedupe policy so a rename onto a tag a meeting already
    /// has **merges** (no case-variant duplicate). No-op when the source is blank, the target trims
    /// empty, or nothing carries the tag.
    func renameTag(_ tag: String, to newName: String) {
        let fromKey = tag.trimmingCharacters(in: .whitespaces).lowercased()
        let trimmedNew = newName.trimmingCharacters(in: .whitespaces)
        guard !fromKey.isEmpty, !trimmedNew.isEmpty else { return }

        var didChange = false
        for meeting in meetings {
            let current = meeting.obsidianTags
            guard current.contains(where: { $0.lowercased() == fromKey }) else { continue }
            // Replace the matched tag with the new name, then dedupe case-insensitively (preserving
            // the first occurrence) so a rename that collides with an existing tag merges instead of
            // leaving `["Recruiting", "recruiting"]`.
            let replaced = current.map { $0.lowercased() == fromKey ? trimmedNew : $0 }
            let cleaned = Self.caseFoldedDedupe(replaced)
            guard cleaned != current else { continue }
            meeting.obsidianTags = cleaned
            meeting.updatedAt = Date()
            didChange = true
        }
        guard didChange else { return }
        commitWrite(.list)
    }

    /// Bulk-delete a tag from every meeting that carries it, in a single save (plan D6). Case-folded.
    func deleteTag(_ tag: String) {
        let key = tag.trimmingCharacters(in: .whitespaces).lowercased()
        guard !key.isEmpty else { return }

        var didChange = false
        for meeting in meetings {
            let current = meeting.obsidianTags
            guard current.contains(where: { $0.lowercased() == key }) else { continue }
            meeting.obsidianTags = current.filter { $0.lowercased() != key }
            meeting.updatedAt = Date()
            didChange = true
        }
        guard didChange else { return }
        commitWrite(.list)
    }

    /// Trim blanks and drop exact-string duplicates while preserving order (the canonical tag policy
    /// shared by `setObsidianTags`).
    static func normalizedTags(_ tags: [String]) -> [String] {
        var seen = Set<String>()
        return tags
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// Trim blanks and drop **case-insensitive** duplicates, keeping the first occurrence's casing.
    /// Used by `renameTag` so a rename merge never yields a case-variant twin.
    private static func caseFoldedDedupe(_ tags: [String]) -> [String] {
        var seen = Set<String>()
        return tags
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }

    // MARK: - First-party folders (plan D7, M4)

    /// Split a `/`-separated folder path into trimmed, non-empty components (the canonical folder
    /// tokenization shared by the mutators, the tree, and the filter). `nil`/blank ⇒ `[]` (Unfiled).
    static func folderComponents(_ path: String?) -> [String] {
        guard let path else { return [] }
        return path
            .split(separator: "/")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Canonical string form of a folder path (components rejoined); `nil` when Unfiled.
    static func normalizedFolderPath(_ path: String?) -> String? {
        let comps = folderComponents(path)
        return comps.isEmpty ? nil : comps.joined(separator: "/")
    }

    /// Set a meeting's folder (first-party alias over `obsidianFolder`), normalizing components.
    /// Empty/blank clears it (the meeting becomes Unfiled).
    func setFolder(_ path: String?, for meeting: Meeting) {
        let normalized = Self.normalizedFolderPath(path)
        guard meeting.obsidianFolder != normalized else { return }
        meeting.obsidianFolder = normalized
        meeting.updatedAt = Date()
        commitWrite(.list)
    }

    /// Bulk-rename a folder across every meeting at or under it, in a **single** `save()` (plan D7).
    /// A rename is a component-wise prefix rewrite of the whole subtree, so `renameFolder` and
    /// `moveFolder` share one implementation.
    func renameFolder(_ old: String, to new: String) {
        rewriteFolderPrefix(from: old, to: new)
    }

    /// Move a folder (and its whole subtree) under a new path — component-wise prefix rewrite, one
    /// save (plan D7). Functionally identical to `renameFolder`; the two names document intent.
    func moveFolder(_ old: String, to new: String) {
        rewriteFolderPrefix(from: old, to: new)
    }

    /// Delete a folder: unfile every meeting at or under `path` (their `folderPath` becomes `nil`),
    /// in one save. The M7 metadata seam is notified so a configured folder's config is dropped.
    func deleteFolder(_ path: String) {
        let comps = Self.folderComponents(path)
        guard !comps.isEmpty else { return }

        var didChange = false
        for meeting in meetings {
            let mc = Self.folderComponents(meeting.obsidianFolder)
            guard mc.count >= comps.count, Array(mc.prefix(comps.count)) == comps else { continue }
            meeting.obsidianFolder = nil
            meeting.updatedAt = Date()
            didChange = true
        }
        onFolderDeleted?(comps.joined(separator: "/"))
        guard didChange else { return }
        commitWrite(.list)
    }

    /// Rewrite the folder prefix `old` → `new` (component-wise, so `Acme` never matches `Acme2`) on
    /// every meeting at or under `old`, in one save. The M7 metadata seam always fires (even when no
    /// meeting currently sits under the folder) so a configured-but-empty folder's config follows the
    /// rename atomically.
    private func rewriteFolderPrefix(from old: String, to new: String) {
        let oldComps = Self.folderComponents(old)
        let newComps = Self.folderComponents(new)
        guard !oldComps.isEmpty, !newComps.isEmpty else { return }
        let oldPath = oldComps.joined(separator: "/")
        let newPath = newComps.joined(separator: "/")
        guard oldPath != newPath else { return }

        var didChange = false
        for meeting in meetings {
            let comps = Self.folderComponents(meeting.obsidianFolder)
            guard comps.count >= oldComps.count, Array(comps.prefix(oldComps.count)) == oldComps else { continue }
            meeting.obsidianFolder = (newComps + comps.dropFirst(oldComps.count)).joined(separator: "/")
            meeting.updatedAt = Date()
            didChange = true
        }
        onFolderPathRewrite?(oldPath, newPath)
        guard didChange else { return }
        commitWrite(.list)
    }

    // MARK: - Bulk mutators (plan LX-2, D5 — single-save, mirrors `renameTag`/`deleteTag`)

    /// Set the folder of every meeting in `meetings` in a **single** `save()` + `fetchMeetings()`
    /// (plan LX-2 D5 — not O(n) per-meeting `setFolder`/`update` calls). The path is normalized once;
    /// meetings already at the target are skipped, and a `didChange` guard makes the whole call a no-op
    /// when nothing moved. Empty/blank ⇒ Unfiled.
    func setFolder(_ path: String?, for meetings: [Meeting]) {
        let normalized = Self.normalizedFolderPath(path)
        var didChange = false
        for meeting in meetings where meeting.obsidianFolder != normalized {
            meeting.obsidianFolder = normalized
            meeting.updatedAt = Date()
            didChange = true
        }
        guard didChange else { return }
        commitWrite(.list)
    }

    /// Add `tag` to every meeting in `meetings` in one save (plan LX-2 D5). Case-folded: a meeting
    /// already carrying the tag (any casing) is skipped, and the result is re-run through the canonical
    /// trim/dedupe policy. Blank tag or no change ⇒ no-op.
    func addTag(_ tag: String, to meetings: [Meeting]) {
        let trimmed = tag.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        let key = trimmed.lowercased()
        var didChange = false
        for meeting in meetings {
            guard !meeting.obsidianTags.contains(where: { $0.lowercased() == key }) else { continue }
            meeting.obsidianTags = Self.normalizedTags(meeting.obsidianTags + [trimmed])
            meeting.updatedAt = Date()
            didChange = true
        }
        guard didChange else { return }
        commitWrite(.list)
    }

    /// Remove `tag` (case-folded) from every meeting in `meetings` in one save (plan LX-2 D5). A
    /// meeting that does not carry the tag is skipped; no change ⇒ no-op.
    func removeTag(_ tag: String, from meetings: [Meeting]) {
        let key = tag.trimmingCharacters(in: .whitespaces).lowercased()
        guard !key.isEmpty else { return }
        var didChange = false
        for meeting in meetings {
            let filtered = meeting.obsidianTags.filter { $0.lowercased() != key }
            guard filtered.count != meeting.obsidianTags.count else { continue }
            meeting.obsidianTags = filtered
            meeting.updatedAt = Date()
            didChange = true
        }
        guard didChange else { return }
        commitWrite(.list)
    }
}
