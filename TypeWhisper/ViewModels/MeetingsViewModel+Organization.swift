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
