import Foundation
import AppKit
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

    /// How long an event that already *started* stays in the primary Upcoming section after its
    /// scheduled end (M10 "past/overrunning visibility"). A meeting the user is still on that runs
    /// long, or one that just ended, must not vanish the moment its scheduled end passes — it stays
    /// visible (badged "ended") until this grace elapses or the user creates/starts/dismisses it.
    static let defaultGrace: TimeInterval = 2 * 60 * 60

    @Published private(set) var authorizationStatus: CalendarAuthorizationStatus
    /// Current + upcoming + overrunning (recently-ended, within `grace`) events. This is the primary
    /// Upcoming section and the *only* list the start-notification and auto-brief paths consume; both
    /// self-gate to events at/near their start, so the added overrunning entries never trip them.
    @Published private(set) var upcomingEvents: [CalendarEventDTO] = []
    /// Already-ended events (beyond `grace`) from the lookback window (since start of day) — the
    /// collapsible "Earlier" section (M10). Unlike `upcomingEvents` these are NOT excluded when a
    /// backing meeting already exists, so a past event whose meeting exists can still be opened.
    @Published private(set) var earlierEvents: [CalendarEventDTO] = []
    @Published private(set) var errorMessage: String?

    private let provider: CalendarEventProviding
    private let selectionStore: CalendarSelectionStoring
    private let lookAhead: TimeInterval
    private let grace: TimeInterval

    /// Last query inputs, retained so `dismiss(eventID:)` can re-publish both sections without a
    /// provider round-trip (and deterministically under test).
    private var lastRawEvents: [CalendarEventDTO] = []
    private var lastNow: Date?
    private var lastExcludedEventIDs: Set<String> = []
    /// Overrunning events the user explicitly dismissed this session (M10). In-memory only —
    /// dismissal is a transient "hide it now" affordance, not persisted state.
    private var dismissedEventIDs: Set<String> = []

    init(
        provider: CalendarEventProviding = EventKitCalendarProvider(),
        selectionStore: CalendarSelectionStoring = CalendarSelectionStore(),
        lookAhead: TimeInterval = CalendarService.defaultLookAhead,
        grace: TimeInterval = CalendarService.defaultGrace
    ) {
        self.provider = provider
        self.selectionStore = selectionStore
        self.lookAhead = lookAhead
        self.grace = grace
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

    /// Re-query the provider and publish both sections. The primary `upcomingEvents` excludes events
    /// that already back an existing meeting (`existingCalendarEventIDs`); the `earlierEvents`
    /// lookback list does not, so a past event whose meeting exists can still be opened (M10). The
    /// query window is widened back to the start of `now`'s day so the lookback list has data.
    func refresh(now: Date = Date(), existingCalendarEventIDs: Set<String> = []) {
        guard authorizationStatus == .authorized else {
            lastRawEvents = []
            lastNow = now
            lastExcludedEventIDs = []
            upcomingEvents = []
            earlierEvents = []
            return
        }
        let from = CalendarService.lookbackStart(for: now)
        let raw = provider.events(from: from, to: now.addingTimeInterval(lookAhead))
        lastRawEvents = raw
        lastNow = now
        lastExcludedEventIDs = existingCalendarEventIDs
        republish()
    }

    /// Recompute both published sections from the retained last query (used by `refresh` and by
    /// `dismiss(eventID:)`), so dismissing an overrunning row updates the UI without a provider hit.
    private func republish() {
        guard let now = lastNow else { return }
        // [M11] Single filtering choke point: drop events from calendars the user has deselected
        // BEFORE any windowing, so every downstream consumer (Upcoming, Earlier, the auto-brief
        // scheduler, start notifications, and capture-context rules) sees a consistent list and a
        // deselected calendar can never generate a brief or notification. Events with no known
        // `calendarID` are kept (treated as selected) so nothing is ever silently lost.
        let selected = lastRawEvents.filter { event in
            guard let id = event.calendarID else { return true }
            return selectionStore.isSelected(id)
        }
        let excludedFromPrimary = lastExcludedEventIDs.union(dismissedEventIDs)
        upcomingEvents = CalendarService.currentUpcomingAndOverrunning(
            from: selected,
            now: now,
            lookAhead: lookAhead,
            grace: grace,
            excludingEventIDs: excludedFromPrimary
        )
        earlierEvents = CalendarService.earlierEvents(
            from: selected,
            now: now,
            since: CalendarService.lookbackStart(for: now),
            grace: grace,
            excludingEventIDs: dismissedEventIDs
        )
    }

    /// Hide an overrunning (recently-ended) event from the Upcoming section for this session — the
    /// "dismiss" arm of "visible until created / started / dismissed" (M10). Also keeps it out of
    /// the Earlier list. In-memory only.
    func dismiss(eventID: String) {
        dismissedEventIDs.insert(eventID)
        republish()
    }

    // MARK: - Calendar selection (M11)

    /// Every `.event` calendar across the user's accounts, for the "Calendars" settings list.
    func availableCalendars() -> [CalendarInfo] {
        provider.calendars()
    }

    /// Whether the given calendar is currently selected (new/unknown calendars default selected).
    func isCalendarSelected(_ calendarID: String) -> Bool {
        selectionStore.isSelected(calendarID)
    }

    /// Toggle a calendar's inclusion and immediately re-publish both event sections from the
    /// retained last query (no provider round-trip), so the lists react without waiting for the
    /// next poll.
    func setCalendarSelected(_ selected: Bool, for calendarID: String) {
        selectionStore.setSelected(selected, for: calendarID)
        republish()
    }

    /// Start of `now`'s calendar day — the lookback boundary for the Earlier section.
    static func lookbackStart(for now: Date, calendar: Calendar = .current) -> Date {
        calendar.startOfDay(for: now)
    }

    /// Time-based classification of an event relative to `now`, driving both sectioning and badges
    /// (M10). `grace` is how long a recently-ended event stays in the primary section.
    enum EventTimeStatus: Equatable, Sendable {
        /// Not yet started.
        case upcoming
        /// Started, not yet ended.
        case inProgress
        /// Ended within `grace` — still shown in the Upcoming section, badged "ended".
        case endedRecently
        /// Ended beyond `grace` — belongs only in the Earlier section.
        case ended
    }

    static func timeStatus(
        for event: CalendarEventDTO,
        now: Date,
        grace: TimeInterval = defaultGrace
    ) -> EventTimeStatus {
        if event.endDate > now {
            return event.startDate <= now ? .inProgress : .upcoming
        }
        return now < event.endDate.addingTimeInterval(grace) ? .endedRecently : .ended
    }

    /// Pure windowing for the primary section (unit-tested): current + upcoming + overrunning
    /// (recently-ended within `grace`). An event qualifies when it starts within the look-ahead
    /// window and its `timeStatus` is anything but `.ended`. All-day and excluded events are
    /// dropped. Sorted by start ascending so current/upcoming keep the visual focus.
    static func currentUpcomingAndOverrunning(
        from events: [CalendarEventDTO],
        now: Date,
        lookAhead: TimeInterval,
        grace: TimeInterval = defaultGrace,
        excludingEventIDs excluded: Set<String>
    ) -> [CalendarEventDTO] {
        let cutoff = now.addingTimeInterval(lookAhead)
        return events
            .filter { !$0.isAllDay }
            .filter { !excluded.contains($0.id) }
            .filter { $0.startDate <= cutoff }
            .filter { timeStatus(for: $0, now: now, grace: grace) != .ended }
            .sorted { $0.startDate < $1.startDate }
    }

    /// Pure windowing for the "Earlier" section (unit-tested): events that ended beyond `grace` but
    /// started on/after the lookback boundary `since`. Deliberately does NOT exclude events with a
    /// backing meeting (they navigate to it). Sorted by start descending (most recent first).
    static func earlierEvents(
        from events: [CalendarEventDTO],
        now: Date,
        since: Date,
        grace: TimeInterval = defaultGrace,
        excludingEventIDs excluded: Set<String> = []
    ) -> [CalendarEventDTO] {
        events
            .filter { !$0.isAllDay }
            .filter { !excluded.contains($0.id) }
            .filter { $0.startDate >= since }
            .filter { timeStatus(for: $0, now: now, grace: grace) == .ended }
            .sorted { $0.startDate > $1.startDate }
    }

    /// Backward-compatible pure windowing: current + upcoming only (no overrunning grace). Retained
    /// for callers/tests that want the pre-M10 "not yet ended" semantics.
    static func upcomingAndCurrent(
        from events: [CalendarEventDTO],
        now: Date,
        lookAhead: TimeInterval,
        excludingEventIDs excluded: Set<String>
    ) -> [CalendarEventDTO] {
        currentUpcomingAndOverrunning(
            from: events,
            now: now,
            lookAhead: lookAhead,
            grace: 0,
            excludingEventIDs: excluded
        )
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

    // MARK: - Link-to-past-event candidates (meeting-identity milestone, requirement 3)

    /// Default half-window for the "Link to calendar event…" search: ± 7 days around the meeting's
    /// date (the picker lets the user widen it).
    static let defaultLinkWindow: TimeInterval = 7 * 24 * 60 * 60

    /// Candidate events for linking a meeting to a historical calendar event, within `± window` of
    /// `date`, filtered by the user's calendar selection (the same choke point `republish` applies,
    /// so a deselected calendar never offers link candidates). All-day events are dropped. Returns
    /// the raw (unranked) set; `rankedLinkCandidates` orders them. Empty when access is not granted.
    func linkCandidates(around date: Date, window: TimeInterval = defaultLinkWindow) -> [CalendarEventDTO] {
        guard authorizationStatus == .authorized else { return [] }
        return provider.events(around: date, window: window)
            .filter { !$0.isAllDay }
            .filter { event in
                guard let id = event.calendarID else { return true }
                return selectionStore.isSelected(id)
            }
    }

    /// Word tokens of a title, lowercased and punctuation-stripped, for similarity scoring.
    static func titleTokens(_ title: String) -> Set<String> {
        let separators = CharacterSet.alphanumerics.inverted
        let parts = title.lowercased().components(separatedBy: separators)
        return Set(parts.filter { !$0.isEmpty })
    }

    /// Title similarity in `[0, 1]` — Jaccard overlap of word-token sets (order-independent, robust
    /// to added/dropped words). Two blank titles score `0`. Pure + unit-testable.
    static func titleSimilarity(_ a: String, _ b: String) -> Double {
        let ta = titleTokens(a)
        let tb = titleTokens(b)
        guard !ta.isEmpty, !tb.isEmpty else { return 0 }
        let intersection = ta.intersection(tb).count
        let union = ta.union(tb).count
        return union == 0 ? 0 : Double(intersection) / Double(union)
    }

    /// Date proximity in `[0, 1]`: `1` at the exact date, decaying linearly to `0` at the window
    /// edge (and `0` beyond). Pure + unit-testable.
    static func dateProximity(_ eventDate: Date, to target: Date, window: TimeInterval) -> Double {
        let span = abs(window)
        guard span > 0 else { return eventDate == target ? 1 : 0 }
        let delta = abs(eventDate.timeIntervalSince(target))
        return max(0, 1 - delta / span)
    }

    /// Combined link-candidate score: title similarity weighted above date proximity (the title is
    /// the stronger identity signal), so an exact title match a few days off still outranks an
    /// unrelated event happening at the same minute. Pure + unit-testable.
    static func linkScore(
        eventTitle: String,
        eventDate: Date,
        targetTitle: String,
        targetDate: Date,
        window: TimeInterval
    ) -> Double {
        let similarity = titleSimilarity(eventTitle, targetTitle)
        let proximity = dateProximity(eventDate, to: targetDate, window: window)
        return 0.65 * similarity + 0.35 * proximity
    }

    /// Rank candidate events for linking by `linkScore` (descending), tie-broken by date proximity
    /// then title, so the picker leads with the most likely match. Pure + unit-testable.
    static func rankedLinkCandidates(
        events: [CalendarEventDTO],
        targetTitle: String,
        targetDate: Date,
        window: TimeInterval
    ) -> [CalendarEventDTO] {
        events
            .map { event -> (event: CalendarEventDTO, score: Double, proximity: Double) in
                (
                    event,
                    linkScore(
                        eventTitle: event.title,
                        eventDate: event.startDate,
                        targetTitle: targetTitle,
                        targetDate: targetDate,
                        window: window
                    ),
                    dateProximity(event.startDate, to: targetDate, window: window)
                )
            }
            .sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                if lhs.proximity != rhs.proximity { return lhs.proximity > rhs.proximity }
                return lhs.event.title.localizedCaseInsensitiveCompare(rhs.event.title) == .orderedAscending
            }
            .map(\.event)
    }

    /// Live search filter for the picker's search-as-you-type field: keep events whose title
    /// contains `query` (case-insensitive); an empty query passes everything through unchanged.
    static func filterLinkCandidates(_ events: [CalendarEventDTO], query: String) -> [CalendarEventDTO] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return events }
        return events.filter { $0.title.localizedCaseInsensitiveContains(needle) }
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

    func calendars() -> [CalendarInfo] {
        guard authorizationStatus == .authorized else { return [] }
        return store.calendars(for: .event).map { calendar in
            CalendarInfo(
                id: calendar.calendarIdentifier,
                title: calendar.title,
                sourceName: calendar.source?.title ?? "",
                color: (calendar.color as NSColor?).map(CalendarColor.init(nsColor:)) ?? .fallback
            )
        }
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
            calendarName: event.calendar?.title,
            calendarID: event.calendar?.calendarIdentifier,
            calendarColor: event.calendar.map { ($0.color as NSColor?).map(CalendarColor.init(nsColor:)) ?? .fallback },
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
            // Speaker-recognition amendment (D-A8): carry `isCurrentUser` additively so the two-person
            // channel path can name `SPEAKER_OTHERS` from the single non-self attendee. Stored only
            // when the participant *is* the current user (`true`); a non-self participant stays `nil`
            // so "indeterminate self" and "known other" both read as `isSelf != true`.
            let isSelf: Bool? = participant.isCurrentUser ? true : nil
            return Attendee(name: participant.name ?? "", email: email(from: participant), isSelf: isSelf)
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
