import Foundation

/// Whether the app may read calendar events. Mirrors the granular macOS 14 EventKit
/// authorization states but stays decoupled from `EKAuthorizationStatus` so that views and
/// tests never need to import EventKit.
enum CalendarAuthorizationStatus: Equatable, Sendable {
    case notDetermined
    case denied
    case restricted
    case authorized
}

/// A calendar event projected into a plain value type, decoupled from `EKEvent`, so the
/// windowing/projection logic is unit-testable without a live `EKEventStore` (see plan D10,
/// brief §8: "Wrap `EKEventStore` behind a protocol for testability").
struct CalendarEventDTO: Equatable, Sendable, Identifiable {
    /// Stable per-*occurrence* identifier. For recurring events all occurrences share one
    /// `EKEvent.eventIdentifier`, so the provider composes it with the occurrence start
    /// (`"\(eventIdentifier)#\(startDate.timeIntervalSince1970)"`); also stored on the created
    /// `Meeting.calendarEventID` and used for dedupe, so each occurrence dedupes independently.
    var id: String
    var title: String
    var startDate: Date
    var endDate: Date
    var isAllDay: Bool
    /// Recurrence-series identifier (`EKEvent.calendarItemExternalIdentifier` when the event
    /// has recurrence rules), used to match a meeting against prior occurrences.
    var seriesID: String?
    /// Name of the calendar (EventKit source list) the event belongs to, e.g. "Work". Used by
    /// capture-context rules (addendum AD7). Optional/additive — nil when unknown.
    var calendarName: String?
    var attendees: [Attendee]

    init(
        id: String,
        title: String,
        startDate: Date,
        endDate: Date,
        isAllDay: Bool = false,
        seriesID: String? = nil,
        calendarName: String? = nil,
        attendees: [Attendee] = []
    ) {
        self.id = id
        self.title = title
        self.startDate = startDate
        self.endDate = endDate
        self.isAllDay = isAllDay
        self.seriesID = seriesID
        self.calendarName = calendarName
        self.attendees = attendees
    }
}

/// Fakeable seam over `EKEventStore`. Production uses `EventKitCalendarProvider`; tests inject
/// a synthetic provider returning canned DTOs so CI never touches the live calendar store.
@MainActor
protocol CalendarEventProviding: AnyObject {
    /// Current read authorization, without prompting.
    var authorizationStatus: CalendarAuthorizationStatus { get }
    /// Prompt for (or re-check) full calendar access and return the resulting status.
    func requestAccess() async -> CalendarAuthorizationStatus
    /// Events overlapping the `[start, end]` window. Ordering is not guaranteed by the seam;
    /// `CalendarService` sorts.
    func events(from start: Date, to end: Date) -> [CalendarEventDTO]
}
