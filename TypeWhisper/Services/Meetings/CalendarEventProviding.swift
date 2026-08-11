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
    /// Event description/notes as plain text (Google `description`, EventKit `notes`). nil when
    /// absent. Additive ([Google Phase 1 · M3], spec §4): the Google mapper populates it now; the
    /// EventKit provider leaves it nil until M5.
    var eventNotes: String?
    /// Video-conference join URL (Google conferenceData/hangoutLink; EventKit `url` when it looks
    /// like a known conference host). nil when absent (same M3/M5 split as `eventNotes`).
    var conferencingURL: String?
    /// Human label of the owning account for "split by account" attribution — the Google account
    /// email; nil for EventKit events (the system calendar UI already shows source via
    /// `CalendarInfo`).
    var accountLabel: String?

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
        attendees: [Attendee] = [],
        eventNotes: String? = nil,
        conferencingURL: String? = nil,
        accountLabel: String? = nil
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
        self.eventNotes = eventNotes
        self.conferencingURL = conferencingURL
        self.accountLabel = accountLabel
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

extension CalendarEventProviding {
    /// Historical/proximity query used by the "Link to calendar event…" picker (owner requirement
    /// 3): every event within `± window` of `date`. Defined as a default over the existing
    /// `events(from:to:)` seam so the whole feature stays fakeable — a test provider only has to
    /// implement `events(from:to:)` and this window arithmetic comes for free. Production
    /// (`EventKitCalendarProvider`) inherits it too; the single EventKit predicate already spans an
    /// arbitrary window, so no separate real implementation is needed.
    func events(around date: Date, window: TimeInterval) -> [CalendarEventDTO] {
        let span = abs(window)
        return events(from: date.addingTimeInterval(-span), to: date.addingTimeInterval(span))
    }
}
