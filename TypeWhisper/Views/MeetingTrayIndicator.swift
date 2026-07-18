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

    /// How soon a detected calendar meeting must start before the menu-bar *menu* shows the
    /// "Upcoming: …" entry (`nextUpcoming`). Kept narrow — this governs the in-menu entry only.
    static let upcomingLeadWindow: TimeInterval = 10 * 60

    /// How far ahead a meeting may start and still be surfaced as the tray *title* + countdown
    /// (owner requests 1 & 2). Deliberately wider than `upcomingLeadWindow` because the owner's
    /// reference shows a meeting ~39 min out; the default is 60 minutes. A display-only window
    /// layered over the *existing* `upcomingEvents` poll — it adds no new polling loop.
    static let trayTitleWindow: TimeInterval = 60 * 60

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
    /// after `now` (i.e. already in progress) — those never show the countdown hint. Used by the
    /// in-menu "Upcoming: …" entry; the tray *title* uses `countdown(start:now:)` (which also has a
    /// past-start "now" form).
    static func upcomingHint(for event: CalendarEventDTO, now: Date) -> String? {
        guard event.startDate > now else { return nil }
        return countdown(start: event.startDate, now: now)
    }

    /// Localized Granola-style countdown for the tray title (owner request 1). Minutes-only under an
    /// hour ("in 39m"); hours+minutes above ("in 1h 5m"); whole hours collapse the minute part
    /// ("in 1h"); and once the start time has passed while the meeting is still current it reads as a
    /// localized "now". Minutes round UP (via `minutesUntil`), so a start 30 s away reads "in 1m".
    static func countdown(start: Date, now: Date) -> String {
        guard start > now else {
            return String(localized: "meetings.tray.countdown.now")
        }
        let minutes = minutesUntil(start, now: now)
        if minutes < 60 {
            return String(format: String(localized: "meetings.tray.upcoming.inMinutes"), minutes)
        }
        let hours = minutes / 60
        let remainder = minutes % 60
        if remainder == 0 {
            return String(format: String(localized: "meetings.tray.upcoming.inHours"), hours)
        }
        return String(format: String(localized: "meetings.tray.upcoming.inHoursMinutes"), hours, remainder)
    }

    /// The tray-title label for a meeting (owner request 1): "<truncated title> · <countdown>",
    /// e.g. "test · in 39m". Mirrors Granola's tray text — the glyph is supplied by the view.
    static func trayLabel(
        title: String,
        start: Date,
        now: Date,
        maxTitleLength: Int = titleMaxLength
    ) -> String {
        "\(truncatedTitle(title, maxLength: maxTitleLength)) · \(countdown(start: start, now: now))"
    }

    /// What the tray title resolves to, in strict precedence order. Pure so the recording-over-upcoming
    /// precedence (owner request 4) and the idle plain-glyph fallback are unit-testable without a live
    /// status item.
    enum Display: Equatable {
        /// A meeting capture is recording: record glyph + "<title> · <elapsed>".
        case recording(label: String)
        /// No recording, but an in-progress/upcoming meeting is within the tray window: calendar glyph
        /// + "<title> · <countdown>".
        case upcoming(label: String)
        /// Neither applies — the plain menu-bar glyph, zero-cost.
        case idle
    }

    /// Resolve the tray title. Recording wins whenever a meeting capture is active with a title;
    /// otherwise the caller passes the (already recording-suppressed) upcoming candidate. Callers gate
    /// `upcoming` to nil while an unrelated dictation/recorder capture owns the icon, so the recording
    /// state always takes precedence over the upcoming label.
    static func display(
        isRecording: Bool,
        recordingTitle: String,
        elapsedSeconds: TimeInterval,
        upcoming: CalendarEventDTO?,
        now: Date
    ) -> Display {
        if isRecording, !recordingTitle.isEmpty {
            return .recording(label: recordingLabel(title: recordingTitle, elapsedSeconds: elapsedSeconds))
        }
        if let upcoming {
            return .upcoming(label: trayLabel(title: upcoming.title, start: upcoming.startDate, now: now))
        }
        return .idle
    }

    /// The soonest calendar meeting that starts strictly after `now` and within `leadWindow` — the
    /// in-*menu* "Upcoming: …" candidate. Reuses the existing `upcomingEvents` detection rather than
    /// a new query; all-day events are excluded (mirrors the start-notification gate).
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

    /// The meeting the tray *title* should surface (owner requests 1 & 2): the currently in-progress
    /// meeting (started, not yet ended) if one exists, otherwise the soonest meeting starting within
    /// `leadWindow` (default 60 min). All-day events are excluded. Independent of `nextUpcoming`,
    /// which keeps its narrower future-only window for the menu entry. Reuses the existing
    /// `upcomingEvents` snapshot; recomputed against a fresh `now` so the countdown decrements and the
    /// candidate transitions to the "now" form without any calendar re-query.
    static func trayCandidate(
        events: [CalendarEventDTO],
        now: Date,
        leadWindow: TimeInterval = trayTitleWindow
    ) -> CalendarEventDTO? {
        let considered = events.filter { !$0.isAllDay }
        if let current = considered
            .filter({ $0.startDate <= now && $0.endDate > now })
            .min(by: { $0.startDate < $1.startDate }) {
            return current
        }
        return considered
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
    /// How often the tray title's countdown refreshes *while it is visible* (owner request 1). No
    /// always-on 1 s timer: this ticker exists only while an upcoming/in-progress meeting is being
    /// shown and is torn down the moment the indicator disappears (or a recording takes over), so the
    /// idle menu bar has zero wakeups. Minutes-granularity copy makes a 45 s cadence imperceptible.
    private static let countdownTickInterval: TimeInterval = 45

    @Published private(set) var isRecording = false
    @Published private(set) var meetingTitle = ""
    @Published private(set) var elapsedSeconds: TimeInterval = 0
    /// The in-progress or soonest-upcoming calendar meeting within the tray window, or nil. Recomputed
    /// on each `upcomingEvents` publish (the existing calendar poll) and on the visible-only countdown
    /// ticker below.
    @Published private(set) var upcomingEvent: CalendarEventDTO?
    /// The clock the tray-title countdown is rendered against. Bumped by the countdown ticker so the
    /// label re-renders (e.g. "in 39m" → "in 38m") without touching the recording elapsed timer.
    @Published private(set) var trayNow = Date()

    private var cancellables = Set<AnyCancellable>()
    /// Latest calendar snapshot, retained so the countdown ticker can recompute the candidate against
    /// a fresh `now` without a calendar re-query.
    private var lastEvents: [CalendarEventDTO] = []
    /// Runs only while the tray title is visible (see `updateCountdownTicker`).
    private var countdownTicker: AnyCancellable?

    init() {
        let viewModel = MeetingsViewModel.shared
        isRecording = viewModel.isCapturing
        meetingTitle = viewModel.activeMeeting?.title ?? ""
        elapsedSeconds = viewModel.captureElapsedSeconds
        recomputeUpcoming(viewModel.upcomingEvents)

        viewModel.$isCapturing
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in
                self?.isRecording = value
                // Recording takes precedence over the upcoming title, so the countdown ticker is
                // pointless (and its wakeups wasteful) while capturing.
                self?.updateCountdownTicker()
            }
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
        lastEvents = events
        refreshUpcoming()
    }

    /// Recompute the tray candidate against the current wall clock and (re)start or stop the ticker.
    private func refreshUpcoming() {
        trayNow = Date()
        upcomingEvent = MeetingTrayIndicator.trayCandidate(events: lastEvents, now: trayNow)
        updateCountdownTicker()
    }

    /// The countdown ticker runs iff the tray title is actually visible: an upcoming/in-progress
    /// meeting exists AND no recording is taking precedence. Otherwise it is torn down (zero idle
    /// wakeups when the menu bar shows the plain glyph).
    private func updateCountdownTicker() {
        let shouldTick = upcomingEvent != nil && !isRecording
        if shouldTick {
            guard countdownTicker == nil else { return }
            countdownTicker = Timer
                .publish(every: Self.countdownTickInterval, on: .main, in: .common)
                .autoconnect()
                .sink { [weak self] _ in self?.refreshUpcoming() }
        } else {
            countdownTicker?.cancel()
            countdownTicker = nil
        }
    }
}
