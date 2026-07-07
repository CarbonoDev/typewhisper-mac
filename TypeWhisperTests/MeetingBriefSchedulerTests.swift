import XCTest
@testable import TypeWhisper

/// Unit tests for the automatic pre-meeting brief scheduler (plan AD9). The store is a real
/// in-memory `MeetingService` (temp directory); brief generation is stubbed so no LLM is touched.
/// A fake `now` drives the lead-window logic; config comes from an isolated `UserDefaults` suite.
@MainActor
final class MeetingBriefSchedulerTests: XCTestCase {
    // MARK: - Stub brief generator

    @MainActor
    private final class StubBriefGenerator: MeetingBriefGenerating {
        private let store: MeetingService
        private(set) var calls: [UUID] = []
        private(set) var maxConcurrent = 0
        private var active = 0
        var errorToThrow: Error?
        /// When true, a successful call persists a real `.brief` so freshness dedupe reflects it.
        var addsBriefOnSuccess = true

        init(store: MeetingService) { self.store = store }

        @discardableResult
        func generateBrief(for meeting: Meeting) async throws -> MeetingOutput {
            active += 1
            maxConcurrent = max(maxConcurrent, active)
            // Yield so that if the scheduler ever ran two generations concurrently, their spans would
            // overlap and `maxConcurrent` would exceed 1.
            await Task.yield()
            calls.append(meeting.id)
            defer { active -= 1 }
            if let errorToThrow { throw errorToThrow }
            let content = "AUTO_BRIEF"
            if addsBriefOnSuccess {
                return store.addOutput(to: meeting, kind: .brief, content: content)
            }
            // Return a detached output without persisting (used when a stale brief must remain the
            // latest one for a specific assertion).
            return MeetingOutput(kind: .brief, content: content, meeting: meeting)
        }
    }

    struct Boom: Error {}

    // MARK: - Fixtures

    private func makeStore() throws -> MeetingService {
        let dir = try TestSupport.makeTemporaryDirectory(prefix: "BriefScheduler")
        addTeardownBlock { TestSupport.remove(dir) }
        return MeetingService(appSupportDirectory: dir)
    }

    private func makeDefaults() -> UserDefaults {
        let suite = "MeetingBriefSchedulerTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        return defaults
    }

    private func event(
        id: String = "evt-1",
        title: String = "Acme Sync",
        startInMinutes: Double = 10,
        isAllDay: Bool = false,
        attendees: Int = 2,
        now: Date
    ) -> CalendarEventDTO {
        let people = (0..<attendees).map { Attendee(name: "Person \($0)", email: "p\($0)@acme.com") }
        return CalendarEventDTO(
            id: id,
            title: title,
            startDate: now.addingTimeInterval(startInMinutes * 60),
            endDate: now.addingTimeInterval((startInMinutes + 30) * 60),
            isAllDay: isAllDay,
            attendees: people
        )
    }

    private func settle(_ scheduler: MeetingBriefScheduler) async {
        await scheduler.currentWorker?.value
    }

    // MARK: - Tests

    func testFiresOnceForEventEnteringLeadWindow() async throws {
        let store = try makeStore()
        let stub = StubBriefGenerator(store: store)
        let scheduler = MeetingBriefScheduler(store: store, briefService: stub, defaults: makeDefaults())
        let now = Date()

        let evt = event(now: now)
        // Two ticks before the first generation settles: the pending-guard must prevent a double.
        scheduler.tick(events: [evt], now: now)
        scheduler.tick(events: [evt], now: now)
        await settle(scheduler)

        XCTAssertEqual(stub.calls.count, 1)
        // A backing meeting was pre-created and carries the auto-brief.
        let meeting = try XCTUnwrap(store.meetings.first { $0.calendarEventID == evt.id })
        XCTAssertEqual(meeting.source, .calendar)
        XCTAssertEqual(meeting.state, .scheduled)
        XCTAssertNotNil(store.latestOutput(ofKind: .brief, for: meeting))

        // A later tick now sees a fresh brief and does not regenerate.
        scheduler.tick(events: [evt], now: now)
        await settle(scheduler)
        XCTAssertEqual(stub.calls.count, 1)
    }

