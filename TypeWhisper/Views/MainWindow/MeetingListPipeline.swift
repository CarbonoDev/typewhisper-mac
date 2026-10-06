import Foundation

/// [Perf Phase 2] The scalar facts `MeetingsViewModel.filteredMeetings` and the archive sort read from
/// a meeting, derived once per `(id, updatedAt)` (every `MeetingService` write bumps `updatedAt`).
/// Searching then tests cached strings with no attendees-JSON decode. Deliberately no relationship
/// reads: transcript / output facts are derived lazily by `MeetingListPipeline`, only while a state
/// facet needs them.
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
    private typealias Stamp = MeetingRelationshipFacts.ColumnStamp
    private var transcriptFacts: [UUID: (updatedAt: Date, columns: Stamp, value: Bool)] = [:]
    private var outputKindFacts: [UUID: (updatedAt: Date, columns: Stamp, value: Set<MeetingOutputKind>)] = [:]

    /// Derivation counts (cache misses) by kind — test probes for the invalidation key and for
    /// laziness: an unfiltered or search-only query must not derive any relationship fact.
    struct DerivationCounts: Equatable {
        var scalar = 0
        var transcript = 0
        var outputKinds = 0
    }
    private(set) var derivations = DerivationCounts()

    private struct MemoKey: Equatable {
        var query: MeetingListQuery
        var calendar: Calendar
        /// Only the relative date ranges depend on the clock, and only by day.
        var day: Date?
    }

    /// A cached result. It keeps its input meetings so the hit test compares object identity as well
    /// as `(id, updatedAt)`: a meeting deleted and re-created with the same id and timestamp (backup
    /// restore) is a different object and misses. Holding the inputs also keeps their identities
    /// from being reused while the entry lives.
    private struct MemoEntry {
        var key: MemoKey
        var inputs: [Meeting]
        var updatedAts: [Date]
        /// The inputs' fact-column stamps, recorded only when a state facet is active (the only
        /// time the result depends on transcript / output facts, whose columns change without an
        /// `updatedAt` bump).
        var columnStamps: [Stamp]?
        var result: [Meeting]

        @MainActor func matches(_ meetings: [Meeting], key other: MemoKey) -> Bool {
            guard key == other, inputs.count == meetings.count else { return false }
            for index in meetings.indices {
                let meeting = meetings[index]
                // Reading `updatedAt` of every input on a hit is also what keeps the calling view
                // observing each meeting (see the type comment).
                guard meeting === inputs[index], meeting.updatedAt == updatedAts[index] else { return false }
                if let columnStamps, MeetingRelationshipFacts.columnStamp(meeting) != columnStamps[index] {
                    return false
                }
            }
            return true
        }
    }

    /// A few recent results: the archive and the folder detail each keep theirs.
    private var memo: [MemoEntry] = []
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
        let key = MemoKey(query: query, calendar: calendar, day: relative ? calendar.startOfDay(for: now) : nil)
        if let hit = memo.firstIndex(where: { $0.matches(meetings, key: key) }) {
            let entry = memo.remove(at: hit)
            memo.append(entry)
            return entry.result
        }
        let result = apply(
            meetings.map { ($0, filterFacts(for: $0)) }, query: query, now: now, calendar: calendar
        )
        memo.append(MemoEntry(
            key: key,
            inputs: meetings,
            updatedAts: meetings.map(\.updatedAt),
            columnStamps: query.stateFacets.isEmpty ? nil : meetings.map(MeetingRelationshipFacts.columnStamp),
            result: result
        ))
        if memo.count > memoLimit { memo.removeFirst() }
        return result
    }

    func filterFacts(for meeting: Meeting) -> MeetingFilterFacts {
        if let cached = facts[meeting.id], cached.updatedAt == meeting.updatedAt { return cached }
        derivations.scalar += 1
        let derived = MeetingFilterFacts(meeting)
        facts[meeting.id] = derived
        return derived
    }

    /// Lazily derived through the seam, cached per `(id, updatedAt)` + the fact-column stamp.
    private func hasTranscript(_ meeting: Meeting) -> Bool {
        let columns = MeetingRelationshipFacts.columnStamp(meeting)
        if let cached = transcriptFacts[meeting.id], cached.updatedAt == meeting.updatedAt, cached.columns == columns {
            return cached.value
        }
        derivations.transcript += 1
        let value = MeetingRelationshipFacts.hasTranscript(meeting)
        transcriptFacts[meeting.id] = (meeting.updatedAt, columns, value)
        return value
    }

    /// Lazily derived through the seam, cached per `(id, updatedAt)` + the fact-column stamp.
    private func outputKinds(_ meeting: Meeting) -> Set<MeetingOutputKind> {
        let columns = MeetingRelationshipFacts.columnStamp(meeting)
        if let cached = outputKindFacts[meeting.id], cached.updatedAt == meeting.updatedAt, cached.columns == columns {
            return cached.value
        }
        derivations.outputKinds += 1
        let value = MeetingRelationshipFacts.outputKinds(meeting)
        outputKindFacts[meeting.id] = (meeting.updatedAt, columns, value)
        return value
    }

    /// The filter + sort over cached facts. Mirrors `MeetingsViewModel.filteredMeetings` step for
    /// step (vertical filter, folder facet, tag, then the AND-composed facets, short-circuiting in
    /// the same order — so relationship facts are only derived for meetings that reach the state
    /// facet check), then sorts.
    private func apply(
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
                result = result.filter { Self.hasPrefix($0.facts.folderComponents, prefix) }
            }
        }
        if !query.folderFacets.isEmpty {
            let prefixes = query.folderFacets.map { MeetingService.folderComponents($0) }
            result = result.filter { row in
                prefixes.contains { !$0.isEmpty && Self.hasPrefix(row.facts.folderComponents, $0) }
            }
        }
        if let tag = query.tag, !tag.trimmingCharacters(in: .whitespaces).isEmpty {
            let key = tag.lowercased()
            result = result.filter { $0.facts.lowercasedTags.contains(key) }
        }
        let search = query.searchText.trimmingCharacters(in: .whitespaces)
        result = result.filter { row in
            let facts = row.facts
            return Self.matchesSearch(facts, trimmedQuery: search)
                && MeetingsViewModel.withinDateRange(
                    date: facts.rangeDate, range: query.dateRange, now: now, calendar: calendar
                )
                && matchesStateFacets(row.meeting, query.stateFacets)
                && Self.matchesSource(facts.source, query.sourceFacet)
                && Self.matchesLanguage(facts.languageCode, query.languageFilter)
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

    /// Each relationship fact is derived only when a selected facet needs it (no facets: none).
    private func matchesStateFacets(_ meeting: Meeting, _ facets: Set<MeetingStateFacet>) -> Bool {
        facets.allSatisfy { facet in
            switch facet {
            case .hasTranscript: return hasTranscript(meeting)
            case .hasSummary: return outputKinds(meeting).contains(.summary)
            case .hasBrief: return outputKinds(meeting).contains(.brief)
            case .hasExtended: return outputKinds(meeting).contains(.extended)
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
