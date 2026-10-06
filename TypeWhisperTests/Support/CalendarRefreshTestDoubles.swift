import Combine
import Foundation
@testable import TypeWhisper

/// [Perf Phase 2] Shared doubles for the calendar coordinator tests: a counting provider, a manual
/// clock, and a wake scheduler the test fires by hand.
@MainActor
final class CountingCalendarProvider: CalendarEventProviding {
    var authorizationStatus: CalendarAuthorizationStatus = .authorized
    var eventsToReturn: [CalendarEventDTO]
    private(set) var queryCount = 0

    init(events: [CalendarEventDTO] = []) {
        self.eventsToReturn = events
    }

    func requestAccess() async -> CalendarAuthorizationStatus { authorizationStatus }

    func events(from start: Date, to end: Date) -> [CalendarEventDTO] {
        queryCount += 1
        return eventsToReturn.filter { $0.startDate <= end && $0.endDate >= start }
    }

    func calendars() -> [CalendarInfo] { [] }
}

@MainActor
final class ManualCalendarWakes {
    final class Entry: @unchecked Sendable {
        let fireAt: Date
        let action: @MainActor @Sendable () -> Void
        var isCancelled = false

        init(fireAt: Date, action: @escaping @MainActor @Sendable () -> Void) {
            self.fireAt = fireAt
            self.action = action
        }
    }

    var clock: Date
    private(set) var entries: [Entry] = []

    init(clock: Date) {
        self.clock = clock
    }

    /// The live (armed, not cancelled) wake, if any.
    var armed: Entry? { entries.last { !$0.isCancelled } }

    func schedule(_ delay: TimeInterval, _ action: @escaping @MainActor @Sendable () -> Void) -> AnyCancellable {
        let entry = Entry(fireAt: clock.addingTimeInterval(delay), action: action)
        entries.append(entry)
        return AnyCancellable { entry.isCancelled = true }
    }

    /// Advance the clock to the armed wake and fire it. Returns the time it fired at.
    @discardableResult
    func fireNext() -> Date? {
        guard let entry = armed else { return nil }
        entry.isCancelled = true
        clock = max(clock, entry.fireAt)
        entry.action()
        return clock
    }
}
