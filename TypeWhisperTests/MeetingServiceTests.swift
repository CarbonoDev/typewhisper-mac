import XCTest
import SwiftData
@testable import TypeWhisper

@MainActor
final class MeetingServiceTests: XCTestCase {
    // MARK: - Persistence roundtrip across service instances

    func testAggregatePersistsAndRequeriesAcrossServiceInstances() throws {
        let dir = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(dir) }

        let meetingID: UUID
        do {
            let service = MeetingService(appSupportDirectory: dir)
            let meeting = service.createMeeting(
                title: "Weekly Sync",
                source: .calendar,
                state: .completed,
                startDate: Date(timeIntervalSince1970: 1_000_000),
                seriesID: "series-A",
                attendees: [
                    Attendee(name: "Marco", email: "marco@example.com"),
                    Attendee(name: "Alex", email: "alex@example.com")
                ]
            )
            meetingID = meeting.id
            service.appendStableSegments(
                [
                    TranscriptionSegment(text: "First point.", start: 0, end: 2),
                    TranscriptionSegment(text: "Second point.", start: 2, end: 4)
                ],
                to: meeting
            )
            service.addNote(to: meeting, text: "Remember to follow up.", timestampOffset: 3)
            service.addOutput(to: meeting, kind: .summary, content: "A short summary.")
            service.addQATurn(to: meeting, question: "When do we ship?", answer: "Next week.")
        }

