import XCTest
@testable import TypeWhisper

/// `CalendarMeetingReconciler` + `MeetingService.applyCalendarReconciliation`: a `.scheduled`
/// meeting linked to a calendar event follows the event when it is rescheduled (Google instance ids
/// keep the original start, so the link survives the move); engaged meetings never do.
@MainActor
final class CalendarMeetingReconcilerTests: XCTestCase {
    private let eventID = "google:acct:weeklyseries0001_20261006T230000Z"
    private let yesterday = Date(timeIntervalSince1970: 1_791_327_600) // 2026-10-06 23:00Z
    private var today: Date { yesterday.addingTimeInterval(24 * 3600) }

    private func makeStore() throws -> MeetingService {
        let dir = try TestSupport.makeTemporaryDirectory(prefix: "CalendarMeetingReconciler")
        addTeardownBlock { TestSupport.remove(dir) }
        return MeetingService(appSupportDirectory: dir)
    }

    private func makeMeeting(
        in store: MeetingService,
        title: String = "Weekly",
        state: MeetingState = .scheduled,
        start: Date? = nil,
        eventID: String? = nil
    ) -> Meeting {
        let start = start ?? yesterday
        return store.createMeeting(
            title: title,
            source: .calendar,
            state: state,
            startDate: start,
            endDate: start.addingTimeInterval(3600),
            calendarEventID: eventID ?? self.eventID
        )
    }

    private func event(title: String = "Weekly", start: Date, notes: String? = nil, url: String? = nil) -> CalendarEventDTO {
        CalendarEventDTO(
            id: eventID,
            title: title,
            startDate: start,
            endDate: start.addingTimeInterval(3600),
            eventNotes: notes,
            conferencingURL: url
        )
    }

    private func reconcile(_ store: MeetingService, _ events: [CalendarEventDTO], previousTitles: [String: String] = [:]) {
        store.applyCalendarReconciliation(
            CalendarMeetingReconciler.changes(meetings: store.meetings, events: events, previousTitles: previousTitles)
        )
    }

    func testMovedEventUpdatesScheduledMeetingDates() throws {
        let store = try makeStore()
        let meeting = makeMeeting(in: store)

        reconcile(store, [event(start: today, notes: "Agenda", url: "https://meet.google.com/abc")])

        XCTAssertEqual(meeting.startDate, today)
        XCTAssertEqual(meeting.endDate, today.addingTimeInterval(3600))
        XCTAssertEqual(meeting.calendarNotes, "Agenda")
        XCTAssertEqual(meeting.conferencingURL, "https://meet.google.com/abc")
        XCTAssertEqual(store.meetings.count, 1, "reconciling never creates or drops meetings")
    }

    func testMovedMeetingIsResortedInPublishedList() throws {
        let store = try makeStore()
        let moved = makeMeeting(in: store)
        let other = makeMeeting(in: store, title: "Other", start: yesterday.addingTimeInterval(3600), eventID: "other")
        XCTAssertEqual(store.meetings.map(\.id), [other.id, moved.id])

        reconcile(store, [event(start: today)])

        XCTAssertEqual(store.meetings.map(\.id), [moved.id, other.id], "a moved startDate re-sorts the list")
    }

    func testEngagedMeetingIsUntouched() throws {
        let store = try makeStore()
        let ended = makeMeeting(in: store, state: .completed)
        XCTAssertTrue(CalendarMeetingReconciler.changes(meetings: [ended], events: [event(start: today)]).isEmpty)

        let withNote = makeMeeting(in: store, eventID: "noted")
        store.addNote(to: withNote, text: "prep")
        let movedNoted = CalendarEventDTO(id: "noted", title: "Weekly", startDate: today, endDate: today.addingTimeInterval(3600))
        XCTAssertTrue(CalendarMeetingReconciler.changes(meetings: [withNote], events: [movedNoted]).isEmpty)

        reconcile(store, [event(start: today), movedNoted])
        XCTAssertEqual(ended.startDate, yesterday)
        XCTAssertEqual(withNote.startDate, yesterday)
    }

    func testRenamedMeetingKeepsItsTitle() throws {
        let store = try makeStore()
        let meeting = makeMeeting(in: store, title: "My own name")

        reconcile(store, [event(title: "Weekly v2", start: today)], previousTitles: [eventID: "Weekly"])

        XCTAssertEqual(meeting.title, "My own name")
        XCTAssertEqual(meeting.startDate, today)
    }

    func testUnrenamedMeetingFollowsEventTitle() throws {
        let store = try makeStore()
        let meeting = makeMeeting(in: store, title: "Weekly")

        let changes = CalendarMeetingReconciler.changes(
            meetings: store.meetings,
            events: [event(title: "Weekly v2", start: yesterday)],
            previousTitles: [eventID: "Weekly"]
        )
        XCTAssertEqual(changes, [.init(meetingID: meeting.id, title: "Weekly v2")])

        // No previous projection known (first pass after launch): the title is left alone.
        XCTAssertTrue(
            CalendarMeetingReconciler.changes(meetings: store.meetings, events: [event(title: "Weekly v2", start: yesterday)]).isEmpty
        )
    }

    func testUnchangedEventWritesNothing() throws {
        let store = try makeStore()
        let meeting = makeMeeting(in: store)
        let updatedAt = meeting.updatedAt

        let changes = CalendarMeetingReconciler.changes(meetings: store.meetings, events: [event(start: yesterday)])
        XCTAssertTrue(changes.isEmpty)
        store.applyCalendarReconciliation(changes)
        XCTAssertEqual(meeting.updatedAt, updatedAt)
    }

    func testMeetingWithoutMatchingEventIsUntouched() throws {
        let store = try makeStore()
        let meeting = makeMeeting(in: store, eventID: "gone")

        reconcile(store, [event(start: today)])

        XCTAssertEqual(meeting.startDate, yesterday)
    }

    func testNilEventNotesDoNotEraseSnapshot() throws {
        let store = try makeStore()
        let meeting = makeMeeting(in: store)
        store.applyCalendarReconciliation([.init(meetingID: meeting.id, calendarNotes: "kept")])

        reconcile(store, [event(start: today, notes: nil)])

        XCTAssertEqual(meeting.calendarNotes, "kept")
        XCTAssertEqual(meeting.startDate, today)
    }

    func testSyncTracksTitlesAcrossPasses() throws {
        let store = try makeStore()
        let meeting = makeMeeting(in: store, title: "Weekly")
        let sync = LinkedMeetingCalendarSync(meetingService: store)

        sync.reconcile([event(title: "Weekly", start: yesterday)])
        sync.reconcile([event(title: "Weekly (moved)", start: today)])

        XCTAssertEqual(meeting.title, "Weekly (moved)")
        XCTAssertEqual(meeting.startDate, today)
    }
}
