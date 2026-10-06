import Foundation

/// [Perf Phase 2] Pure planner for the calendar coordinator's single one-shot timer: the next instant
/// at which anything derived from the calendar can change on its own, with no store change.
///
/// Replaces the 60 s poll. Three kinds of instant matter:
/// - **Windowing edges** — an event enters the look-ahead window, starts, ends, or leaves the
///   overrun grace (the Upcoming / Earlier split moves). Re-windowing the retained query suffices.
/// - **Consumer windows** — a time-gated consumer (start notification, auto-brief) has an event
///   entering its window. While an event is *inside* a window the consumer is re-ticked every
///   `retickInterval`, exactly the cadence the poll gave it (delivery retries, failure suppression and
///   placeholder re-creation all assume a periodic tick inside the window).
/// - **Display edges** — an event comes within `displayLeads` of its start (the tray's 60-minute
///   title window): nothing in the lists changes, but a time-driven display does (`CalendarClock`).
/// - **Refetch** — the retained query no longer covers the window (`CalendarService.nextRefetchDate`).
enum CalendarWakePlanner {
    /// A time-gated consumer's active window around an event's start: `[start − lead, start + trail]`.
    struct ConsumerWindow: Equatable, Sendable {
        var lead: TimeInterval
        var trail: TimeInterval

        func contains(_ event: CalendarEventDTO, now: Date) -> Bool {
            let untilStart = event.startDate.timeIntervalSince(now)
            return untilStart <= lead && untilStart >= -trail
        }

        func opens(for event: CalendarEventDTO) -> Date {
            event.startDate.addingTimeInterval(-lead)
        }
    }

    struct Wake: Equatable, Sendable {
        var date: Date
        /// True when the wake is the refetch deadline (a provider query), false for a re-window.
        var isRefetch: Bool
    }

    /// The poll cadence consumers keep while an event sits inside their window.
    static let retickInterval: TimeInterval = 60

    static func nextWake(
        sourceEvents: [CalendarEventDTO],
        consumerEvents: [CalendarEventDTO],
        now: Date,
        lookAhead: TimeInterval,
        grace: TimeInterval,
        consumerWindows: [ConsumerWindow],
        displayLeads: [TimeInterval] = [],
        refetchAt: Date?
    ) -> Wake? {
        var earliest: Date?
        func consider(_ date: Date) {
            guard date > now else { return }
            if earliest.map({ date < $0 }) ?? true { earliest = date }
        }

        for event in sourceEvents where !event.isAllDay {
            consider(event.startDate.addingTimeInterval(-lookAhead))
            consider(event.startDate)
            consider(event.endDate)
            consider(event.endDate.addingTimeInterval(grace))
            for lead in displayLeads {
                consider(event.startDate.addingTimeInterval(-lead))
            }
        }
        for event in consumerEvents where !event.isAllDay {
            for window in consumerWindows {
                if window.contains(event, now: now) {
                    consider(now.addingTimeInterval(retickInterval))
                } else {
                    consider(window.opens(for: event))
                }
            }
        }

        if let refetchAt, earliest.map({ refetchAt <= $0 }) ?? true {
            // A refetch also re-windows and runs the consumers, so it subsumes an equal re-window.
            return Wake(date: max(refetchAt, now), isRefetch: true)
        }
        return earliest.map { Wake(date: $0, isRefetch: false) }
    }
}
