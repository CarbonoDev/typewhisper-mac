import Combine
import Foundation

/// An upcoming calendar event projected for the "Coming up" card: the event plus its resolved
/// color (via the `CalendarColorProviding` seam), its time status, and whether it is running long.
struct ComingUpItem: Identifiable {
    var event: CalendarEventDTO
    var color: CalendarColor
    var timeStatus: CalendarService.EventTimeStatus
    var isRunningLong: Bool

    var id: String { event.id }
}

/// View model for the meetings Home feed (plan Track C / D6). Registered as `.shared` in
/// `ServiceContainer`. It owns the two M10/M11 **seams** — the calendar color source and the
/// running-long predicate — and turns `MeetingsViewModel.shared`'s published calendar/meeting state
/// into the card + timeline projections the Home views render. All heavy grouping/badge logic lives
/// as pure statics on `MeetingsViewModel+Home` (frozen-VM extension); this class only wires in the
/// seams and the "now" clock, so it stays a thin, testable adapter with no stored meeting state.
@MainActor
final class HomeFeedViewModel: ObservableObject {
    nonisolated(unsafe) static var _shared: HomeFeedViewModel?
    static var shared: HomeFeedViewModel {
        guard let instance = _shared else {
            fatalError("HomeFeedViewModel not initialized")
        }
        return instance
    }

    /// The calendar color seam (default palette today; swaps for M11's real per-calendar API with no
    /// structural change — D6).
    private let colorProvider: CalendarColorProviding
    private let calendar: Calendar

    init(
        colorProvider: CalendarColorProviding = DefaultCalendarColorProvider(),
        calendar: Calendar = .current
    ) {
        self.colorProvider = colorProvider
        self.calendar = calendar
    }

    // MARK: - Color seam

    func color(for event: CalendarEventDTO) -> CalendarColor {
        colorProvider.color(for: event)
    }

    // MARK: - Running-long seam (M10 remainder)

    /// Whether an upcoming/current event is "running long": it has passed its end time but no
    /// completed meeting is linked to it yet, so it may still be recording. Default implementation
    /// per D6; swaps to M10's in-flight running-long API when it merges, with no structural change.
    func isRunningLong(
        event: CalendarEventDTO,
        existingMeeting: Meeting?,
        now: Date = Date()
    ) -> Bool {
        guard event.endDate < now else { return false }
        guard let existingMeeting else { return true }
        return existingMeeting.state != .completed
    }

    /// Whether a stored meeting is running long: still marked live while its scheduled end has
    /// passed (an in-progress capture that overran its calendar slot).
    func isRunningLong(meeting: Meeting, now: Date = Date()) -> Bool {
        guard meeting.state == .live else { return false }
        guard let end = meeting.endDate else { return false }
        return end < now
    }

    // MARK: - Coming-up projection

    /// Project the calendar's upcoming/current events into color-coded card items.
    func comingUp(
        from events: [CalendarEventDTO],
        existingMeeting: (CalendarEventDTO) -> Meeting?,
        now: Date = Date()
    ) -> [ComingUpItem] {
        events.map { event in
            ComingUpItem(
                event: event,
                color: color(for: event),
                timeStatus: CalendarService.timeStatus(for: event, now: now),
                isRunningLong: isRunningLong(
                    event: event,
                    existingMeeting: existingMeeting(event),
                    now: now
                )
            )
        }
    }

    // MARK: - Timeline projection

    /// Day-grouped meetings for the timeline, newest first.
    func timelineGroups(from meetings: [Meeting]) -> [MeetingDayGroup] {
        MeetingsViewModel.homeDayGroups(from: meetings, calendar: calendar)
    }

    /// The ordered state badges for one meeting row.
    func badges(for meeting: Meeting, now: Date = Date()) -> [MeetingBadge] {
        let facts = MeetingsViewModel.homeBadgeFacts(
            for: meeting,
            isRunningLong: isRunningLong(meeting: meeting, now: now)
        )
        return MeetingsViewModel.homeBadges(for: facts)
    }

    /// Localized section header for a day group (Tomorrow / weekday / Today / Yesterday / weekday /
    /// date). All formatting flows through the injected `calendar` and its time zone so headers stay
    /// correct under a non-system-zone calendar (e.g. in tests) and across DST boundaries.
    func groupTitle(for group: MeetingDayGroup, now: Date = Date()) -> String {
        switch MeetingsViewModel.homeDayBucket(for: group.date, now: now, calendar: calendar) {
        case .future(let date):
            let daysAhead = calendar.dateComponents(
                [.day], from: calendar.startOfDay(for: now), to: date
            ).day ?? 0
            if daysAhead == 1 { return String(localized: "home.timeline.tomorrow") }
            if daysAhead < 7 { return weekdayTitle(for: date) }
            return dateTitle(for: date)
        case .today:
            return String(localized: "home.timeline.today")
        case .yesterday:
            return String(localized: "home.timeline.yesterday")
        case .earlierThisWeek(let date):
            return weekdayTitle(for: date)
        case .older(let date):
            return dateTitle(for: date)
        }
    }

    /// Weekday name (e.g. "Monday") in the injected calendar/time zone.
    private func weekdayTitle(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate("EEEE")
        return formatter.string(from: date)
    }

    /// Localized month/day/year in the injected calendar/time zone.
    private func dateTitle(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate("yMMMd")
        return formatter.string(from: date)
    }
}
