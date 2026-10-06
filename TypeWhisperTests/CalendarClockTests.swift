import Combine
import XCTest
@testable import TypeWhisper

/// [Perf · stale-state audit] Time-driven calendar displays re-render from `CalendarClock`, which the
/// coordinator ticks at its wakes — including wakes that change no list (event start, the tray-title
/// window opening) — and the exclusion set re-applies on the coordinator's `exclusionsChanged`.
@MainActor
final class CalendarClockTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    private final class InMemorySelection: CalendarSelectionStoring {
        func isSelected(_ calendarID: String) -> Bool { true }
        func setSelected(_ selected: Bool, for calendarID: String) {}
        var deselectedCalendarIDs: Set<String> { [] }
    }

    private func event(_ id: String, startIn: TimeInterval) -> CalendarEventDTO {
        CalendarEventDTO(
            id: id, title: id,
            startDate: start.addingTimeInterval(startIn),
            endDate: start.addingTimeInterval(startIn + 1800),
            isAllDay: false, attendees: []
        )
    }

    private func settle(_ coordinator: CalendarRefreshCoordinator) async {
        await mainHop()
        await coordinator.settle()
        await mainHop()
    }

    private func mainHop() async {
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
    }

    private func makeCoordinator(
        events: [CalendarEventDTO],
        displayLeads: [TimeInterval] = [],
        excluded: @escaping @MainActor () -> Set<String> = { [] },
        exclusionsChanged: AnyPublisher<Void, Never> = Empty().eraseToAnyPublisher()
    ) -> (CalendarRefreshCoordinator, CalendarService, ManualCalendarWakes) {
        let service = CalendarService(provider: CountingCalendarProvider(events: events), selectionStore: InMemorySelection())
        let wakes = ManualCalendarWakes(clock: start)
        let coordinator = CalendarRefreshCoordinator(
            calendarService: service,
            hooks: .init(
                existingCalendarEventIDs: excluded,
                consumerWindows: { [] },
                runConsumers: { _, _ in },
                displayLeads: { displayLeads },
                exclusionsChanged: exclusionsChanged
            ),
            now: { wakes.clock },
            notificationCenter: NotificationCenter(),
            workspaceNotificationCenter: NotificationCenter(),
            scheduleWake: { wakes.schedule($0, $1) }
        )
        return (coordinator, service, wakes)
    }

    func testClockTicksOnAWakeThatChangesNoList() async {
        let evt = event("a", startIn: 10 * 60)
        let (coordinator, service, wakes) = makeCoordinator(events: [evt])
        coordinator.start()
        await settle(coordinator)
        let listBefore = service.upcomingEvents

        var ticks: [Date] = []
        let watch = coordinator.clock.$now.dropFirst().sink { ticks.append($0) }
        XCTAssertEqual(coordinator.nextWake?.date, evt.startDate)
        wakes.fireNext()
        await settle(coordinator)

        XCTAssertEqual(service.upcomingEvents, listBefore, "an event starting changes no list")
        XCTAssertEqual(ticks, [evt.startDate], "but the clock ticks so in-progress badges re-render")
        withExtendedLifetime(watch) {}
    }

    func testClockTicksAfterARefetch() async {
        let (coordinator, _, _) = makeCoordinator(events: [])
        var ticks = 0
        let watch = coordinator.clock.$now.dropFirst().sink { _ in ticks += 1 }
        coordinator.start()
        await settle(coordinator)
        XCTAssertEqual(ticks, 1)
        withExtendedLifetime(watch) {}
    }

    func testTrayTitleWindowOpeningIsAWake() async {
        // Two hours out: without the display lead the first wake would be the refetch deadline.
        let evt = event("a", startIn: 2 * 3600)
        let lead = MeetingTrayIndicator.trayTitleWindow
        let (coordinator, _, _) = makeCoordinator(events: [evt], displayLeads: [lead])
        coordinator.start()
        await settle(coordinator)
        let wake = coordinator.nextWake
        XCTAssertNotNil(wake)
        if let refetch = coordinator.nextWake.flatMap({ $0.isRefetch ? $0.date : nil }) {
            // The refetch deadline can precede it (≤ 1 h slack); then the edge is the following wake.
            XCTAssertLessThanOrEqual(refetch, evt.startDate.addingTimeInterval(-lead))
        } else {
            XCTAssertEqual(wake?.date, evt.startDate.addingTimeInterval(-lead))
        }
        let planned = CalendarWakePlanner.nextWake(
            sourceEvents: [evt], consumerEvents: [], now: start, lookAhead: 12 * 3600, grace: 2 * 3600,
            consumerWindows: [], displayLeads: [lead], refetchAt: nil
        )
        XCTAssertEqual(planned?.date, evt.startDate.addingTimeInterval(-lead))
    }

    func testExclusionChangeRewindowsWithoutStartOrQuery() async {
        let evt = event("a", startIn: 3600)
        final class Box { var excluded: Set<String> = [] }
        let box = Box()
        let changes = PassthroughSubject<Void, Never>()
        let (coordinator, service, _) = makeCoordinator(
            events: [evt],
            excluded: { box.excluded },
            exclusionsChanged: changes.eraseToAnyPublisher()
        )
        service.refresh(now: start)
        XCTAssertEqual(service.upcomingEvents.map(\.id), ["a"])

        // The backing auto-brief placeholder went live: the event is now engaged.
        box.excluded = ["a"]
        changes.send()
        XCTAssertEqual(service.upcomingEvents.map(\.id), [])
        // And a deleted meeting frees it again.
        box.excluded = []
        changes.send()
        XCTAssertEqual(service.upcomingEvents.map(\.id), ["a"])
        withExtendedLifetime(coordinator) {}
    }
}
