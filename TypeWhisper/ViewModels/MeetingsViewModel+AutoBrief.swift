import Foundation

/// [Track D] Automatic pre-meeting brief surfacing (plan AD9). Read-only helpers over the brief
/// scheduler: whether a fresh brief exists for an upcoming event (drives the "Brief ready" affordance
/// on `UpcomingMeetingsSection`) and a localized status line for the scheduler's coarse state.
extension MeetingsViewModel {
    /// Whether a fresh auto-brief exists for the meeting backing an upcoming calendar event.
    func hasFreshBrief(for event: CalendarEventDTO, now: Date = Date()) -> Bool {
        briefScheduler.hasFreshBrief(forCalendarEventID: event.id, now: now)
    }

    /// A localized, user-facing line for the current scheduler status, or nil when idle.
    var autoBriefStatusMessage: String? {
        switch briefSchedulerStatus {
        case .idle:
            return nil
        case .generating(let title):
            return String(
                format: String(localized: "meetings.brief.auto.status.generating"),
                title
            )
        case .failed:
            // Silent-fail (AD9): surface a neutral, non-alarming line rather than the raw error.
            return String(localized: "meetings.brief.auto.status.skipped")
        }
    }
}
