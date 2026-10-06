import Foundation
import Combine

/// [Perf · stale-state audit] The clock for calendar-derived displays that change with time alone:
/// "in progress" / "ended" badges, the Home next-meeting card's status, the tray's countdown
/// candidate, "Today / Yesterday" headers. The 60 s poll and the unconditional republishes used to
/// re-render those for free; now `CalendarRefreshCoordinator` ticks this at exactly the instants they
/// can change (its wakes: event start, end, end + grace, the tray-title window opening, day
/// rollover). Only views that read the time observe it, so a tick re-renders nothing else.
@MainActor
final class CalendarClock: ObservableObject {
    @Published private(set) var now: Date

    init(now: Date = Date()) {
        self.now = now
    }

    func tick(_ date: Date = Date()) {
        now = date
    }
}
