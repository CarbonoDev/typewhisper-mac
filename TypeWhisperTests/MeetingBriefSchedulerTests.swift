import XCTest
@testable import TypeWhisper

/// Unit tests for the automatic pre-meeting brief scheduler (plan AD9). The store is a real
/// in-memory `MeetingService` (temp directory); brief generation is stubbed so no LLM is touched.
/// A fake `now` drives the lead-window logic; config comes from an isolated `UserDefaults` suite.
@MainActor
final class MeetingBriefSchedulerTests: XCTestCase {
    /// [Track J] The scheduler now enqueues onto this queue instead of owning a serial worker; tests
    /// settle on `await jobQueue.drain()`.
    private let jobQueue = JobQueueService()

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
        await jobQueue.drain()
    }

    // MARK: - Tests

    func testFiresOnceForEventEnteringLeadWindow() async throws {
        let store = try makeStore()
        let stub = StubBriefGenerator(store: store)
        let scheduler = MeetingBriefScheduler(store: store, briefService: stub, jobQueue: jobQueue, defaults: makeDefaults())
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
        let scheduler = MeetingBriefScheduler(store: store, briefService: stub, jobQueue: jobQueue, defaults: makeDefaults())
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
        let scheduler = MeetingBriefScheduler(store: store, briefService: stub, jobQueue: jobQueue, defaults: makeDefaults())
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
        let scheduler = MeetingBriefScheduler(store: store, briefService: stub, jobQueue: jobQueue, defaults: makeDefaults())
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
        let scheduler = MeetingBriefScheduler(store: store, briefService: stub, jobQueue: jobQueue, defaults: makeDefaults())
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
        let scheduler = MeetingBriefScheduler(store: store, briefService: stub, jobQueue: jobQueue, defaults: makeDefaults())
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
        let scheduler = MeetingBriefScheduler(store: store, briefService: stub, jobQueue: jobQueue, defaults: makeDefaults())
        let now = Date()

        let events = (0..<5).map { event(id: "evt-\($0)", startInMinutes: Double(1 + $0), now: now) }
        scheduler.tick(events: events, now: now)
        await settle(scheduler)

        XCTAssertEqual(stub.calls.count, 5)
        XCTAssertEqual(stub.maxConcurrent, 1, "brief generation must be serialized (cap 1)")
    }

    func testThrowingGenerateBriefDoesNotPropagate() async throws {
        let store = try makeStore()
        let stub = StubBriefGenerator(store: store)
        stub.errorToThrow = Boom()
        let scheduler = MeetingBriefScheduler(store: store, briefService: stub, jobQueue: jobQueue, defaults: makeDefaults())
        let now = Date()
        let evt = event(now: now)

        // Must not throw out of the poll loop.
        scheduler.tick(events: [evt], now: now)
        await settle(scheduler)

        XCTAssertEqual(stub.calls.count, 1)
        // Meeting was pre-created but no brief persisted.
        let meeting = try XCTUnwrap(store.meetings.first { $0.calendarEventID == evt.id })
        XCTAssertNil(store.latestOutput(ofKind: .brief, for: meeting))
    }

    /// finding 3: a thrown generation is remembered and not retried on every subsequent poll tick
    /// while the event remains in the lead window (guards against an LLM/network retry storm).
    func testThrowingGenerateBriefIsNotRetriedWithinLeadWindow() async throws {
        let store = try makeStore()
        let stub = StubBriefGenerator(store: store)
        stub.errorToThrow = Boom()
        let scheduler = MeetingBriefScheduler(store: store, briefService: stub, jobQueue: jobQueue, defaults: makeDefaults())
        let now = Date()
        let evt = event(now: now)

        scheduler.tick(events: [evt], now: now)
        await settle(scheduler)
        XCTAssertEqual(stub.calls.count, 1)

        // Several more poll ticks inside the same lead window must not re-attempt generation.
        for offset in [1.0, 2.0, 3.0] {
            scheduler.tick(events: [evt], now: now.addingTimeInterval(offset * 60))
            await settle(scheduler)
        }
        XCTAssertEqual(stub.calls.count, 1, "a failed event must not be retried within its lead window")
    }

    /// finding 1: after the scheduler pre-creates a placeholder meeting, the event must NOT be
    /// excluded from the upcoming list (so the "Brief ready" row and the start-notification prompt
    /// survive). Routes the event through `CalendarService.refresh` with the exclusion set the view
    /// model computes, and confirms the event stays visible and the start notification still fires.
    func testPlaceholderMeetingKeepsEventVisibleAndNotifiable() async throws {
        let store = try makeStore()
        let stub = StubBriefGenerator(store: store)
        let scheduler = MeetingBriefScheduler(store: store, briefService: stub, jobQueue: jobQueue, defaults: makeDefaults())
        let now = Date()
        let evt = event(startInMinutes: 15, now: now)

        // Scheduler pre-creates the backing meeting ~15 min before start.
        scheduler.tick(events: [evt], now: now)
        await settle(scheduler)
        let meeting = try XCTUnwrap(store.meetings.first { $0.calendarEventID == evt.id })
        XCTAssertEqual(meeting.state, .scheduled)
        XCTAssertTrue(scheduler.placeholderEventIDs.contains(evt.id))

        // The exclusion set the view model feeds to CalendarService.refresh must keep the placeholder.
        let excluded = MeetingsViewModel.engagedCalendarEventIDs(
            meetings: store.meetings,
            autoBriefPlaceholders: scheduler.placeholderEventIDs
        )
        XCTAssertFalse(excluded.contains(evt.id), "auto-brief placeholder must not be excluded")

        // Routed through the real windowing, the event remains visible.
        let provider = FakeProvider(events: [evt])
        let calendar = CalendarService(provider: provider)
        await calendar.requestAccess(now: now)
        calendar.refresh(now: now, existingCalendarEventIDs: excluded)
        XCTAssertEqual(calendar.upcomingEvents.map(\.id), [evt.id])

        // The start notification still fires once the event reaches its start window.
        let notifier = MeetingStartNotificationService(center: nil)
        let atStart = evt.startDate.addingTimeInterval(-30)
        XCTAssertTrue(notifier.shouldNotify(evt, now: atStart))

        // Contrast: once the user engages the meeting (state leaves `.scheduled`), it IS excluded.
        meeting.state = .live
        let afterEngage = MeetingsViewModel.engagedCalendarEventIDs(
            meetings: store.meetings,
            autoBriefPlaceholders: scheduler.placeholderEventIDs
        )
        XCTAssertTrue(afterEngage.contains(evt.id))
    }

    // MARK: - [Track J] Queue routing

    /// A resumable barrier so a stub can hold the llm lane deterministically.
    @MainActor
    private final class Gate {
        private var waiters: [CheckedContinuation<Void, Never>] = []
        private var opened = false
        func wait() async { if opened { return }; await withCheckedContinuation { waiters.append($0) } }
        func open() {
            guard !opened else { return }
            opened = true
            let current = waiters
            waiters = []
            current.forEach { $0.resume() }
        }
    }

    private func waitUntil(_ condition: @escaping () -> Bool) async {
        var iterations = 0
        while !condition() {
            if iterations > 100_000 { XCTFail("condition never met"); return }
            await Task.yield()
            iterations += 1
        }
    }

    /// `tick` enqueues a background `.brief` job (llm lane) for the pre-created meeting, deduped by
    /// `(brief, meetingID)` so repeated ticks within the lead window never stack a second one.
    func testTickEnqueuesBackgroundBriefJobDedupedByMeeting() async throws {
        let store = try makeStore()
        let stub = StubBriefGenerator(store: store)
        stub.addsBriefOnSuccess = false // don't persist, so a re-tick isn't skipped by freshness
        let scheduler = MeetingBriefScheduler(store: store, briefService: stub, jobQueue: jobQueue, defaults: makeDefaults())
        let now = Date()
        let evt = event(now: now)

        scheduler.tick(events: [evt], now: now)
        let meeting = try XCTUnwrap(store.meetings.first { $0.calendarEventID == evt.id })
        let briefJobs = jobQueue.jobs.filter { $0.kind == .brief }
        XCTAssertEqual(briefJobs.count, 1)
        XCTAssertEqual(briefJobs.first?.priority, .background)
        XCTAssertEqual(briefJobs.first?.meetingID, meeting.id)

        // A second tick while the first is still active is deduped by the queue.
        scheduler.tick(events: [evt], now: now)
        XCTAssertEqual(jobQueue.jobs.filter { $0.kind == .brief && $0.state.isActive }.count, 1)

        await jobQueue.drain()
        XCTAssertEqual(stub.calls.count, 1)
    }

    /// A user-initiated brief in the llm lane runs before a queued background auto-brief (priority).
    func testUserInitiatedBriefRunsBeforeQueuedAutoBrief() async throws {
        let store = try makeStore()
        let stub = StubBriefGenerator(store: store)
        stub.addsBriefOnSuccess = false
        let scheduler = MeetingBriefScheduler(store: store, briefService: stub, jobQueue: jobQueue, defaults: makeDefaults())
        let now = Date()

        // Hold the llm lane with a gated job so both briefs must queue behind it.
        let gate = Gate()
        jobQueue.enqueue(kind: .summary, meetingID: UUID(), priority: .userInitiated) { await gate.wait() }
        await waitUntil { self.jobQueue.runningCount == 1 }

        // Auto-brief (background) enqueued by the scheduler.
        let evt = event(now: now)
        scheduler.tick(events: [evt], now: now)
        let autoMeeting = try XCTUnwrap(store.meetings.first { $0.calendarEventID == evt.id })

        // A user-initiated brief for a different meeting, enqueued the way the view model does.
        let userMeeting = store.createMeeting(title: "User", source: .adHoc, state: .completed)
        jobQueue.enqueue(kind: .brief, meetingID: userMeeting.id, priority: .userInitiated) { [weak stub] in
            _ = try await stub?.generateBrief(for: userMeeting)
        }

        gate.open()
        await jobQueue.drain()

        let userIdx = try XCTUnwrap(stub.calls.firstIndex(of: userMeeting.id))
        let autoIdx = try XCTUnwrap(stub.calls.firstIndex(of: autoMeeting.id))
        XCTAssertLessThan(userIdx, autoIdx, "a user-initiated brief must run before a queued auto-brief")
    }

    // MARK: - Fake calendar provider (no live EKEventStore)

    private final class FakeProvider: CalendarEventProviding {
        var authorizationStatus: CalendarAuthorizationStatus = .notDetermined
        var eventsToReturn: [CalendarEventDTO]
        init(events: [CalendarEventDTO]) { self.eventsToReturn = events }
        func requestAccess() async -> CalendarAuthorizationStatus {
            authorizationStatus = .authorized
            return .authorized
        }
        func events(from start: Date, to end: Date) -> [CalendarEventDTO] { eventsToReturn }
        func calendars() -> [CalendarInfo] { [] }
    }

    func testDisabledSettingIsNoOp() async throws {
        let store = try makeStore()
        let stub = StubBriefGenerator(store: store)
        let defaults = makeDefaults()
        defaults.set(false, forKey: UserDefaultsKeys.meetingsAutoBriefEnabled)
        let scheduler = MeetingBriefScheduler(store: store, briefService: stub, jobQueue: jobQueue, defaults: defaults)
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
        let scheduler = MeetingBriefScheduler(store: store, briefService: stub, jobQueue: jobQueue, defaults: defaults)
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
        let scheduler = MeetingBriefScheduler(store: store, briefService: stub, jobQueue: jobQueue, defaults: makeDefaults())
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