        // Fresh service instance on the same directory must see the full aggregate.
        let reopened = MeetingService(appSupportDirectory: dir)
        XCTAssertEqual(reopened.meetings.count, 1)
        let meeting = try XCTUnwrap(reopened.meetings.first)
        XCTAssertEqual(meeting.id, meetingID)
        XCTAssertEqual(meeting.title, "Weekly Sync")
        XCTAssertEqual(meeting.source, .calendar)
        XCTAssertEqual(meeting.state, .completed)
        XCTAssertEqual(meeting.seriesID, "series-A")
        XCTAssertEqual(meeting.attendees.count, 2)
        XCTAssertEqual(Set(meeting.attendees.compactMap(\.email)), ["marco@example.com", "alex@example.com"])
        XCTAssertEqual(meeting.segments.count, 2)
        XCTAssertEqual(meeting.segments.sorted { $0.order < $1.order }.map(\.text), ["First point.", "Second point."])
        XCTAssertEqual(meeting.segments.map(\.order).sorted(), [0, 1])
        XCTAssertEqual(meeting.notes.count, 1)
        XCTAssertEqual(meeting.outputs.count, 1)
        XCTAssertEqual(meeting.outputs.first?.kind, .summary)
        XCTAssertEqual(meeting.qaTurns.count, 1)
    }

    // MARK: - Cascade delete

    func testDeleteMeetingCascadesToChildren() throws {
        let dir = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(dir) }

        // Phase 1: seed a meeting with one of every child, then release the service so the
        // store is closed before we reopen it to count rows (avoids concurrent containers).
        do {
            let service = MeetingService(appSupportDirectory: dir)
            let meeting = service.createMeeting(title: "Doomed", source: .adHoc)
            service.appendStableSegments(
                [TranscriptionSegment(text: "one", start: 0, end: 1)],
                to: meeting
            )
            service.addNote(to: meeting, text: "note")
            service.addOutput(to: meeting, kind: .summary, content: "out")
            service.addQATurn(to: meeting, question: "q", answer: "a")
        }
        XCTAssertEqual(try childCounts(in: dir), ChildCounts(segments: 1, notes: 1, outputs: 1, qaTurns: 1))

        // Phase 2: delete the meeting through a fresh service instance.
        do {
            let service = MeetingService(appSupportDirectory: dir)
            let meeting = try XCTUnwrap(service.meetings.first)
            service.deleteMeeting(meeting)
            XCTAssertTrue(service.meetings.isEmpty)
        }

        // Every child row must be gone from the store, not just the root.
        XCTAssertEqual(try childCounts(in: dir), ChildCounts(segments: 0, notes: 0, outputs: 0, qaTurns: 0))
    }

    // MARK: - priorMeetings

    func testPriorMeetingsMatchesByAttendeeEmailAndSeriesButNotOtherwise() throws {
        let dir = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(dir) }

        let service = MeetingService(appSupportDirectory: dir)
        let target = service.createMeeting(
            title: "Target",
            seriesID: "series-1",
            attendees: [Attendee(name: "Marco", email: "marco@example.com")]
        )
        let sharedAttendee = service.createMeeting(
            title: "Shared Attendee",
            seriesID: "series-other",
            attendees: [
                Attendee(name: "Marco", email: "Marco@Example.com"), // case-insensitive match
                Attendee(name: "Bob", email: "bob@example.com")
            ]
        )
        let sharedSeries = service.createMeeting(
            title: "Shared Series",
            seriesID: "series-1",
            attendees: [Attendee(name: "Dana", email: "dana@example.com")]
        )
        let unrelated = service.createMeeting(
            title: "Unrelated",
            seriesID: "series-zzz",
            attendees: [Attendee(name: "Eve", email: "eve@example.com")]
        )

        let matches = service.priorMeetings(matching: target)
        let matchIDs = Set(matches.map(\.id))

        XCTAssertTrue(matchIDs.contains(sharedAttendee.id))
        XCTAssertTrue(matchIDs.contains(sharedSeries.id))
        XCTAssertFalse(matchIDs.contains(unrelated.id))
        XCTAssertFalse(matchIDs.contains(target.id)) // never itself
        XCTAssertEqual(matches.count, 2)
    }

    // MARK: - replaceSegments

    func testReplaceSegmentsSwapsSourceAndRenumbers() throws {
        let dir = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(dir) }

        let service = MeetingService(appSupportDirectory: dir)
        let meeting = service.createMeeting(title: "Replace", source: .adHoc)
        service.appendStableSegments(
            [
                TranscriptionSegment(text: "live a", start: 0, end: 2),
                TranscriptionSegment(text: "live b", start: 2, end: 4)
            ],
            source: .liveCapture,
            to: meeting
        )

        service.replaceSegments(
            of: meeting,
            source: .liveCapture,
            with: [
                TranscriptionSegment(text: "final a", start: 0, end: 2),
                TranscriptionSegment(text: "final b", start: 2, end: 4),
                TranscriptionSegment(text: "final c", start: 4, end: 6)
            ]
        )

        let ordered = meeting.segments.sorted { $0.order < $1.order }
        XCTAssertEqual(ordered.map(\.text), ["final a", "final b", "final c"])
        XCTAssertEqual(ordered.map(\.order), [0, 1, 2])
        XCTAssertTrue(ordered.allSatisfy { $0.source == .liveCapture })
    }

    // MARK: - Helpers

    private struct ChildCounts: Equatable {
        var segments: Int
        var notes: Int
        var outputs: Int
        var qaTurns: Int
    }

    /// Open the meetings store directly (bypassing the service) to assert on raw child-row counts.
    private func childCounts(in dir: URL) throws -> ChildCounts {
        let (_, context) = try SwiftDataStoreFactory.create(
            for: [
                Meeting.self,
                MeetingSegment.self,
                MeetingNote.self,
                MeetingOutput.self,
                MeetingQATurn.self,
                MeetingTemplate.self
            ],
            storeName: "meetings",
            in: dir
        )
        return ChildCounts(
            segments: try context.fetchCount(FetchDescriptor<MeetingSegment>()),
            notes: try context.fetchCount(FetchDescriptor<MeetingNote>()),
            outputs: try context.fetchCount(FetchDescriptor<MeetingOutput>()),
            qaTurns: try context.fetchCount(FetchDescriptor<MeetingQATurn>())
        )
    }
}
