import Foundation
import Combine
import EventKit
import os.log

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "TypeWhisper", category: "CalendarService")

/// Read-only calendar integration (plan D10). Wraps `EKEventStore` behind
/// `CalendarEventProviding`, surfaces the current/upcoming events in a rolling window, and
/// projects a chosen event into the parameters for a `.calendar`-sourced `Meeting`.
///
/// Detection is poll + prompt: EventKit reports that a meeting is *scheduled*, never that it
/// *started*, so the app only ever prompts the user to create/capture a meeting — it never
/// silently records.
@MainActor
final class CalendarService: ObservableObject {
    /// How far ahead of "now" an event may start and still be shown (also includes any event
    /// already in progress). 12 hours covers "the rest of today" without listing next week.
    static let defaultLookAhead: TimeInterval = 12 * 60 * 60

    @Published private(set) var authorizationStatus: CalendarAuthorizationStatus
    @Published private(set) var upcomingEvents: [CalendarEventDTO] = []
    @Published private(set) var errorMessage: String?

    private let provider: CalendarEventProviding
    private let lookAhead: TimeInterval

    init(
        provider: CalendarEventProviding = EventKitCalendarProvider(),
        lookAhead: TimeInterval = CalendarService.defaultLookAhead
    ) {
        self.provider = provider
        self.lookAhead = lookAhead
        self.authorizationStatus = provider.authorizationStatus
        updateErrorMessage(for: provider.authorizationStatus)
    }

    var isAuthorized: Bool { authorizationStatus == .authorized }

    // MARK: - Permission

    /// Prompt for calendar access (or re-check an existing decision) and refresh on success.
    /// `now` mirrors the `refresh(now:)` seam so the refresh triggered here is time-deterministic
    /// under test; production passes the default wall-clock time.
    func requestAccess(now: Date = Date()) async {
        let status = await provider.requestAccess()
        authorizationStatus = status
        updateErrorMessage(for: status)
        if status == .authorized {
            refresh(now: now)
        }
    }

    private func updateErrorMessage(for status: CalendarAuthorizationStatus) {
        switch status {
        case .denied, .restricted:
            errorMessage = String(localized: "meetings.calendar.accessDenied")
        case .notDetermined, .authorized:
            errorMessage = nil
        }
    }

    // MARK: - Query

    /// Re-query the provider and publish the current/upcoming events, excluding events that
    /// already back an existing meeting (`existingCalendarEventIDs`).
    func refresh(now: Date = Date(), existingCalendarEventIDs: Set<String> = []) {
        guard authorizationStatus == .authorized else {
            upcomingEvents = []
            return
        }
        let raw = provider.events(from: now, to: now.addingTimeInterval(lookAhead))
        upcomingEvents = CalendarService.upcomingAndCurrent(
            from: raw,
            now: now,
            lookAhead: lookAhead,
            excludingEventIDs: existingCalendarEventIDs
        )
    }

    /// Pure windowing (unit-tested). An event qualifies when it has not yet ended and starts
    /// within the look-ahead window; this naturally covers both currently-running and upcoming
    /// events. All-day events and already-captured events are excluded. Result is sorted by
    /// start date ascending.
    static func upcomingAndCurrent(
        from events: [CalendarEventDTO],
        now: Date,
        lookAhead: TimeInterval,
        excludingEventIDs excluded: Set<String>
    ) -> [CalendarEventDTO] {
        let cutoff = now.addingTimeInterval(lookAhead)
        return events
            .filter { !$0.isAllDay }
            .filter { !excluded.contains($0.id) }
            .filter { $0.endDate > now && $0.startDate <= cutoff }
            .sorted { $0.startDate < $1.startDate }
    }

    /// Whether the event is happening right now (started, not yet ended). Used for the
    /// "in progress" badge.
    static func isCurrent(_ event: CalendarEventDTO, now: Date = Date()) -> Bool {
        event.startDate <= now && event.endDate > now
    }

    // MARK: - Projection

