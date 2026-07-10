import XCTest
@testable import TypeWhisper

/// LX-1 — Meetings-list filter bar (plan D2/D8). Pure predicate + composition tests over the single
/// `MeetingsViewModel.filteredMeetings` choke point and its facet helpers. All meetings are detached
/// `@Model` objects with an injected calendar/now, so CI never touches a live store or clock.
@MainActor
final class MeetingListFilterTests: XCTestCase {
    /// Fixed gregorian calendar in a stable time zone so day/week/month math is deterministic.
    private var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/New_York")!
        cal.firstWeekday = 2 // Monday, so the week window is unambiguous under test.
        return cal
    }

    /// 2026-07-08 (Wednesday) 14:00 local.
    private var now: Date {
        calendar.date(from: DateComponents(year: 2026, month: 7, day: 8, hour: 14))!
    }

    private func day(_ year: Int, _ month: Int, _ dayOfMonth: Int, hour: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: dayOfMonth, hour: hour))!
    }

    private func meeting(
        _ title: String,
        start: Date? = nil,
        created: Date? = nil,
        attendees: [Attendee] = [],
        source: MeetingSource = .adHoc,
        hasTranscript: Bool = false,
        outputKinds: [MeetingOutputKind] = [],
        language: String? = nil
    ) -> Meeting {
        let m = Meeting(
            title: title,
            source: source,
            startDate: start,
            languageCode: language,
            createdAt: created ?? now
        )
        m.attendees = attendees
        // Fresh segment instances per meeting — a shared `MeetingSegment` would be reparented away by
        // the inverse to-one relationship, leaving all but the last assignee transcript-less.
        m.segments = hasTranscript ? [MeetingSegment(order: 0, start: 0, end: 1, text: "hi")] : []
        m.outputs = outputKinds.map { MeetingOutput(kind: $0, content: "x") }
        return m
    }

    private func filter(
        _ meetings: [Meeting],
        searchText: String = "",
        dateRange: MeetingDateRange = .all,
        stateFacets: Set<MeetingStateFacet> = [],
        sourceFacet: MeetingSourceFacet = .all,
        languageFilter: String? = nil,
        folder: String? = nil,
        tag: String? = nil
    ) -> [String] {
        MeetingsViewModel.filteredMeetings(
            meetings,
            folder: folder,
            tag: tag,
            searchText: searchText,
            dateRange: dateRange,
            stateFacets: stateFacets,
            sourceFacet: sourceFacet,
            languageFilter: languageFilter,
            now: now,
            calendar: calendar
        ).map(\.title)
    }

    // MARK: - No-op passthrough

    func testEmptyInputsPassEveryMeetingThrough() {
        let a = meeting("A")
        let b = meeting("B")
        XCTAssertEqual(Set(filter([a, b])), ["A", "B"])
    }

    // MARK: - Search

    func testSearchMatchesTitleAndAttendeeCaseFolded() {
        let byTitle = meeting("Quarterly Planning")
        let byAttendee = meeting("Standup", attendees: [Attendee(name: "Alice Zhang", email: "alice@acme.com")])
        let miss = meeting("Retro")

        XCTAssertEqual(filter([byTitle, byAttendee, miss], searchText: "PLANNING"), ["Quarterly Planning"])
        XCTAssertEqual(filter([byTitle, byAttendee, miss], searchText: "zhang"), ["Standup"])
        XCTAssertEqual(filter([byTitle, byAttendee, miss], searchText: "acme"), ["Standup"], "matches attendee email")
        XCTAssertTrue(filter([byTitle, byAttendee, miss], searchText: "nomatch").isEmpty)
        // Whitespace-only query is a no-op.
        XCTAssertEqual(Set(filter([byTitle, byAttendee, miss], searchText: "   ")), ["Quarterly Planning", "Standup", "Retro"])
    }

    // MARK: - Date range presets

    func testTodayBoundary() {
        let today = meeting("Today", start: day(2026, 7, 8, hour: 9))
        let yesterday = meeting("Yesterday", start: day(2026, 7, 7, hour: 23))
        XCTAssertEqual(filter([today, yesterday], dateRange: .today), ["Today"])
    }

    func testThisWeekBoundary() {
        // Week of Mon 2026-07-06 … Sun 2026-07-12 (firstWeekday = Monday).
        let inWeek = meeting("InWeek", start: day(2026, 7, 6, hour: 8))
        let lastWeek = meeting("LastWeek", start: day(2026, 7, 5, hour: 23)) // Sunday, previous week
        XCTAssertEqual(filter([inWeek, lastWeek], dateRange: .thisWeek), ["InWeek"])
    }

    func testThisMonthBoundary() {
        let inMonth = meeting("July", start: day(2026, 7, 1))
        let lastMonth = meeting("June", start: day(2026, 6, 30))
        XCTAssertEqual(filter([inMonth, lastMonth], dateRange: .thisMonth), ["July"])
    }

    func testCustomBoundsAreInclusive() {
        let start = day(2026, 7, 1, hour: 0)
        let end = day(2026, 7, 3, hour: 23)
        let onStart = meeting("OnStart", start: start)
        let onEnd = meeting("OnEnd", start: end)
        let inside = meeting("Inside", start: day(2026, 7, 2))
        let before = meeting("Before", start: start.addingTimeInterval(-1))
        let after = meeting("After", start: end.addingTimeInterval(1))

        let kept = Set(filter(
            [onStart, onEnd, inside, before, after],
            dateRange: .custom(start: start, end: end)
        ))
        XCTAssertEqual(kept, ["OnStart", "OnEnd", "Inside"], "bounds inclusive; strictly outside excluded")
    }

    func testDateRangeUsesCreatedAtWhenNoStartDate() {
        let created = meeting("NoStart", start: nil, created: day(2026, 7, 8, hour: 10))
        XCTAssertEqual(filter([created], dateRange: .today), ["NoStart"], "effective day falls back to createdAt")
    }

    // MARK: - State facets

    func testStateFacetsFromSegmentsAndOutputs() {
        let transcribed = meeting("Transcribed", hasTranscript: true)
        let summarized = meeting("Summarized", outputKinds: [.summary])
        let briefed = meeting("Briefed", outputKinds: [.brief])
        let bare = meeting("Bare")

        let all = [transcribed, summarized, briefed, bare]
        XCTAssertEqual(filter(all, stateFacets: [.hasTranscript]), ["Transcribed"])
        XCTAssertEqual(filter(all, stateFacets: [.hasSummary]), ["Summarized"])
        XCTAssertEqual(filter(all, stateFacets: [.hasBrief]), ["Briefed"])
    }

    func testStateFacetsComposeAsAnd() {
        let both = meeting("Both", hasTranscript: true, outputKinds: [.summary])
        let transcriptOnly = meeting("TranscriptOnly", hasTranscript: true)
        let summaryOnly = meeting("SummaryOnly", outputKinds: [.summary])

        XCTAssertEqual(
            filter([both, transcriptOnly, summaryOnly], stateFacets: [.hasTranscript, .hasSummary]),
            ["Both"],
            "every selected state facet must hold"
        )
    }

    // MARK: - Source facet

    func testSourceFacetCapturedVsImported() {
        let adHoc = meeting("AdHoc", source: .adHoc)
        let cal = meeting("Cal", source: .calendar)
        let importedAudio = meeting("ImportedAudio", source: .importedAudio)
        let importedTranscript = meeting("ImportedTranscript", source: .importedTranscript)
        let all = [adHoc, cal, importedAudio, importedTranscript]

        XCTAssertEqual(Set(filter(all, sourceFacet: .captured)), ["AdHoc", "Cal"])
        XCTAssertEqual(Set(filter(all, sourceFacet: .imported)), ["ImportedAudio", "ImportedTranscript"])
        XCTAssertEqual(filter(all, sourceFacet: .all).count, 4)
    }

    // MARK: - Language facet

    func testLanguageFacetIsCaseFoldedExactMatch() {
        let en = meeting("EN", language: "en")
        let de = meeting("DE", language: "de")
        let unset = meeting("Unset", language: nil)
        XCTAssertEqual(filter([en, de, unset], languageFilter: "EN"), ["EN"])
        XCTAssertTrue(filter([en, de, unset], languageFilter: nil).count == 3, "nil language is a no-op")
    }

    func testLanguageCodesPresentIsDistinctSorted() {
        let a = meeting("A", language: "de")
        let b = meeting("B", language: "EN")
        let c = meeting("C", language: "en")
        let d = meeting("D", language: nil)
        XCTAssertEqual(MeetingsViewModel.languageCodesPresent(in: [a, b, c, d]), ["de", "en"])
    }

    // MARK: - Full composition (search ∧ date ∧ state ∧ source ∧ folder ∧ tag)

    func testAllFacetsComposeAsAnd() {
        // Only this meeting satisfies every facet at once.
        let winner = meeting(
            "Acme Planning",
            start: day(2026, 7, 8, hour: 9),
            attendees: [Attendee(name: "Bob")],
            source: .adHoc,
            hasTranscript: true,
            outputKinds: [.summary]
        )
        winner.folderPath = "Clients/Acme"
        winner.tags = ["q3"]

        // Each of these fails exactly one facet.
        let wrongDate = meeting("Acme Planning old", start: day(2026, 1, 1), source: .adHoc, hasTranscript: true, outputKinds: [.summary])
        wrongDate.folderPath = "Clients/Acme"; wrongDate.tags = ["q3"]
        let wrongSource = meeting("Acme Planning imp", start: day(2026, 7, 8), source: .importedAudio, hasTranscript: true, outputKinds: [.summary])
        wrongSource.folderPath = "Clients/Acme"; wrongSource.tags = ["q3"]
        let wrongFolder = meeting("Acme Planning nf", start: day(2026, 7, 8), source: .adHoc, hasTranscript: true, outputKinds: [.summary])
        wrongFolder.folderPath = "Other"; wrongFolder.tags = ["q3"]
        let wrongTag = meeting("Acme Planning nt", start: day(2026, 7, 8), source: .adHoc, hasTranscript: true, outputKinds: [.summary])
        wrongTag.folderPath = "Clients/Acme"; wrongTag.tags = ["misc"]
        let wrongSearch = meeting("Other Planning", start: day(2026, 7, 8), source: .adHoc, hasTranscript: true, outputKinds: [.summary])
        wrongSearch.folderPath = "Clients/Acme"; wrongSearch.tags = ["q3"]

        let result = filter(
            [winner, wrongDate, wrongSource, wrongFolder, wrongTag, wrongSearch],
            searchText: "acme",
            dateRange: .thisWeek,
            stateFacets: [.hasTranscript, .hasSummary],
            sourceFacet: .captured,
            folder: "Clients/Acme",
            tag: "q3"
        )
        XCTAssertEqual(result, ["Acme Planning"], "only the meeting matching every facet survives")
    }
}
