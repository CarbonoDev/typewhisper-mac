import Foundation
import EventKit

/// [Perf Phase 2] Runs the rolling-window EventKit query off the main actor. EventKit queries can
/// take tens of milliseconds on a large calendar database; the old 60 s poll ran them on main.
///
/// Owns its own `EKEventStore`, created lazily on the first query — i.e. after access has been
/// granted (a store created before the grant can keep answering empty) — and only ever touched from
/// this actor. Read-only: it only issues `events(matching:)`.
actor EventKitEventQuery {
    private var store: EKEventStore?

    func events(from start: Date, to end: Date) -> [CalendarEventDTO] {
        let store = self.store ?? EKEventStore()
        self.store = store
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        return store.events(matching: predicate).map(EventKitCalendarProvider.dto(from:))
    }
}
