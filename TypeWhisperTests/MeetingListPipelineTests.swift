import XCTest
@testable import TypeWhisper

/// [Perf Phase 2] `MeetingListPipeline` must return exactly what `MeetingsViewModel.filteredMeetings`
/// (+ the archive's effective-date sort) returns, for every facet combination. Each test runs the old
/// predicate and the new one over the same fixtures and compares ids in order.
@MainActor
final class MeetingListPipelineTests: XCTestCase {
    private var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/New_York")!
        cal.firstWeekday = 2
        return cal
    }

    /// 2026-07-08 (Wednesday) 14:00 local.
    private var now: Date { day(2026, 7, 8, hour: 14) }

    private func day(_ y: Int, _ m: Int, _ d: Int, hour: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: hour))!
    }

    private func meeting(
        _ title: String,
        start: Date? = nil,
        created: Date? = nil,
        attendees: [Attendee] = [],
        source: MeetingSource = .adHoc,
        folder: String? = nil,
        tags: [String] = [],
        language: String? = nil,
        transcript: Bool = false,
        outputs: [MeetingOutputKind] = []
    ) -> Meeting {
        let m = Meeting(
            title: title,
            source: source,
            startDate: start,
            languageCode: language,
            obsidianFolder: folder,
            createdAt: created ?? day(2026, 1, 1)
        )
        m.attendees = attendees
        m.tags = tags
        m.segments = transcript ? [MeetingSegment(order: 0, start: 0, end: 1, text: "hi")] : []
        m.outputs = outputs.map { MeetingOutput(kind: $0, content: "x") }
        return m
    }

    private lazy var fixtures: [Meeting] = [
        meeting("Revisión BI", start: day(2026, 7, 8, hour: 9),
                attendees: [Attendee(name: "Ána López", email: "ana@acme.io")],
                folder: "Clients/Acme", tags: ["Hiring"], language: "es", transcript: true, outputs: [.summary]),
        meeting("REVIEW of Q3 budget", start: day(2026, 7, 6), folder: "Clients/Acme/Q3",
                tags: ["finance", "hiring"], language: "EN", outputs: [.brief, .extended]),
        meeting("Q3 budget review", start: day(2026, 7, 6), folder: "Clients/Acme2", language: "en",
                transcript: true),
        meeting("Weekly sync - 2026_07_07 16_29 CST - Notes by Gemini", source: .importedTranscript,
                folder: "  ", tags: ["Ops"], transcript: true, outputs: [.summary, .extended]),
        meeting("Standup", created: day(2026, 7, 8, hour: 8),
                attendees: [Attendee(name: "Bob", email: nil), Attendee(name: "Ñandú Pérez", email: "n@x.org")]),
        meeting("Standup", start: day(2026, 6, 30), source: .calendar, folder: "Internal", tags: ["ops"]),
        meeting("Planning (2)", start: day(2025, 12, 31), source: .importedAudio, folder: "Internal/Team",
                language: "de", outputs: [.brief]),
        meeting("café chat", start: day(2026, 7, 1), attendees: [Attendee(name: "Zoë", email: "zoe@café.fr")],
                folder: "Clients/Globex", tags: ["Hiring", "social"]),
        meeting("Untitled", start: day(2026, 7, 6)),
        meeting("ÉQUIPE weekly", created: day(2026, 7, 10), source: .calendar, language: "fr", transcript: true),
    ]

    private func reference(_ meetings: [Meeting], _ q: MeetingListQuery) -> [UUID] {
        let filtered = MeetingsViewModel.filteredMeetings(
            meetings,
            folder: q.folder,
            tag: q.tag,
            unfiledOnly: q.unfiledOnly,
            searchText: q.searchText,
            dateRange: q.dateRange,
            stateFacets: q.stateFacets,
            sourceFacet: q.sourceFacet,
            languageFilter: q.languageFilter,
            folderFacets: q.folderFacets,
            now: now,
            calendar: calendar
        )
        guard let newestFirst = q.sortNewestFirst else { return filtered.map(\.id) }
        return filtered.sorted {
            let a = MeetingsListView.effectiveDate($0)
            let b = MeetingsListView.effectiveDate($1)
            return newestFirst ? a > b : a < b
        }.map(\.id)
    }

    private func assertParity(_ q: MeetingListQuery, pipeline: MeetingListPipeline = MeetingListPipeline(),
                              line: UInt = #line) {
        let new = pipeline.meetings(fixtures, query: q, now: now, calendar: calendar).map(\.id)
        XCTAssertEqual(new, reference(fixtures, q), "query \(q)", line: line)
    }

    // MARK: - Facet-by-facet

    private let searches = [
        "", "   ", "rev", "Revisión", "revision", "REVISIÓN", "q3 budget", "budget q3", "Q3 BUDGET REVIEW",
        "ana", "ána", "Ána López", "@acme.io", "ACME", "bob", "ñandú", "nandu", "zoe@café", "café",
        "CAFE", "équipe", "equipe", "notes by gemini", "Weekly sync", " standup ", "(2)", "zzz",
    ]
    private var dateRanges: [MeetingDateRange] {
        [.all, .today, .thisWeek, .thisMonth, .custom(start: day(2026, 7, 1), end: day(2026, 7, 6))]
    }
    private let facetSets: [Set<MeetingStateFacet>] = [
        [], [.hasTranscript], [.hasSummary], [.hasBrief], [.hasExtended], [.hasSummary, .hasExtended],
        [.hasTranscript, .hasSummary],
    ]
    private let languages: [String?] = [nil, "", "ES", "en", "xx"]
    private let folders: [String?] = [nil, "", "Clients/Acme", "clients/acme", "Internal", " Clients / Acme "]
    private let tags: [String?] = [nil, " ", "Hiring", "OPS", "missing"]
    private let folderFacetSets: [Set<String>] = [[], ["Clients/Acme"], ["Clients/Acme2", "Internal"], [""]]
    private let sorts: [Bool?] = [nil, true, false]

    func testEachFacetMatchesTheReference() {
        for s in searches { assertParity(MeetingListQuery(searchText: s)) }
        for r in dateRanges { assertParity(MeetingListQuery(dateRange: r)) }
        for f in facetSets { assertParity(MeetingListQuery(stateFacets: f)) }
        for src in MeetingSourceFacet.allCases { assertParity(MeetingListQuery(sourceFacet: src)) }
        for l in languages { assertParity(MeetingListQuery(languageFilter: l)) }
        for f in folders { assertParity(MeetingListQuery(folder: f)) }
        for t in tags { assertParity(MeetingListQuery(tag: t)) }
        for ff in folderFacetSets { assertParity(MeetingListQuery(folderFacets: ff)) }
        for sort in sorts { assertParity(MeetingListQuery(sortNewestFirst: sort)) }
        assertParity(MeetingListQuery(folder: "Clients/Acme", unfiledOnly: true))
        assertParity(MeetingListQuery(tag: "ops", unfiledOnly: true))
    }

    /// A deterministic sample of full combinations (every facet set at once), through one shared
    /// pipeline so memo hits and misses interleave the way they do in the app.
    func testRandomFacetCombinationsMatchTheReference() {
        var rng = SeededGenerator(seed: 0x5EED)
        let pipeline = MeetingListPipeline()
        var resultSizes = Set<Int>()
        for _ in 0..<1500 {
            // Each facet stays at its no-op value (index 0) most of the time, so combinations of a
            // few active facets — the realistic case — dominate instead of all-facets-empty results.
            func pick<T>(_ options: [T]) -> T {
                Int.random(in: 0..<3, using: &rng) == 0
                    ? options.randomElement(using: &rng)!
                    : options[0]
            }
            let q = MeetingListQuery(
                folder: pick(folders),
                tag: pick(tags),
                unfiledOnly: Int.random(in: 0..<8, using: &rng) == 0,
                searchText: pick(searches),
                dateRange: pick(dateRanges),
                stateFacets: pick(facetSets),
                sourceFacet: pick(MeetingSourceFacet.allCases),
                languageFilter: pick(languages),
                folderFacets: pick(folderFacetSets),
                sortNewestFirst: sorts.randomElement(using: &rng)!
            )
            assertParity(q, pipeline: pipeline)
            resultSizes.insert(reference(fixtures, q).count)
        }
        XCTAssertGreaterThanOrEqual(resultSizes.count, 4, "the sample must exercise non-trivial results")
    }

    func testSearchFixturesAreNotVacuous() {
        // Attendee-only, email-only and multi-word title matches each hit something.
        for query in ["Ána López", "@acme.io", "q3 budget", "ñandú"] {
            XCTAssertFalse(reference(fixtures, MeetingListQuery(searchText: query)).isEmpty, query)
        }
    }

    // MARK: - Memo and invalidation

    func testFactsAreDerivedOncePerUpdatedAt() {
        let pipeline = MeetingListPipeline()
        let meetings = fixtures
        _ = pipeline.meetings(meetings, query: MeetingListQuery(searchText: "a"), now: now, calendar: calendar)
        _ = pipeline.meetings(meetings, query: MeetingListQuery(searchText: "ab"), now: now, calendar: calendar)
        _ = pipeline.meetings(meetings, query: MeetingListQuery(searchText: "abc"), now: now, calendar: calendar)
        XCTAssertEqual(pipeline.derivationCount, meetings.count, "typing re-filters cached facts only")
    }

    func testAnInPlaceWriteIsSeenThroughUpdatedAt() {
        let pipeline = MeetingListPipeline()
        let target = meeting("Kickoff", updatedAtSeconds: 1)
        let query = MeetingListQuery(searchText: "retro")
        XCTAssertTrue(pipeline.meetings([target], query: query, now: now, calendar: calendar).isEmpty)

        // What `MeetingService.setTitle` does: an in-place write (no `meetings` republish) that bumps
        // `updatedAt`.
        target.title = "Retro"
        target.updatedAt = Date(timeIntervalSince1970: 2)
        XCTAssertEqual(pipeline.meetings([target], query: query, now: now, calendar: calendar).map(\.id), [target.id])
    }

    func testRelativeDateRangesFollowTheClock() {
        let pipeline = MeetingListPipeline()
        let today = meeting("Today", start: now)
        let query = MeetingListQuery(dateRange: .today)
        XCTAssertEqual(pipeline.meetings([today], query: query, now: now, calendar: calendar).count, 1)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: now)!
        XCTAssertTrue(pipeline.meetings([today], query: query, now: tomorrow, calendar: calendar).isEmpty)
    }

    private func meeting(_ title: String, updatedAtSeconds: TimeInterval) -> Meeting {
        Meeting(title: title, updatedAt: Date(timeIntervalSince1970: updatedAtSeconds))
    }
}

/// SplitMix64 — a tiny deterministic generator so the sampled combinations are reproducible.
private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
