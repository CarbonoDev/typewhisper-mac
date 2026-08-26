import Foundation

/// Cross-provider twin collapse for the *automatic* consumers of the fanned-in event list
/// ([Google Phase 1 · M4], D-G6 amendment — PR #7 review finding 4).
///
/// When a Google account is also synced into macOS Calendar via CalDAV, the same real event
/// arrives twice with unrelated IDs (`google:<sub>:<raw>` and `<uuid>#<ts>`). D-G6 answers the
/// *visible* half of that with calendar-level deselection, which the user must first be prompted
/// for. Until then — and forever, if the user chooses "Keep both" — every automatic consumer acts
/// twice: `MeetingBriefScheduler` dedupes strictly on `calendarEventID`, so it auto-creates two
/// meeting documents and enqueues two `relatedDiscovery` + two `brief` jobs on the cap-1 `llm`
/// lane, and `MeetingStartNotificationService` posts two "meeting starting" notifications.
///
/// This collapser therefore runs at the *consumer* boundary only (the `$upcomingEvents` sink in
/// `MeetingsViewModel`): the published event lists and the Calendars selection UI still show both
/// copies, so nothing is hidden invisibly and the D-G6 prompt keeps making sense — but the paths
/// that spend tokens and post notifications see one event.
///
/// The collapse key is deliberately narrow (D-G6's objection to event-level suppression was that
/// *wrong* matches hide real events):
///   - identity = the D-G8 `seriesID` — the bare `iCalUID`, which is exactly why it was chosen —
///     falling back to the trimmed, case-folded title for non-recurring events;
///   - **plus** the exact start *and* end instants (a same-titled adjacent occurrence never
///     matches);
///   - **and** the group must span both providers (≥1 namespaced Google ID and ≥1 bare EventKit
///     ID). Two copies from the same side (two Google accounts invited to the same event, §8) are
///     never collapsed.
///
/// The Google copy wins — it carries the richer detail (conference entry points, RSVP, organizer).
/// Pure, no I/O: fully covered by `CalendarEventTwinCollapserTests`.
enum CalendarEventTwinCollapser {
    /// The narrow twin identity: what must match for two events to be considered the same real
    /// event arriving from two providers.
    struct CollapseKey: Hashable {
        let identity: String
        let start: Date
        let end: Date
    }

    /// The key for an event, or `nil` when it carries no usable identity (no series id and a blank
    /// title) — such an event is never collapsed.
    static func collapseKey(for event: CalendarEventDTO) -> CollapseKey? {
        let series = event.seriesID?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let identity: String
        if let series, !series.isEmpty {
            identity = "series:\(series)"
        } else {
            let title = event.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !title.isEmpty else { return nil }
            identity = "title:\(title)"
        }
        return CollapseKey(identity: identity, start: event.startDate, end: event.endDate)
    }

    /// One entry per real event, preferring the Google copy of a cross-provider twin pair. Input
    /// order is otherwise preserved.
    static func collapse(_ events: [CalendarEventDTO]) -> [CalendarEventDTO] {
        var groups: [CollapseKey: [Int]] = [:]
        for (index, event) in events.enumerated() {
            guard let key = collapseKey(for: event) else { continue }
            groups[key, default: []].append(index)
        }

        var dropped = Set<Int>()
        for (_, indices) in groups where indices.count > 1 {
            let googleIndices = indices.filter {
                GoogleCalendarID.accountSub(fromNamespacedID: events[$0].id) != nil
            }
            // Cross-provider only: a group entirely on one side is left alone.
            guard let winner = googleIndices.first, googleIndices.count < indices.count else {
                continue
            }
            for index in indices where index != winner {
                dropped.insert(index)
            }
        }

        guard !dropped.isEmpty else { return events }
        return events.enumerated().filter { !dropped.contains($0.offset) }.map(\.element)
    }
}
