import XCTest
@testable import TypeWhisper

/// [M3-Participants] The participants editor's ranked add-attendee suggestions (plan M3): directory ∪
/// linked-event calendar attendees ∪ a persistent "Create '<name>'" row, plus the add/remove paths and
/// the two-person-toggle re-appearance rule. Ranking is exercised through the pure
/// `MeetingsViewModel.rankedAttendeeSuggestions` so no view model is constructed.
@MainActor
final class ParticipantsSuggestionTests: XCTestCase {
    private typealias Suggestion = MeetingsViewModel.AttendeeSuggestion
    private typealias DirectoryCandidate = MeetingsViewModel.DirectoryCandidate

    private func makeWired() throws -> (MeetingService, ParticipantDirectoryService, URL) {
        let dir = try TestSupport.makeTemporaryDirectory()
        let meetingService = MeetingService(appSupportDirectory: dir)
        let directory = ParticipantDirectoryService(appSupportDirectory: dir)
        meetingService.onAttendeesIngested = { [weak directory] attendees in
            directory?.ingest(attendees)
        }
        return (meetingService, directory, dir)
    }

    // MARK: - Ranking

    func testRankingIncludesDirectoryCalendarAndCreateNew() {
        let result = MeetingsViewModel.rankedAttendeeSuggestions(
            query: "al",
            directory: [DirectoryCandidate(name: "Alex", email: nil)],
            calendar: [Attendee(name: "Alice", email: "alice@x.com", isSelf: false)],
            existing: []
        )
        let kinds = result.map(\.kind)
        XCTAssertTrue(kinds.contains(.calendar), "calendar candidate present")
        XCTAssertTrue(kinds.contains(.directory), "directory candidate present")
        XCTAssertEqual(result.last?.kind, .createNew, "the persistent Create-new row is appended last")
        XCTAssertEqual(result.last?.name, "al")
    }

    func testRankingExcludesRosterMembers() {
        let result = MeetingsViewModel.rankedAttendeeSuggestions(
            query: "",
            directory: [DirectoryCandidate(name: "Alex", email: "alex@x.com")],
            calendar: [Attendee(name: "Alex on calendar", email: "alex@x.com")],
            existing: [Attendee(name: "Alex", email: "alex@x.com")]
        )
        XCTAssertTrue(
            result.allSatisfy { $0.email?.lowercased() != "alex@x.com" },
            "an attendee already on the roster is never suggested (matched by email)"
        )
    }

    func testNameOnlyRosterMemberExcludesEmailCarryingCandidateForSameName() {
        // [M4 — M3 review minor] The roster carries a name-only "Alex"; an email-carrying candidate for
        // the same name must still be excluded (previously the asymmetric check let it through, and
        // picking it appended a duplicate 'Alex' row).
        let result = MeetingsViewModel.rankedAttendeeSuggestions(
            query: "",
            directory: [DirectoryCandidate(name: "Alex", email: "alex@x.com")],
            calendar: [Attendee(name: "Alex", email: "alex@x.com", isSelf: false)],
            existing: [Attendee(name: "Alex")] // name-only roster member
        )
        XCTAssertFalse(
            result.contains { $0.name.lowercased() == "alex" && $0.kind != .createNew },
            "a name-only roster 'Alex' excludes an email-carrying candidate for the same name"
        )
    }

    func testCalendarWinsDedupeAndCarriesEmailAndIsSelf() {
        let result = MeetingsViewModel.rankedAttendeeSuggestions(
            query: "",
            directory: [DirectoryCandidate(name: "Alex", email: "alex@x.com")],
            calendar: [Attendee(name: "Alex", email: "alex@x.com", isSelf: true)],
            existing: []
        )
        let alex = result.filter { $0.email == "alex@x.com" }
        XCTAssertEqual(alex.count, 1, "the calendar + directory rows for one identity collapse to one")
        XCTAssertEqual(alex.first?.kind, .calendar, "the richer calendar row wins the dedupe")
        XCTAssertEqual(alex.first?.isSelf, true, "and it carries email + isSelf through")
    }

