import Foundation

extension MeetingService {
    /// Apply `CalendarMeetingReconciler` changes in one save. An in-place write: membership is
    /// unchanged, and `commitWrite(.inPlace)` refetches on its own when a moved `startDate` breaks
    /// the published fetch order (a date change can re-sort the list), so `.list` would only force
    /// a republish on writes that do not need one.
    func applyCalendarReconciliation(_ changes: [CalendarMeetingReconciler.Change]) {
        guard !changes.isEmpty else { return }
        let wanted = Set(changes.map(\.meetingID))
        let byID = Dictionary(
            meetings.lazy.filter { wanted.contains($0.id) }.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let now = Date()
        var wrote = false
        for change in changes {
            guard let meeting = byID[change.meetingID] else { continue }
            if let start = change.startDate { meeting.startDate = start }
            if let end = change.endDate { meeting.endDate = end }
            if let title = change.title { meeting.title = title }
            if let notes = change.calendarNotes { meeting.calendarNotes = notes }
            if let url = change.conferencingURL { meeting.conferencingURL = url }
            meeting.updatedAt = now
            wrote = true
        }
        if wrote { commitWrite(.inPlace) }
    }
}
