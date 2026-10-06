import Combine
import EventKit
import XCTest
@testable import TypeWhisper

/// [Perf Phase 2] `CalendarRefreshCoordinator` + the equality-gated `CalendarService`: refetch on
/// store / system triggers instead of a 60 s poll, publish (and run consumers) only on change, and
/// wake for time-gated consumers at their window openings.
@MainActor
final class CalendarRefreshCoordinatorTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)
    private var cancellables = Set<AnyCancellable>()

    private struct Harness {
        let provider: CountingCalendarProvider
        let service: CalendarService
        let wakes: ManualCalendarWakes
        let center: NotificationCenter
        let coordinator: CalendarRefreshCoordinator
        let consumerRuns: () -> [(ids: [String], at: Date)]
    }

    private func event(_ id: String, startIn: TimeInterval, length: TimeInterval = 1800) -> CalendarEventDTO {
        CalendarEventDTO(
            id: id, title: id,
            startDate: start.addingTimeInterval(startIn),
            endDate: start.addingTimeInterval(startIn + length),
            isAllDay: false, attendees: []
        )
    }

    private func makeHarness(
        events: [CalendarEventDTO],
        windows: [CalendarWakePlanner.ConsumerWindow] = [MeetingStartNotificationService.consumerWindow]
    ) -> Harness {
        let provider = CountingCalendarProvider(events: events)
        let service = CalendarService(provider: provider, selectionStore: InMemorySelection())
        let wakes = ManualCalendarWakes(clock: start)
        let center = NotificationCenter()
        final class Runs { var value: [(ids: [String], at: Date)] = [] }
        let runs = Runs()
        let coordinator = CalendarRefreshCoordinator(
            calendarService: service,
            hooks: .init(
                existingCalendarEventIDs: { [] },
                consumerWindows: { windows },
                runConsumers: { events, at in runs.value.append((events.map(\.id), at)) }
            ),
            now: { wakes.clock },
            notificationCenter: center,
            workspaceNotificationCenter: NotificationCenter(),
            scheduleWake: { wakes.schedule($0, $1) }
        )
        // Mirror the VM sink: a published change runs the consumers and re-plans.
        service.$upcomingEvents
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak coordinator] events in
                runs.value.append((events.map(\.id), wakes.clock))
                coordinator?.reschedule()
            }
            .store(in: &cancellables)
        return Harness(
            provider: provider, service: service, wakes: wakes, center: center,
            coordinator: coordinator, consumerRuns: { runs.value }
        )
    }

    private final class InMemorySelection: CalendarSelectionStoring {
        func isSelected(_ calendarID: String) -> Bool { true }
        func setSelected(_ selected: Bool, for calendarID: String) {}
        var deselectedCalendarIDs: Set<String> { [] }
    }

    /// Let `receive(on: main)` hops and the in-flight query land.
    private func settle(_ coordinator: CalendarRefreshCoordinator) async {
        await mainHop()
        await coordinator.settle()
        await mainHop()
    }

    private func mainHop() async {
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
    }

    // MARK: - Equality gate

    func testUnchangedRefetchPublishesNothingAndRunsNoConsumers() async {
        let h = makeHarness(events: [event("a", startIn: 3600)])
        h.coordinator.start()
        await settle(h.coordinator)
        XCTAssertEqual(h.service.upcomingEvents.map(\.id), ["a"])
        let runsAfterFirst = h.consumerRuns().count
        XCTAssertEqual(runsAfterFirst, 1)

        h.coordinator.refetch()
        await settle(h.coordinator)
        XCTAssertEqual(h.provider.queryCount, 2, "the store was re-queried")
        XCTAssertEqual(h.consumerRuns().count, runsAfterFirst, "an equal window publishes nothing")
    }

    func testChangedRefetchPublishesOnce() async {
        let h = makeHarness(events: [event("a", startIn: 3600)])
        h.coordinator.start()
        await settle(h.coordinator)
        h.provider.eventsToReturn.append(event("b", startIn: 7200))
        h.coordinator.refetch()
        await settle(h.coordinator)
        XCTAssertEqual(h.service.upcomingEvents.map(\.id), ["a", "b"])
        XCTAssertEqual(h.consumerRuns().last?.ids, ["a", "b"])
    }

    // MARK: - Triggers

    func testEventStoreChangeRefetchesWhileStarted() async {
        let h = makeHarness(events: [])
        h.coordinator.start()
        await settle(h.coordinator)
        XCTAssertEqual(h.provider.queryCount, 1)

        h.provider.eventsToReturn = [event("a", startIn: 3600)]
        h.center.post(name: .EKEventStoreChanged, object: nil)
        await settle(h.coordinator)
        XCTAssertEqual(h.provider.queryCount, 2)
        XCTAssertEqual(h.service.upcomingEvents.map(\.id), ["a"])

        h.center.post(name: .NSCalendarDayChanged, object: nil)
        await settle(h.coordinator)
        XCTAssertEqual(h.provider.queryCount, 3, "day rollover refetches")
    }

    func testStoppedCoordinatorIgnoresStoreChangesAndDisarms() async {
        let h = makeHarness(events: [event("a", startIn: 3600)])
        h.coordinator.start()
        await settle(h.coordinator)
        XCTAssertNotNil(h.wakes.armed)
        h.coordinator.stop()
        XCTAssertNil(h.wakes.armed, "stop cancels the wake timer")
        h.center.post(name: .EKEventStoreChanged, object: nil)
        await settle(h.coordinator)
        XCTAssertEqual(h.provider.queryCount, 1)
    }

    func testTriggerBurstCoalesces() async {
        let h = makeHarness(events: [])
        h.coordinator.start()
        for _ in 0..<5 { h.coordinator.refetch() }
        await settle(h.coordinator)
        XCTAssertLessThanOrEqual(h.provider.queryCount, 2, "one in-flight query plus one follow-up")
    }

    // MARK: - Wakes (time-gated consumers fire at the same moments)

    func testNoPollWhileNothingIsDue() async {
        // An event 6 h out: the only wakes are its notification window and the refetch deadline —
        // no minute-by-minute ticking in between.
        let h = makeHarness(events: [event("a", startIn: 6 * 3600)])
        h.coordinator.start()
        await settle(h.coordinator)
        let wake = try? XCTUnwrap(h.coordinator.nextWake)
        XCTAssertEqual(wake?.isRefetch, true)
        XCTAssertEqual(wake?.date, h.service.nextRefetchDate())
        XCTAssertLessThanOrEqual(wake?.date ?? .distantFuture, start.addingTimeInterval(CalendarService.defaultFetchSlack))
    }

    func testNotificationConsumerRunsWhenItsWindowOpens() async {
        let notifier = MeetingStartNotificationService(center: nil)
        let evt = event("a", startIn: 10 * 60)
        let h = makeHarness(events: [evt])
        h.coordinator.start()
        await settle(h.coordinator)

        let wake = try? XCTUnwrap(h.coordinator.nextWake)
        XCTAssertEqual(wake?.date, evt.startDate.addingTimeInterval(-60), "wakes exactly as the window opens")
        XCTAssertFalse(notifier.shouldNotify(evt, now: evt.startDate.addingTimeInterval(-61)))

        let runsBefore = h.consumerRuns().count
        let firedAt = h.wakes.fireNext()
        await settle(h.coordinator)
        XCTAssertEqual(h.consumerRuns().count, runsBefore + 1, "the wake runs the consumers")
        XCTAssertEqual(h.consumerRuns().last?.ids, ["a"])
        XCTAssertEqual(firedAt, evt.startDate.addingTimeInterval(-60))
        XCTAssertTrue(notifier.shouldNotify(evt, now: firedAt!), "the notifier would post on this run")

        // Inside the window: re-ticked at the old poll cadence.
        XCTAssertEqual(h.coordinator.nextWake?.date, firedAt!.addingTimeInterval(CalendarWakePlanner.retickInterval))
    }

    func testEventStartingRewindowsWithoutAProviderQuery() async {
        let evt = event("a", startIn: 10 * 60)
        let h = makeHarness(events: [evt], windows: [])
        h.coordinator.start()
        await settle(h.coordinator)
        XCTAssertEqual(h.coordinator.nextWake?.date, evt.startDate)
        h.wakes.fireNext()
        await settle(h.coordinator)
        XCTAssertEqual(h.provider.queryCount, 1, "time passing re-windows the retained query")
        XCTAssertEqual(h.coordinator.nextWake?.date, evt.endDate)
    }

    func testRefetchDeadlineQueriesAndRunsConsumers() async {
        let h = makeHarness(events: [event("a", startIn: 6 * 3600)], windows: [])
        h.coordinator.start()
        await settle(h.coordinator)
        let runsBefore = h.consumerRuns().count
        XCTAssertEqual(h.coordinator.nextWake?.isRefetch, true)
        h.wakes.fireNext()
        await settle(h.coordinator)
        XCTAssertEqual(h.provider.queryCount, 2)
        XCTAssertEqual(h.consumerRuns().count, runsBefore + 1, "a wake-driven refetch runs the consumers")
    }
}
