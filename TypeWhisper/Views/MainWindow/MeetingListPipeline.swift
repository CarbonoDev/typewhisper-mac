import Foundation

/// [Perf Phase 2] Everything `MeetingsViewModel.filteredMeetings` and the archive sort read from a
/// meeting, derived once per `(id, updatedAt)` (every `MeetingService` write bumps `updatedAt`).
/// Searching then tests cached strings: no attendees-JSON decode, no `segments` / `outputs` fault.
struct MeetingFilterFacts: Equatable {
    var updatedAt: Date
    /// What the search facet matches today, no more and no less: the raw title, then each
    /// attendee's name and email.
    var searchFields: [String]
    var folderComponents: [String]
    var lowercasedTags: [String]
    /// The date-range facet's day: `startDate ?? createdAt` (the Home grouping rule).
    var rangeDate: Date
    /// The archive's sort key: `startDate`, else the date in an imported export filename, else
    /// creation (`MeetingsListView.effectiveDate`).
    var sortDate: Date
    var source: MeetingSource
    var languageCode: String?
    var hasTranscript: Bool
    /// `outputs` kinds exactly as `matchesStateFacets` reads them.
    var outputKinds: Set<MeetingOutputKind>

    @MainActor
    init(_ meeting: Meeting) {
        updatedAt = meeting.updatedAt
        var fields = [meeting.title]
        for attendee in meeting.attendees {
            fields.append(attendee.name)
            if let email = attendee.email { fields.append(email) }
        }
        searchFields = fields
        folderComponents = MeetingService.folderComponents(meeting.folderPath)
        lowercasedTags = meeting.tags.map { $0.lowercased() }
        rangeDate = meeting.startDate ?? meeting.createdAt
        sortDate = MeetingsListView.effectiveDate(meeting)
        source = meeting.source
        languageCode = meeting.languageCode
        hasTranscript = !meeting.segments.isEmpty
        outputKinds = Set(meeting.outputs.map(\.kind))
    }
}

/// Every input of the meeting list's filter + sort: the coordinator's folder / tag / unfiled filter,
/// the filter-bar facets, and the archive sort order (`nil` keeps the input order, as the folder
/// detail does).
struct MeetingListQuery: Equatable {
    var folder: String?
    var tag: String?
    var unfiledOnly = false
    var searchText = ""
    var dateRange: MeetingDateRange = .all
    var stateFacets: Set<MeetingStateFacet> = []
    var sourceFacet: MeetingSourceFacet = .all
    var languageFilter: String?
    var folderFacets: Set<String> = []
    var sortNewestFirst: Bool?
}

/// [Perf Phase 2] The meeting list's filter + sort, evaluated once per input change instead of once
/// per body, shared by the archive list and the folder detail. Results equal
/// `MeetingsViewModel.filteredMeetings` (+ the archive's date sort) for every facet combination —
/// pinned by `MeetingListPipelineTests`, which runs both over the same fixtures.
///
/// The memo key reads each displayed meeting's `updatedAt`. That is also what keeps a calling view
/// current: `MeetingService` no longer republishes `meetings` for in-place writes, and SwiftUI's
/// Observation tracking of that read is how the body learns a meeting changed.
@MainActor
final class MeetingListPipeline {
    static let shared = MeetingListPipeline()

    private var facts: [UUID: MeetingFilterFacts] = [:]
    /// Number of fact derivations (cache misses) — a test probe for the invalidation key.
    private(set) var derivationCount = 0

    private struct MemoKey: Equatable {
        var entries: [Entry]
        var query: MeetingListQuery
        var calendar: Calendar
        /// Only the relative date ranges depend on the clock, and only by day.
        var day: Date?
    }

    private struct Entry: Equatable {
        var id: UUID
        var updatedAt: Date
    }

    /// A few recent results: the archive and the folder detail each keep theirs.
    private var memo: [(key: MemoKey, result: [Meeting])] = []
    private let memoLimit = 4

