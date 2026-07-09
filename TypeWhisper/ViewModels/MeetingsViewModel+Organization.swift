import Foundation

/// First-party tag organization surface (plan D6/D8, M3). Thin MainActor pass-throughs to the
/// single-writer `MeetingService` bulk-tag mutators plus the **pure** filter/autocomplete functions
/// the coordinator-held tag filter and the document Tags chip render. Extension-file discipline: no
/// stored state is added here (the derived tag index lives on `MeetingOrganizationIndex`, which the
/// sidebar and chips observe directly).
@MainActor
extension MeetingsViewModel {
    // MARK: - Per-meeting tag editing (Tags chip)

    /// Replace a meeting's tags wholesale (the service applies the canonical trim/dedupe policy).
    func setMeetingTags(_ tags: [String], for meeting: Meeting) {
        meetingService.setObsidianTags(tags, for: meeting)
    }

    /// Add one tag to a meeting; no-op if it already carries it (case-folded).
    func addMeetingTag(_ tag: String, to meeting: Meeting) {
        let trimmed = tag.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        let existing = meeting.tags
        guard !existing.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) else { return }
        meetingService.setObsidianTags(existing + [trimmed], for: meeting)
    }

    /// Remove one tag from a meeting (case-folded match).
    func removeMeetingTag(_ tag: String, from meeting: Meeting) {
        let filtered = meeting.tags.filter { $0.caseInsensitiveCompare(tag) != .orderedSame }
        meetingService.setObsidianTags(filtered, for: meeting)
    }

    // MARK: - Bulk tag ops (sidebar context menu)

    /// Bulk-rename a tag across every meeting that carries it, in one save (plan D6).
    func renameTag(_ tag: String, to newName: String) {
        meetingService.renameTag(tag, to: newName)
    }

    /// Bulk-delete a tag across every meeting, in one save (plan D6).
    func deleteTag(_ tag: String) {
        meetingService.deleteTag(tag)
    }

    // MARK: - Filtering (plan D8; pure over `meetings` + the coordinator's active tag)

    /// Meetings carrying `tag`, by case-folded membership. Pure — `MainWindowCoordinator` holds the
    /// active filter and this projects it over a meetings snapshot.
    static func meetings(_ meetings: [Meeting], taggedWith tag: String) -> [Meeting] {
        let key = tag.lowercased()
        return meetings.filter { meeting in
            meeting.tags.contains { $0.lowercased() == key }
        }
    }

    /// Instance convenience over `self.meetings`.
    func meetings(taggedWith tag: String) -> [Meeting] {
        Self.meetings(meetings, taggedWith: tag)
    }

    // MARK: - Per-meeting folder editing (Folder chip, plan D7/M4)

    /// Set a meeting's folder path (normalized by the service). Empty/blank ⇒ Unfiled.
    func setMeetingFolder(_ path: String?, for meeting: Meeting) {
        meetingService.setFolder(path, for: meeting)
    }

    // MARK: - Bulk folder ops (sidebar context menu, plan D7)

    /// Bulk-rename a folder (its whole subtree) across every meeting under it, one save (plan D7).
    func renameFolder(_ old: String, to new: String) {
        meetingService.renameFolder(old, to: new)
    }

    /// Bulk-delete a folder: unfile every meeting at or under it, one save (plan D7).
    func deleteFolder(_ path: String) {
        meetingService.deleteFolder(path)
    }

    // MARK: - Folder filtering (plan D8; pure over `meetings` + the coordinator's active folder)

    /// Meetings at `folder` or nested under it — component-wise prefix match, so `Acme` never matches
    /// `Acme2` and a parent folder includes its descendants (plan D8). Pure; the coordinator holds the
    /// active folder and this projects it over a meetings snapshot.
    static func meetings(_ meetings: [Meeting], inFolder folder: String) -> [Meeting] {
        let prefix = MeetingService.folderComponents(folder)
        guard !prefix.isEmpty else { return meetings }
        return meetings.filter { meeting in
            let comps = MeetingService.folderComponents(meeting.folderPath)
            return comps.count >= prefix.count && Array(comps.prefix(prefix.count)) == prefix
        }
    }

    /// Instance convenience over `self.meetings`.
    func meetings(inFolder folder: String) -> [Meeting] {
        Self.meetings(meetings, inFolder: folder)
    }

    /// Meetings with **no** first-party folder (the Unfiled set). Uses the exact predicate the sidebar's
    /// count uses (`MeetingOrganizationIndex.unfiledCount`), so the row's count and this filtered list
    /// never disagree. Pure over a meetings snapshot.
    static func unfiledMeetings(_ meetings: [Meeting]) -> [Meeting] {
        meetings.filter { MeetingService.folderComponents($0.folderPath).isEmpty }
    }

    /// Compose the coordinator's vertical filter (a folder path, or `unfiledOnly` — the two are mutually
    /// exclusive) with the active tag (horizontal) — they AND together (plan D8). `nil`/`false` inputs
    /// pass through. `unfiledOnly` wins over `folder` when both are (defensively) supplied. Pure so the
    /// list view and tests share it.
    static func filteredMeetings(
        _ meetings: [Meeting],
        folder: String?,
        tag: String?,
        unfiledOnly: Bool = false
    ) -> [Meeting] {
        var result = meetings
        if unfiledOnly {
            result = Self.unfiledMeetings(result)
        } else if let folder, !MeetingService.folderComponents(folder).isEmpty {
            result = Self.meetings(result, inFolder: folder)
        }
        if let tag, !tag.trimmingCharacters(in: .whitespaces).isEmpty {
            result = Self.meetings(result, taggedWith: tag)
        }
        return result
    }

    // MARK: - Folder autocomplete (Folder chip)

    /// Existing folder paths from the derived tree (all nodes, depth-first), filtered by `query`
    /// (case-insensitive substring over the full path), bounded to `limit`. Pure over the supplied
    /// tree snapshot so the view passes `MeetingOrganizationIndex.shared.folderTree`.
    static func folderSuggestions(
        from folderTree: [MeetingFolderNode],
        query: String,
        limit: Int = 8
    ) -> [String] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        var paths: [String] = []
        func collect(_ nodes: [MeetingFolderNode]) {
            for node in nodes {
                paths.append(node.path)
                collect(node.children)
            }
        }
        collect(folderTree)
        return paths
            .filter { trimmed.isEmpty || $0.localizedCaseInsensitiveContains(trimmed) }
            .prefix(limit)
            .map { $0 }
    }

    // MARK: - Autocomplete (Tags chip)

    /// Suggestions for the Tags chip: index tag names not already on `meeting`, filtered by `query`
    /// (case-insensitive, substring), bounded to `limit`. Pure over the supplied index snapshot so it
    /// is unit-testable and the view passes `MeetingOrganizationIndex.shared.tagCounts`.
    static func tagSuggestions(
        from tagCounts: [MeetingTagCount],
        query: String,
        excluding meeting: Meeting,
        limit: Int = 8
    ) -> [String] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        let onMeeting = Set(meeting.tags.map { $0.lowercased() })
        return tagCounts
            .map(\.name)
            .filter { !onMeeting.contains($0.lowercased()) }
            .filter { trimmed.isEmpty || $0.localizedCaseInsensitiveContains(trimmed) }
            .prefix(limit)
            .map { $0 }
    }
}
