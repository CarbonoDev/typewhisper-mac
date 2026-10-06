import XCTest
@testable import TypeWhisper

/// [Perf Phase 2] The calendar wake planner wakes the consumers by the windows they declare; these
/// pin that each declared window is exactly the consumer's own gate, so dropping the 60 s poll moves
/// no start notification or auto-brief.
@MainActor
final class CalendarConsumerWindowTests: XCTestCase {
    private struct NoBriefs: Error {}

    @MainActor
    private final class FailingBriefGenerator: MeetingBriefGenerating {
        @discardableResult
        func generateBrief(for meeting: Meeting, providerOverride: String?, modelOverride: String?) async throws -> MeetingOutput {
            throw NoBriefs()
        }
    }

    private let jobQueue = JobQueueService()

    override func tearDown() async throws {
        for job in jobQueue.jobs where job.state.isActive { jobQueue.cancel(job.id) }
        await jobQueue.drain()
        try await super.tearDown()
    }

    private func makeDefaults(lead: Int? = nil, enabled: Bool? = nil) -> UserDefaults {
        let suite = "CalendarConsumerWindowTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        if let lead { defaults.set(lead, forKey: UserDefaultsKeys.meetingsAutoBriefLeadMinutes) }
        if let enabled { defaults.set(enabled, forKey: UserDefaultsKeys.meetingsAutoBriefEnabled) }
        return defaults
    }

    private func makeScheduler(defaults: UserDefaults) throws -> (MeetingBriefScheduler, MeetingService) {
        let dir = try TestSupport.makeTemporaryDirectory(prefix: "CalendarConsumerWindow")
        addTeardownBlock { TestSupport.remove(dir) }
        let store = MeetingService(appSupportDirectory: dir)
        let scheduler = MeetingBriefScheduler(
            store: store, briefService: FailingBriefGenerator(), jobQueue: jobQueue, defaults: defaults
        )
        return (scheduler, store)
    }

    private func event(_ id: String, start: Date) -> CalendarEventDTO {
        CalendarEventDTO(
            id: id, title: "Sync \(id)",
            startDate: start, endDate: start.addingTimeInterval(1800),
            isAllDay: false,
            attendees: [Attendee(name: "A", email: "a@x.com"), Attendee(name: "B", email: "b@x.com")]
        )
    }

    func testAutoBriefWindowIsTheSchedulersLeadGate() throws {
        for lead in [5, 20, 60] {
            let (scheduler, store) = try makeScheduler(defaults: makeDefaults(lead: lead))
            let window = try XCTUnwrap(scheduler.consumerWindow)
            let start = Date(timeIntervalSince1970: 1_700_000_000)
            for offset in stride(from: -Double(lead * 60) - 120, through: 120, by: 30) {
                let at = start.addingTimeInterval(offset)
                let evt = event("lead\(lead)-\(offset)", start: start)
                scheduler.tick(events: [evt], now: at)
                let ticked = store.meetings.contains { $0.calendarEventID == evt.id }
                XCTAssertEqual(window.contains(evt, now: at), ticked, "lead \(lead) offset \(offset)")
            }
        }
    }

    func testDisabledAutoBriefsDeclareNoWindow() throws {
        let (scheduler, _) = try makeScheduler(defaults: makeDefaults(enabled: false))
        XCTAssertNil(scheduler.consumerWindow)
    }

    func testNotificationWindowIsTheNotifiersGate() {
        let notifier = MeetingStartNotificationService(center: nil)
        let window = MeetingStartNotificationService.consumerWindow
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        for offset in stride(from: -300.0, through: 300.0, by: 15) {
            let evt = event("n\(offset)", start: start)
            let at = start.addingTimeInterval(offset)
            XCTAssertEqual(window.contains(evt, now: at), notifier.shouldNotify(evt, now: at), "offset \(offset)")
        }
    }
}