    func meetings(
        _ meetings: [Meeting],
        query: MeetingListQuery,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [Meeting] {
        let relative: Bool
        switch query.dateRange {
        case .today, .thisWeek, .thisMonth: relative = true
        case .all, .custom: relative = false
        }
        let key = MemoKey(
            entries: meetings.map { Entry(id: $0.id, updatedAt: $0.updatedAt) },
            query: query,
            calendar: calendar,
            day: relative ? calendar.startOfDay(for: now) : nil
        )
        if let hit = memo.firstIndex(where: { $0.key == key }) {
            let entry = memo.remove(at: hit)
            memo.append(entry)
            return entry.result
        }
        let result = Self.apply(
            meetings.map { ($0, filterFacts(for: $0)) }, query: query, now: now, calendar: calendar
        )
        memo.append((key, result))
        if memo.count > memoLimit { memo.removeFirst() }
        return result
    }

    func filterFacts(for meeting: Meeting) -> MeetingFilterFacts {
        if let cached = facts[meeting.id], cached.updatedAt == meeting.updatedAt { return cached }
        derivationCount += 1
        let derived = MeetingFilterFacts(meeting)
        facts[meeting.id] = derived
        return derived
    }

    /// The filter + sort over cached facts. Mirrors `MeetingsViewModel.filteredMeetings` step for
    /// step (vertical filter, folder facet, tag, then the AND-composed facets), then sorts.
    static func apply(
        _ rows: [(meeting: Meeting, facts: MeetingFilterFacts)],
        query: MeetingListQuery,
        now: Date,
        calendar: Calendar
    ) -> [Meeting] {
        var result = rows
        if query.unfiledOnly {
            result = result.filter { $0.facts.folderComponents.isEmpty }
        } else if let folder = query.folder {
            let prefix = MeetingService.folderComponents(folder)
            if !prefix.isEmpty {
                result = result.filter { hasPrefix($0.facts.folderComponents, prefix) }
            }
        }
        if !query.folderFacets.isEmpty {
            let prefixes = query.folderFacets.map { MeetingService.folderComponents($0) }
            result = result.filter { row in
                prefixes.contains { !$0.isEmpty && hasPrefix(row.facts.folderComponents, $0) }
            }
        }
        if let tag = query.tag, !tag.trimmingCharacters(in: .whitespaces).isEmpty {
            let key = tag.lowercased()
            result = result.filter { $0.facts.lowercasedTags.contains(key) }
        }
        let search = query.searchText.trimmingCharacters(in: .whitespaces)
        result = result.filter { row in
            let facts = row.facts
            return matchesSearch(facts, trimmedQuery: search)
                && MeetingsViewModel.withinDateRange(
                    date: facts.rangeDate, range: query.dateRange, now: now, calendar: calendar
                )
                && matchesStateFacets(facts, query.stateFacets)
                && matchesSource(facts.source, query.sourceFacet)
                && matchesLanguage(facts.languageCode, query.languageFilter)
        }
        if let newestFirst = query.sortNewestFirst {
            result.sort { newestFirst ? $0.facts.sortDate > $1.facts.sortDate : $0.facts.sortDate < $1.facts.sortDate }
        }
        return result.map(\.meeting)
    }

    private static func hasPrefix(_ components: [String], _ prefix: [String]) -> Bool {
        components.count >= prefix.count && Array(components.prefix(prefix.count)) == prefix
    }

    private static func matchesSearch(_ facts: MeetingFilterFacts, trimmedQuery: String) -> Bool {
        guard !trimmedQuery.isEmpty else { return true }
        return facts.searchFields.contains { $0.localizedCaseInsensitiveContains(trimmedQuery) }
    }

    private static func matchesStateFacets(_ facts: MeetingFilterFacts, _ facets: Set<MeetingStateFacet>) -> Bool {
        facets.allSatisfy { facet in
            switch facet {
            case .hasTranscript: return facts.hasTranscript
            case .hasSummary: return facts.outputKinds.contains(.summary)
            case .hasBrief: return facts.outputKinds.contains(.brief)
            case .hasExtended: return facts.outputKinds.contains(.extended)
            }
        }
    }

    private static func matchesSource(_ source: MeetingSource, _ facet: MeetingSourceFacet) -> Bool {
        switch facet {
        case .all: return true
        case .captured: return source == .adHoc || source == .calendar
        case .imported: return source == .importedAudio || source == .importedTranscript
        }
    }

    private static func matchesLanguage(_ languageCode: String?, _ code: String?) -> Bool {
        guard let code, !code.isEmpty else { return true }
        return languageCode?.caseInsensitiveCompare(code) == .orderedSame
    }
}
