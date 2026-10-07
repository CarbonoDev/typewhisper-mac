import Foundation

/// Keeps untouched calendar-linked meetings in step with their events.
///
/// Google's `singleEvents=true` instance ids are keyed on the occurrence's *original* start
/// (`<recurringEventId>_<originalStartTime>`), so a moved occurrence keeps its id — and the
/// `Meeting.calendarEventID` linked to it — while its start/end change. A `.scheduled` meeting
/// created before the move (an auto-brief placeholder, or one created from Upcoming) would otherwise
/// keep the old dates forever, and the now-card / capture path would treat it as yesterday's.
///
/// Pure planning lives here (`changes`); `MeetingService.applyCalendarReconciliation` writes the
/// result. Engaged meetings — left `.scheduled`, or holding a transcript — are never touched:
/// a recording that happened is a fact.
enum CalendarMeetingReconciler {
    /// The fields of one meeting to rewrite from its event. `nil` leaves a field as is.
    struct Change: Equatable {
        let meetingID: UUID
        var startDate: Date?
        var endDate: Date?
        var title: String?
        var calendarNotes: String?
        var conferencingURL: String?
    }

    /// Whether `meeting` has never been engaged: still `.scheduled` and no transcript. Pre-meeting
    /// notes typed into a placeholder are preparation, not engagement — it still follows its event.
    @MainActor
    static func isUntouched(_ meeting: Meeting) -> Bool {
        meeting.state == .scheduled && !meeting.hasTranscript
    }

    /// The writes that bring each untouched `.scheduled` meeting in line with the event it links to.
    ///
    /// - `previousTitles`: the projected title each event had on the previous pass. A meeting's
    ///   title follows its event only when it still equals that previous projection, so a user
    ///   rename is never clobbered; with no previous title known, the title is left alone.
    /// - Notes / join link are refreshed only to a non-nil event value (a provider that does not
    ///   report them must not erase the snapshot).
    @MainActor
    static func changes(
        meetings: [Meeting],
        events: [CalendarEventDTO],
        previousTitles: [String: String] = [:]
    ) -> [Change] {
        guard !events.isEmpty else { return [] }
        // One pass over the store: only `.scheduled` linked meetings are candidates.
        var byEventID: [String: Meeting] = [:]
        for meeting in meetings where meeting.state == .scheduled {
            guard let eventID = meeting.calendarEventID, byEventID[eventID] == nil else { continue }
            byEventID[eventID] = meeting
        }
        guard !byEventID.isEmpty else { return [] }

        var result: [Change] = []
        for event in events {
            guard let meeting = byEventID.removeValue(forKey: event.id) else { continue }
            var change = Change(meetingID: meeting.id)
            var differs = false
            if meeting.startDate != event.startDate {
                change.startDate = event.startDate
                differs = true
            }
            if meeting.endDate != event.endDate {
                change.endDate = event.endDate
                differs = true
            }
            let projected = CalendarService.meetingProjection(for: event).title
            if let previous = previousTitles[event.id], previous != projected,
               meeting.title == previous {
                change.title = projected
                differs = true
            }
            if let notes = event.eventNotes, notes != meeting.calendarNotes {
                change.calendarNotes = notes
                differs = true
            }
            if let url = event.conferencingURL, url != meeting.conferencingURL {
                change.conferencingURL = url
                differs = true
            }
            // The transcript check only for the (rare) meeting that actually differs.
            guard differs, isUntouched(meeting) else { continue }
            result.append(change)
        }
        return result
    }
}

/// Runs the reconciler after every calendar refetch, remembering each event's projected title from
/// the previous pass (the "old projected title" the rename guard compares against). Session-only:
/// on the first pass after launch no title is known, so only dates / notes / link follow.
@MainActor
final class LinkedMeetingCalendarSync {
    private let meetingService: MeetingService
    private var previousTitles: [String: String] = [:]

    init(meetingService: MeetingService) {
        self.meetingService = meetingService
    }

    func reconcile(_ events: [CalendarEventDTO]) {
        let changes = CalendarMeetingReconciler.changes(
            meetings: meetingService.meetings,
            events: events,
            previousTitles: previousTitles
        )
        meetingService.applyCalendarReconciliation(changes)
        previousTitles = Dictionary(
            events.map { ($0.id, CalendarService.meetingProjection(for: $0).title) },
            uniquingKeysWith: { first, _ in first }
        )
    }
}
