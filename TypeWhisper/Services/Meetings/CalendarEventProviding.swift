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
    /// capture-context rules (addendum AD7) and shown as the row's calendar-name label (M11).
    /// Optional/additive — nil when unknown. This is also the event's "calendar title"; the
    /// `calendarTitle` accessor below aliases it so the M11 spec's naming is available without a
    /// second stored field (extend, don't duplicate).
    var calendarName: String?
    /// Identifier of the owning calendar (`EKCalendar.calendarIdentifier`), used to include/exclude
    /// the event by the user's calendar selection (M11). nil when unknown — treated as selected so
    /// events are never silently dropped.
    var calendarID: String?
    /// The owning calendar's display color, mapped to sRGB components at the provider boundary
    /// (M11 color coding). nil when unknown.
    var calendarColor: CalendarColor?
    var attendees: [Attendee]

    /// The owning calendar's title. Alias of `calendarName` (M11 spec calls this `calendarTitle`);
    /// kept as a computed accessor so the two names never diverge.
    var calendarTitle: String? { calendarName }

    init(
        id: String,
        title: String,
        startDate: Date,
        endDate: Date,
        isAllDay: Bool = false,
        seriesID: String? = nil,
        calendarName: String? = nil,
        calendarID: String? = nil,
        calendarColor: CalendarColor? = nil,
        attendees: [Attendee] = []
    ) {
        self.id = id
        self.title = title
        self.startDate = startDate
        self.endDate = endDate
        self.isAllDay = isAllDay
        self.seriesID = seriesID
        self.calendarName = calendarName
        self.calendarID = calendarID
        self.calendarColor = calendarColor
        self.attendees = attendees
    }
}

/// A calendar the user can include/exclude in Settings (M11). Plain value type projected from
/// `EKCalendar` at the provider boundary so the settings list renders — and is testable — without
/// EventKit.
struct CalendarInfo: Equatable, Sendable, Identifiable {
    /// `EKCalendar.calendarIdentifier`.
    var id: String
    /// Calendar title, e.g. "Work".
    var title: String
    /// Owning account / source name, e.g. "iCloud" or "Google" (`EKSource.title`).
    var sourceName: String
    /// Display color, mapped to sRGB components at the provider boundary.
    var color: CalendarColor
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
    /// Every `.event` calendar across the user's accounts, for the "Calendars" selection list
    /// (M11). Empty when access is not granted.
    func calendars() -> [CalendarInfo]
}