    /// Parameters for a `.calendar`-sourced `Meeting` derived from an event (pure, unit-tested).
    /// The store write itself is performed by `MeetingService` via `MeetingsViewModel` so the
    /// sole-writer invariant holds.
    struct MeetingProjection: Equatable {
        var title: String
        var startDate: Date
        var endDate: Date
        var calendarEventID: String
        var seriesID: String?
        var attendees: [Attendee]
    }

    static func meetingProjection(for event: CalendarEventDTO) -> MeetingProjection {
        let trimmed = event.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = trimmed.isEmpty ? String(localized: "meetings.calendar.untitledEvent") : trimmed
        return MeetingProjection(
            title: title,
            startDate: event.startDate,
            endDate: event.endDate,
            calendarEventID: event.id,
            seriesID: event.seriesID,
            attendees: event.attendees
        )
    }
}

/// Real `CalendarEventProviding` conformance over `EKEventStore`. Read-only, local store,
/// macOS 14 granular API (`requestFullAccessToEvents`). Hardened runtime kills the process on
/// first store access without `NSCalendarsFullAccessUsageDescription` in Info.plist.
@MainActor
final class EventKitCalendarProvider: CalendarEventProviding {
    private let store = EKEventStore()

    var authorizationStatus: CalendarAuthorizationStatus {
        Self.map(EKEventStore.authorizationStatus(for: .event))
    }

    func requestAccess() async -> CalendarAuthorizationStatus {
        do {
            _ = try await store.requestFullAccessToEvents()
        } catch {
            logger.error("Calendar access request failed: \(error.localizedDescription)")
        }
        return authorizationStatus
    }

    func events(from start: Date, to end: Date) -> [CalendarEventDTO] {
        guard authorizationStatus == .authorized else { return [] }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        return store.events(matching: predicate).map(Self.dto(from:))
    }

    // MARK: - Mapping

    private static func map(_ status: EKAuthorizationStatus) -> CalendarAuthorizationStatus {
        switch status {
        case .notDetermined: return .notDetermined
        case .restricted: return .restricted
        case .denied: return .denied
        case .fullAccess: return .authorized
        case .writeOnly: return .denied // write-only cannot read events
        @unknown default: return .denied
        }
    }

    private static func dto(from event: EKEvent) -> CalendarEventDTO {
        CalendarEventDTO(
            id: occurrenceID(for: event),
            title: event.title ?? "",
            startDate: event.startDate,
            endDate: event.endDate,
            isAllDay: event.isAllDay,
            seriesID: event.hasRecurrenceRules ? event.calendarItemExternalIdentifier : nil,
            attendees: attendees(from: event)
        )
    }

    /// Occurrence-scoped identifier. All occurrences of a recurring series returned by
    /// `predicateForEvents` share the same `EKEvent.eventIdentifier` (and `event(withIdentifier:)`
    /// only ever returns the first occurrence), so using the bare identifier would collapse an
    /// entire series into a single dedupe key: creating a meeting from one occurrence would
    /// permanently exclude every future occurrence from the upcoming list and make
    /// `createMeeting(from:)` return a stale prior-occurrence meeting. Composing the identifier
    /// with the occurrence start keeps each occurrence distinct, while `seriesID`
    /// (`calendarItemExternalIdentifier`) still groups the series for `priorMeetings(matching:)`.
    private static func occurrenceID(for event: EKEvent) -> String {
        let base = event.eventIdentifier ?? UUID().uuidString
        // `event.startDate` is the occurrence start for recurring events.
        return "\(base)#\(event.startDate.timeIntervalSince1970)"
    }

    private static func attendees(from event: EKEvent) -> [Attendee] {
        guard let participants = event.attendees else { return [] }
        return participants.map { participant in
            Attendee(name: participant.name ?? "", email: email(from: participant))
        }
    }

    private static func email(from participant: EKParticipant) -> String? {
        // EventKit exposes an attendee's address only via a `mailto:` URL.
        let string = participant.url.absoluteString
        guard string.lowercased().hasPrefix("mailto:") else { return nil }
        let address = String(string.dropFirst("mailto:".count))
        return address.isEmpty ? nil : address
    }
}