    func testSkipsOutsideLeadWindow() async throws {
        let store = try makeStore()
        let stub = StubBriefGenerator(store: store)
        let scheduler = MeetingBriefScheduler(store: store, briefService: stub, defaults: makeDefaults())
        let now = Date()

        // 45 min out (> 20 min default lead) and an already-started event are both ineligible.
        scheduler.tick(events: [event(id: "far", startInMinutes: 45, now: now)], now: now)
        scheduler.tick(events: [event(id: "past", startInMinutes: -5, now: now)], now: now)
        await settle(scheduler)

        XCTAssertTrue(stub.calls.isEmpty)
        XCTAssertTrue(store.meetings.isEmpty)
    }

    func testSkipsAllDayAndBelowMinAttendees() async throws {
        let store = try makeStore()
        let stub = StubBriefGenerator(store: store)
        let scheduler = MeetingBriefScheduler(store: store, briefService: stub, defaults: makeDefaults())
        let now = Date()

        scheduler.tick(events: [event(id: "allday", isAllDay: true, now: now)], now: now)
        scheduler.tick(events: [event(id: "solo", attendees: 0, now: now)], now: now)
        await settle(scheduler)

        XCTAssertTrue(stub.calls.isEmpty)
        XCTAssertTrue(store.meetings.isEmpty)
    }

    func testReusesExistingMeetingInsteadOfCreatingDuplicate() async throws {
        let store = try makeStore()
        let stub = StubBriefGenerator(store: store)
        let scheduler = MeetingBriefScheduler(store: store, briefService: stub, defaults: makeDefaults())
        let now = Date()
        let evt = event(now: now)

        // A meeting already backs this calendar event.
        let existing = store.createMeeting(
            title: "Acme Sync",
            source: .calendar,
            state: .scheduled,
            startDate: evt.startDate,
            calendarEventID: evt.id
        )

        scheduler.tick(events: [evt], now: now)
        await settle(scheduler)

        XCTAssertEqual(stub.calls, [existing.id])
        XCTAssertEqual(store.meetings.filter { $0.calendarEventID == evt.id }.count, 1)
    }

    func testSkipsWhenFreshBriefExists() async throws {
        let store = try makeStore()
        let stub = StubBriefGenerator(store: store)
        let scheduler = MeetingBriefScheduler(store: store, briefService: stub, defaults: makeDefaults())
        let now = Date()
        let evt = event(now: now)

        let meeting = store.createMeeting(
            title: "Acme Sync", source: .calendar, state: .scheduled,
            startDate: evt.startDate, calendarEventID: evt.id
        )
        // A brief generated 1 hour ago is within the 6 h default freshness window.
        let brief = store.addOutput(to: meeting, kind: .brief, content: "EXISTING")
        brief.createdAt = now.addingTimeInterval(-3600)

        scheduler.tick(events: [evt], now: now)
        await settle(scheduler)

        XCTAssertTrue(stub.calls.isEmpty)
    }

    func testRegeneratesWhenBriefIsStale() async throws {
        let store = try makeStore()
        let stub = StubBriefGenerator(store: store)
        let scheduler = MeetingBriefScheduler(store: store, briefService: stub, defaults: makeDefaults())
        let now = Date()
        let evt = event(now: now)

        let meeting = store.createMeeting(
            title: "Acme Sync", source: .calendar, state: .scheduled,
            startDate: evt.startDate, calendarEventID: evt.id
        )
        // 7 h old > 6 h default freshness → stale.
        let brief = store.addOutput(to: meeting, kind: .brief, content: "OLD")
        brief.createdAt = now.addingTimeInterval(-7 * 3600)

        scheduler.tick(events: [evt], now: now)
        await settle(scheduler)

        XCTAssertEqual(stub.calls, [meeting.id])
    }