    func testPrefixMatchesRankAheadOfSubstringMatches() {
        let result = MeetingsViewModel.rankedAttendeeSuggestions(
            query: "ann",
            directory: [
                DirectoryCandidate(name: "Joann", email: nil),   // substring
                DirectoryCandidate(name: "Anna", email: nil)     // prefix
            ],
            calendar: [],
            existing: []
        )
        let nonCreate = result.filter { $0.kind != .createNew }
        XCTAssertEqual(nonCreate.first?.name, "Anna", "prefix match sorts ahead of a substring match")
    }

    func testEmptyQueryKeepsCandidatesButOmitsCreateNew() {
        let result = MeetingsViewModel.rankedAttendeeSuggestions(
            query: "   ",
            directory: [DirectoryCandidate(name: "Alex", email: nil)],
            calendar: [],
            existing: []
        )
        XCTAssertFalse(result.isEmpty)
        XCTAssertFalse(result.contains { $0.kind == .createNew }, "no Create-new row for a blank query")
    }

    func testCreateNewSuppressedWhenQueryIsAnExactRosterName() {
        let result = MeetingsViewModel.rankedAttendeeSuggestions(
            query: "Alex",
            directory: [],
            calendar: [],
            existing: [Attendee(name: "Alex")]
        )
        XCTAssertFalse(
            result.contains { $0.kind == .createNew },
            "an exact roster name offers no Create-new row"
        )
    }

    // MARK: - Add / remove paths

    func testCalendarPickAttachesEmailAndIsSelf() throws {
        let (meetingService, _, dir) = try makeWired()
        defer { TestSupport.remove(dir) }
        let meeting = meetingService.createMeeting(title: "Ad-hoc", source: .adHoc)

        // A calendar-sourced suggestion adds via the same `attendee` payload the view model uses.
        let suggestion = Suggestion(name: "Alice", email: "alice@x.com", isSelf: true, kind: .calendar)
        XCTAssertTrue(meetingService.addAttendee(suggestion.attendee, to: meeting))

        let added = try XCTUnwrap(meeting.attendees.first)
        XCTAssertEqual(added.email, "alice@x.com")
        XCTAssertEqual(added.isSelf, true, "a calendar pick attaches email + isSelf")
    }

    func testRemoveKeepsPerson() throws {
        let (meetingService, directory, dir) = try makeWired()
        defer { TestSupport.remove(dir) }
        let meeting = meetingService.createMeeting(title: "Ad-hoc", source: .adHoc)
        let alice = Attendee(name: "Alice", email: "alice@x.com")
        meetingService.addAttendee(alice, to: meeting)
        XCTAssertEqual(directory.persons.count, 1)

        // The view model's remove path routes here; it must never delete the backing Person.
        XCTAssertTrue(meetingService.removeAttendee(alice, from: meeting))
        XCTAssertTrue(meeting.attendees.isEmpty)
        XCTAssertEqual(directory.persons.count, 1, "removing a participant never deletes the Person")
    }

    // MARK: - Two-person toggle re-appearance (plan M3 / D-A4)

    func testTwoPersonToggleReappearsWhenAttendeesEmpty() throws {
        let (meetingService, _, dir) = try makeWired()
        defer { TestSupport.remove(dir) }
        let meeting = meetingService.createMeeting(title: "Ad-hoc", source: .adHoc)

        XCTAssertTrue(
            MeetingsViewModel.showsTwoPersonToggle(for: meeting),
            "an attendee-less ad-hoc meeting offers the toggle"
        )

        let alex = Attendee(name: "Alex")
        meetingService.addAttendee(alex, to: meeting)
        XCTAssertFalse(
            MeetingsViewModel.showsTwoPersonToggle(for: meeting),
            "adding a participant hides the toggle"
        )

        meetingService.removeAttendee(alex, from: meeting)
        XCTAssertTrue(
            MeetingsViewModel.showsTwoPersonToggle(for: meeting),
            "removing the last participant restores the toggle"
        )
    }
}
