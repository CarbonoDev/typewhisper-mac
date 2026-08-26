import Foundation

/// [Track D] Automatic pre-meeting brief surfacing (plan AD9). Read-only helpers over the brief
/// scheduler: whether a fresh brief exists for an upcoming event (drives the "Brief ready" affordance
/// on `UpcomingMeetingsSection`) and a localized status line for the scheduler's coarse state.
extension MeetingsViewModel {
    /// Whether a fresh auto-brief exists for the meeting backing an upcoming calendar event.
    func hasFreshBrief(for event: CalendarEventDTO, now: Date = Date()) -> Bool {
        briefScheduler.hasFreshBrief(forCalendarEventID: event.id, now: now)
    }

    /// A localized, user-facing line for a currently-running automatic brief, or nil when none is
    /// running. [Track J] Derived from the job queue (plan J2): the scheduler no longer owns a coarse
    /// `status`; a running `.brief`/`.background` job *is* the "preparing" state. Failures stay silent
    /// (AD9) — a failed job simply drops out of this line rather than surfacing an alarming message.
    var autoBriefStatusMessage: String? {
        guard let job = jobQueue.jobs.first(where: {
            $0.kind == .brief && $0.priority == .background && $0.state == .running
        }),
            let meetingID = job.meetingID,
            let title = meetings.first(where: { $0.id == meetingID })?.title
        else {
            return nil
        }
        return String(format: String(localized: "meetings.brief.auto.status.preparing"), title)
    }
}