    func testConcurrencyCapUnderBurst() async throws {
        let store = try makeStore()
        let stub = StubBriefGenerator(store: store)
        let scheduler = MeetingBriefScheduler(store: store, briefService: stub, defaults: makeDefaults())
        let now = Date()

        let events = (0..<5).map { event(id: "evt-\($0)", startInMinutes: Double(1 + $0), now: now) }
        scheduler.tick(events: events, now: now)
        await settle(scheduler)

        XCTAssertEqual(stub.calls.count, 5)
        XCTAssertEqual(stub.maxConcurrent, 1, "brief generation must be serialized (cap 1)")
    }

    func testThrowingGenerateBriefSetsStatusAndDoesNotPropagate() async throws {
        let store = try makeStore()
        let stub = StubBriefGenerator(store: store)
        stub.errorToThrow = Boom()
        let scheduler = MeetingBriefScheduler(store: store, briefService: stub, defaults: makeDefaults())
        let now = Date()
        let evt = event(now: now)

        // Must not throw out of the poll loop.
        scheduler.tick(events: [evt], now: now)
        await settle(scheduler)

        XCTAssertEqual(stub.calls.count, 1)
        // Meeting was pre-created but no brief persisted.
        let meeting = try XCTUnwrap(store.meetings.first { $0.calendarEventID == evt.id })
        XCTAssertNil(store.latestOutput(ofKind: .brief, for: meeting))
        // Status reflects the failure.
        if case .failed = scheduler.status {} else {
            XCTFail("Expected .failed status, got \(scheduler.status)")
        }
    }

    func testDisabledSettingIsNoOp() async throws {
        let store = try makeStore()
        let stub = StubBriefGenerator(store: store)
        let defaults = makeDefaults()
        defaults.set(false, forKey: UserDefaultsKeys.meetingsAutoBriefEnabled)
        let scheduler = MeetingBriefScheduler(store: store, briefService: stub, defaults: defaults)
        let now = Date()

        scheduler.tick(events: [event(now: now)], now: now)
        await settle(scheduler)

        XCTAssertTrue(stub.calls.isEmpty)
        XCTAssertTrue(store.meetings.isEmpty)
    }

    func testCustomLeadAndMinAttendeesSettings() async throws {
        let store = try makeStore()
        let stub = StubBriefGenerator(store: store)
        let defaults = makeDefaults()
        defaults.set(10, forKey: UserDefaultsKeys.meetingsAutoBriefLeadMinutes)
        defaults.set(3, forKey: UserDefaultsKeys.meetingsAutoBriefMinAttendees)
        let scheduler = MeetingBriefScheduler(store: store, briefService: stub, defaults: defaults)
        let now = Date()

        // 15 min out is beyond the 10 min lead → skip.
        scheduler.tick(events: [event(id: "beyond", startInMinutes: 15, attendees: 5, now: now)], now: now)
        // 5 min out with only 2 attendees is below the min of 3 → skip.
        scheduler.tick(events: [event(id: "small", startInMinutes: 5, attendees: 2, now: now)], now: now)
        // 5 min out with 3 attendees → eligible.
        scheduler.tick(events: [event(id: "ok", startInMinutes: 5, attendees: 3, now: now)], now: now)
        await settle(scheduler)

        XCTAssertEqual(stub.calls.count, 1)
        XCTAssertNotNil(store.meetings.first { $0.calendarEventID == "ok" })
    }

    func testHasFreshBriefForCalendarEventID() async throws {
        let store = try makeStore()
        let stub = StubBriefGenerator(store: store)
        let scheduler = MeetingBriefScheduler(store: store, briefService: stub, defaults: makeDefaults())
        let now = Date()

        XCTAssertFalse(scheduler.hasFreshBrief(forCalendarEventID: "missing", now: now))

        let meeting = store.createMeeting(
            title: "Acme Sync", source: .calendar, state: .scheduled, calendarEventID: "evt-fresh"
        )
        let fresh = store.addOutput(to: meeting, kind: .brief, content: "FRESH")
        fresh.createdAt = now.addingTimeInterval(-1800)
        XCTAssertTrue(scheduler.hasFreshBrief(forCalendarEventID: "evt-fresh", now: now))

        fresh.createdAt = now.addingTimeInterval(-8 * 3600)
        XCTAssertFalse(scheduler.hasFreshBrief(forCalendarEventID: "evt-fresh", now: now))
    }
}
