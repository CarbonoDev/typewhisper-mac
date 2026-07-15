import SwiftUI
import Combine

/// Pure, SwiftUI-agnostic formatting + detection logic for the menu bar meeting indicators (owner
/// requests 3 & 4). Kept as static funcs so the tray-label truncation / elapsed formatting and the
/// upcoming-meeting lead-window detection are unit-testable without a live status item
/// (`MeetingTrayIndicatorTests`).
enum MeetingTrayIndicator {
    /// Max characters of the meeting title shown in the (space-constrained) menu bar before it is
    /// truncated with an ellipsis.
    static let titleMaxLength = 22

    /// How soon a detected calendar meeting must start before the menu bar shows the "in Xm" upcoming
    /// hint (owner request 4). A display-only window layered over the *existing* `upcomingEvents`
    /// poll — it introduces no new polling loop; the hint refreshes on each existing calendar tick.
    static let upcomingLeadWindow: TimeInterval = 10 * 60

    /// Truncate `title` to `maxLength` characters, appending an ellipsis when shortened. Empty and
    /// short titles pass through unchanged.
    static func truncatedTitle(_ title: String, maxLength: Int = titleMaxLength) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > maxLength else { return trimmed }
        let prefix = String(trimmed.prefix(max(0, maxLength - 1)))
            .trimmingCharacters(in: .whitespaces)
        return prefix + "\u{2026}"
    }

    /// `mm:ss` / `h:mm:ss` elapsed formatting. Delegates to the in-app live band so the tray elapsed
    /// matches the in-document elapsed display exactly (owner request 3): both are session-relative
    /// (time since the current start/restart), not wall time and not the meeting-timeline total.
    static func elapsed(_ seconds: TimeInterval) -> String {
        LiveRecordingBand.elapsedString(seconds)
    }

    /// The recording tray label: "<truncated title> · <elapsed>".
    static func recordingLabel(
        title: String,
        elapsedSeconds: TimeInterval,
        maxTitleLength: Int = titleMaxLength
    ) -> String {
        "\(truncatedTitle(title, maxLength: maxTitleLength)) · \(elapsed(elapsedSeconds))"
    }

    /// Whole minutes until an event start, rounded UP so a start 30 s away reads "in 1m" (never
    /// "in 0m"). Clamped to a minimum of 1.
    static func minutesUntil(_ start: Date, now: Date) -> Int {
        let seconds = start.timeIntervalSince(now)
        return max(1, Int((seconds / 60).rounded(.up)))
    }

    /// Localized "in Xm" upcoming hint for an event. Returns nil when the event does not start strictly
    /// after `now` (i.e. already in progress) — those never show the countdown hint.
    static func upcomingHint(for event: CalendarEventDTO, now: Date) -> String? {
        guard event.startDate > now else { return nil }
        let minutes = minutesUntil(event.startDate, now: now)
        return String(format: String(localized: "meetings.tray.upcoming.inMinutes"), minutes)
    }

    /// The soonest calendar meeting that starts strictly after `now` and within `leadWindow` — the
    /// tray's upcoming candidate (owner request 4). Reuses the existing `upcomingEvents` detection
    /// rather than a new query; all-day events are excluded (mirrors the start-notification gate).
    static func nextUpcoming(
        events: [CalendarEventDTO],
        now: Date,
        leadWindow: TimeInterval = upcomingLeadWindow
    ) -> CalendarEventDTO? {
        events
            .filter { !$0.isAllDay }
            .filter { $0.startDate > now && $0.startDate <= now.addingTimeInterval(leadWindow) }
            .min { $0.startDate < $1.startDate }
    }
}

/// Lightweight menu-bar state for the meeting tray indicators (owner requests 3 & 4). Subscribes to
/// only the capture/calendar publishers the tray label needs, mirroring `MenuBarState`'s pattern so
/// the status item never re-renders on high-frequency, unrelated view-model churn. The elapsed value
/// is driven by the capture service's existing 1 s timer (which runs *only* while recording and is
/// invalidated on stop) — this state adds no timer of its own, so there are zero idle wakeups.
@MainActor
final class MeetingTrayState: ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var meetingTitle = ""
    @Published private(set) var elapsedSeconds: TimeInterval = 0
    /// The soonest upcoming calendar meeting within the lead window, or nil. Recomputed on each
    /// `upcomingEvents` publish (the existing calendar poll), never on a timer.
    @Published private(set) var upcomingEvent: CalendarEventDTO?

    private var cancellables = Set<AnyCancellable>()

    init() {
        let viewModel = MeetingsViewModel.shared
        isRecording = viewModel.isCapturing
        meetingTitle = viewModel.activeMeeting?.title ?? ""
        elapsedSeconds = viewModel.captureElapsedSeconds
        recomputeUpcoming(viewModel.upcomingEvents)

        viewModel.$isCapturing
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in self?.isRecording = value }
            .store(in: &cancellables)
        viewModel.$activeMeeting
            .receive(on: DispatchQueue.main)
            .sink { [weak self] meeting in self?.meetingTitle = meeting?.title ?? "" }
            .store(in: &cancellables)
        viewModel.$captureElapsedSeconds
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in self?.elapsedSeconds = value }
            .store(in: &cancellables)
        viewModel.$upcomingEvents
            .receive(on: DispatchQueue.main)
            .sink { [weak self] events in self?.recomputeUpcoming(events) }
            .store(in: &cancellables)
    }

    private func recomputeUpcoming(_ events: [CalendarEventDTO]) {
        upcomingEvent = MeetingTrayIndicator.nextUpcoming(events: events, now: Date())
    }
}
