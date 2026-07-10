import Foundation

// MARK: - Filter-bar facet value types (plan LX-1, D2)

/// A date-range preset for the meetings filter bar (plan LX-1, D2). Pure value resolved against a
/// fixed `now` by `MeetingsViewModel.withinDateRange`, so every boundary is unit-testable. A meeting's
/// day is its `startDate ?? createdAt` "effective day" (the same rule the Home day grouping uses).
enum MeetingDateRange: Equatable, Sendable {
    case all
    case today
    case thisWeek
    case thisMonth
    /// Inclusive `[start, end]` bounds; the view constructs sensible day-aligned bounds.
    case custom(start: Date, end: Date)
}

/// A meeting "state" filter facet (plan LX-1, D2): the presence of a transcript / summary / brief /
/// extended output. Selected facets compose as an AND set — every one must hold. Derives from the same
/// facts as `homeBadgeFacts` (`segments` for transcript, `outputs` kinds for the rest).
enum MeetingStateFacet: String, CaseIterable, Sendable {
    case hasTranscript
    case hasSummary
    case hasBrief
    case hasExtended
}

/// Origin facet (plan LX-1, D2): captured (ad-hoc / calendar) vs imported (audio / transcript). A
/// three-value control (`all` = no filter).
enum MeetingSourceFacet: String, CaseIterable, Sendable {
    case all
    case captured
    case imported
}

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
    /// exclusive) with the active tag (horizontal) and the LX-1 filter-bar facets (search / date-range /
    /// state / source / language) — every facet ANDs together (plan D8/LX-1). `nil`/`false`/empty inputs
    /// pass through, so the pre-LX-1 call sites (folder + tag + unfiled only) behave unchanged. Pure and
    /// the single choke point the list view, folder detail, and tests all share. `now`/`calendar` are
    /// injectable so date-range boundaries are deterministic under test.
    static func filteredMeetings(
        _ meetings: [Meeting],
        folder: String?,
        tag: String?,
        unfiledOnly: Bool = false,
        searchText: String = "",
        dateRange: MeetingDateRange = .all,
        stateFacets: Set<MeetingStateFacet> = [],
        sourceFacet: MeetingSourceFacet = .all,
        languageFilter: String? = nil,
        now: Date = Date(),
        calendar: Calendar = .current
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
        return result.filter { meeting in
            Self.matchesSearch(meeting, query: searchText)
                && Self.withinDateRange(meeting, range: dateRange, now: now, calendar: calendar)
                && Self.matchesStateFacets(meeting, facets: stateFacets)
                && Self.matchesSource(meeting, facet: sourceFacet)
                && Self.matchesLanguage(meeting, code: languageFilter)
        }
    }

    // MARK: - Pure filter-bar facet predicates (plan LX-1, D2)

    /// Case-folded substring over the meeting's title and its attendees (name + email). Empty/blank
    /// query passes every meeting through (a no-op facet). Mirrors History's `searchQuery` behavior.
    static func matchesSearch(_ meeting: Meeting, query: String) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return true }
        if meeting.title.localizedCaseInsensitiveContains(trimmed) { return true }
        return meeting.attendees.contains { attendee in
            attendee.name.localizedCaseInsensitiveContains(trimmed)
                || (attendee.email?.localizedCaseInsensitiveContains(trimmed) ?? false)
        }
    }

    /// Whether the meeting's effective day (`startDate ?? createdAt`, the Home grouping rule) falls in
    /// `range`. `.all` passes through; `.custom` bounds are inclusive.
    static func withinDateRange(
        _ meeting: Meeting,
        range: MeetingDateRange,
        now: Date,
        calendar: Calendar = .current
    ) -> Bool {
        let effective = meeting.startDate ?? meeting.createdAt
        switch range {
        case .all:
            return true
        case .today:
            return calendar.isDate(effective, inSameDayAs: now)
        case .thisWeek:
            return calendar.isDate(effective, equalTo: now, toGranularity: .weekOfYear)
        case .thisMonth:
            return calendar.isDate(effective, equalTo: now, toGranularity: .month)
        case let .custom(start, end):
            return effective >= start && effective <= end
        }
    }

    /// AND-composed state facets: every selected facet must hold. Empty set is a no-op. Transcript is
    /// `!segments.isEmpty`; summary/brief/extended read the meeting's `outputs` kinds (same facts as
    /// `homeBadgeFacts`).
    static func matchesStateFacets(_ meeting: Meeting, facets: Set<MeetingStateFacet>) -> Bool {
        guard !facets.isEmpty else { return true }
        let kinds = Set(meeting.outputs.map(\.kind))
        for facet in facets {
            switch facet {
            case .hasTranscript:
                if meeting.segments.isEmpty { return false }
            case .hasSummary:
                if !kinds.contains(.summary) { return false }
            case .hasBrief:
                if !kinds.contains(.brief) { return false }
            case .hasExtended:
                if !kinds.contains(.extended) { return false }
            }
        }
        return true
    }

    /// Source origin facet: `.all` passes through; `.captured` = ad-hoc/calendar; `.imported` =
    /// imported audio/transcript.
    static func matchesSource(_ meeting: Meeting, facet: MeetingSourceFacet) -> Bool {
        switch facet {
        case .all:
            return true
        case .captured:
            return meeting.source == .adHoc || meeting.source == .calendar
        case .imported:
            return meeting.source == .importedAudio || meeting.source == .importedTranscript
        }
    }

    /// Language facet (plan LX-1 stretch): case-folded exact match on `languageCode`. `nil`/empty code
    /// passes through.
    static func matchesLanguage(_ meeting: Meeting, code: String?) -> Bool {
        guard let code, !code.isEmpty else { return true }
        return meeting.languageCode?.caseInsensitiveCompare(code) == .orderedSame
    }

    /// Distinct, sorted language codes present across `meetings` (drives the filter bar's language menu).
    static func languageCodesPresent(in meetings: [Meeting]) -> [String] {
        var seen = Set<String>()
        var codes: [String] = []
        for meeting in meetings {
            guard let code = meeting.languageCode, !code.isEmpty else { continue }
            let key = code.lowercased()
            if seen.insert(key).inserted { codes.append(key) }
        }
        return codes.sorted()
    }

    // MARK: - Selection normalization (plan LX-1, D3; mirrors HistoryViewModel)

    /// Keep only the still-visible selected IDs when the filtered set changes, dropping hidden ones
    /// (History's "normalize, don't nuke" position). Pure so the view applies it on
    /// `.onChange(of:)` and tests drive it without SwiftUI.
    static func normalizedSelection(_ selection: Set<UUID>, toVisibleIDs visibleIDs: [UUID]) -> Set<UUID> {
        selection.intersection(visibleIDs)
    }

    // MARK: - Selection gesture math (plan LX-1, D3; hand-rolled MeetingTimelineList rows)

    /// Pure ⌘/⇧-click selection math over a flattened, day-ordered id list. The hand-rolled
    /// `MeetingTimelineList` (and the folder detail via it) drive their selection through this so both
    /// surfaces behave identically; the math is unit-tested without SwiftUI.
    enum SelectionGesture {
        /// The three click kinds the row recognizes (plan D3): plain click replaces, ⌘-click toggles,
        /// ⇧-click extends a contiguous range.
        enum Click {
            case replace
            case toggle
            case range
        }

        /// Apply a `click` on `id` against the current `selection`, the range `anchor` (the last
        /// replace/toggle target), and the flattened visible `orderedIDs`. Returns the new selection and
        /// new anchor. A ⇧-click with no valid anchor degrades to a replace.
        static func apply(
            click: Click,
            on id: UUID,
            selection: Set<UUID>,
            anchor: UUID?,
            orderedIDs: [UUID]
        ) -> (selection: Set<UUID>, anchor: UUID?) {
            switch click {
            case .replace:
                return ([id], id)
            case .toggle:
                var updated = selection
                if updated.contains(id) {
                    updated.remove(id)
                } else {
                    updated.insert(id)
                }
                return (updated, id)
            case .range:
                guard let anchor,
                      let anchorIndex = orderedIDs.firstIndex(of: anchor),
                      let clickIndex = orderedIDs.firstIndex(of: id) else {
                    return ([id], id)
                }
                let lower = min(anchorIndex, clickIndex)
                let upper = max(anchorIndex, clickIndex)
                let span = orderedIDs[lower...upper]
                // Extend (union) so a prior ⌘-click multi-selection is preserved; anchor is unchanged so
                // repeated ⇧-clicks re-extend from the same origin.
                return (selection.union(span), anchor)
            }
        }

        /// ⌘-A: select every visible id.
        static func selectAll(_ orderedIDs: [UUID]) -> Set<UUID> {
            Set(orderedIDs)
        }
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
