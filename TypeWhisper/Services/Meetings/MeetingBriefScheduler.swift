import Foundation
import Combine
import os.log

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "TypeWhisper", category: "MeetingBriefScheduler")

/// Store seam the scheduler needs from `MeetingService` (plan AD9). Kept as a narrow protocol so the
/// scheduler is unit-testable against an in-memory `MeetingService` without pulling in the LLM stack.
@MainActor
protocol MeetingBriefSchedulerStore: AnyObject {
    var meetings: [Meeting] { get }
    @discardableResult
    func createMeeting(
        title: String,
        source: MeetingSource,
        state: MeetingState,
        startDate: Date?,
        endDate: Date?,
        calendarEventID: String?,
        seriesID: String?,
        attendees: [Attendee]
    ) -> Meeting
    func latestOutput(ofKind kind: MeetingOutputKind, for meeting: Meeting) -> MeetingOutput?
}

/// Brief-generation seam (plan AD9). `MeetingBriefService` conforms; tests inject a stub that never
/// touches an LLM.
@MainActor
protocol MeetingBriefGenerating: AnyObject {
    @discardableResult
    func generateBrief(for meeting: Meeting) async throws -> MeetingOutput
}

extension MeetingService: MeetingBriefSchedulerStore {}
extension MeetingBriefService: MeetingBriefGenerating {}

/// Automatic pre-meeting briefs (plan AD9 / job-queue plan J2). Hooked into the existing calendar
/// poll: on each `tick(events:now:)` it looks for calendar events entering the pre-meeting lead window
/// that have enough attendees, pre-creates the backing `Meeting`, and — unless a fresh `.brief`
/// already exists — enqueues one on the central `JobQueueService` as a `.background` `.brief` job.
///
/// [Track J] The bespoke serial queue/status this class used to own is gone: the job queue's `llm`
/// lane (cap 1) provides the concurrency cap, and its `(brief, meetingID)` dedupe replaces the old
/// `pendingEventIDs` set (a repeated tick while a brief is queued/running is dropped by the queue).
/// A failing brief still fails silently (never propagates into the poll loop) and is remembered in
/// `failedEventIDs` so `tick` does not re-enqueue it within the same lead window.
@MainActor
final class MeetingBriefScheduler: ObservableObject {
    private let store: MeetingBriefSchedulerStore
    private let briefService: MeetingBriefGenerating
    private let jobQueue: JobQueueService
    private let defaults: UserDefaults

    /// Calendar-event ids whose backing `Meeting` this scheduler pre-created as an auto-brief
    /// placeholder (no user action). These must NOT be treated as "already handled" by the
    /// upcoming-list exclusion, or the event would drop out of the Upcoming section ~lead-minutes
    /// before it starts — taking the "Brief ready" affordance and the start-notification prompt with
    /// it (finding 1). Exposed to `MeetingsViewModel.existingCalendarEventIDs`; once the user engages
    /// the meeting (capture starts → state leaves `.scheduled`) it is excluded like any other.
    private var autoCreatedEventIDs: Set<String> = []

    /// Read-only view of the calendar-event ids for scheduler-pre-created placeholder meetings.
    var placeholderEventIDs: Set<String> { autoCreatedEventIDs }

    /// Events whose auto-brief generation threw. Suppresses re-enqueue on every subsequent poll tick
    /// within the same lead window (finding 3): without this a persistent failure (no LLM configured,
    /// network down, or a colliding manual `alreadyGenerating`) would re-attempt generation ~once a
    /// minute for the whole ~20 min window. Cleared when the event leaves the lead window.
    private var failedEventIDs: Set<String> = []

    init(
        store: MeetingBriefSchedulerStore,
        briefService: MeetingBriefGenerating,
        jobQueue: JobQueueService,
        defaults: UserDefaults = .standard
    ) {
        self.store = store
        self.briefService = briefService
        self.jobQueue = jobQueue
        self.defaults = defaults
    }

    // MARK: - Config (plan AD9 keys)

    struct Config {
        var enabled: Bool
        var leadMinutes: Int
        var freshnessHours: Int
        var minAttendees: Int
    }

    private func loadConfig() -> Config {
        Config(
            enabled: boolDefault(UserDefaultsKeys.meetingsAutoBriefEnabled, fallback: true),
            leadMinutes: intDefault(UserDefaultsKeys.meetingsAutoBriefLeadMinutes, fallback: 20, min: 5, max: 60),
            freshnessHours: intDefault(UserDefaultsKeys.meetingsAutoBriefFreshnessHours, fallback: 6, min: 1, max: 168),
            minAttendees: intDefault(UserDefaultsKeys.meetingsAutoBriefMinAttendees, fallback: 1, min: 0, max: 100)
        )
    }

    private func boolDefault(_ key: String, fallback: Bool) -> Bool {
        defaults.object(forKey: key) == nil ? fallback : defaults.bool(forKey: key)
    }

    private func intDefault(_ key: String, fallback: Int, min lower: Int, max upper: Int) -> Int {
        let raw = defaults.object(forKey: key) == nil ? fallback : defaults.integer(forKey: key)
        return Swift.min(upper, Swift.max(lower, raw))
    }

    // MARK: - Poll hook

    /// Called from the calendar poll (plan AD9). Synchronously resolves eligible events, pre-creates
    /// their backing meetings, and enqueues brief generation for those lacking a fresh brief. Returns
    /// immediately; generation runs on the serial worker.
    func tick(events: [CalendarEventDTO], now: Date = Date()) {
        let config = loadConfig()
        guard config.enabled else { return }

        let eligible = events.filter { isEligible($0, config: config, now: now) }
        // Forget failures for events that have left the lead window so a later, distinct occurrence
        // can retry (finding 3); keep suppression for events still in-window.
        failedEventIDs.formIntersection(Set(eligible.map(\.id)))

        for event in eligible {
            // A prior attempt threw; do not re-enqueue for the remainder of the lead window. (Queue
            // dedupe handles the "already queued/running" case; this handles the "already failed" one.)
            guard !failedEventIDs.contains(event.id) else { continue }
            let meeting = resolveMeeting(for: event)
            if hasFreshBrief(for: meeting, freshnessHours: config.freshnessHours, now: now) { continue }
            enqueueBrief(meeting: meeting, eventID: event.id)
        }
    }

    /// Whether an event is in the lead window and eligible for an auto-brief.
    private func isEligible(_ event: CalendarEventDTO, config: Config, now: Date) -> Bool {
        guard !event.isAllDay else { return false }
        guard event.attendees.count >= config.minAttendees else { return false }
        let secondsUntilStart = event.startDate.timeIntervalSince(now)
        let lead = TimeInterval(config.leadMinutes * 60)
        // now within [start - lead, start]
        return secondsUntilStart >= 0 && secondsUntilStart <= lead
    }

    /// The existing backing meeting for the event, or a freshly pre-created `.scheduled` calendar
    /// meeting (deduped by `calendarEventID`).
    private func resolveMeeting(for event: CalendarEventDTO) -> Meeting {
        if let existing = store.meetings.first(where: { $0.calendarEventID == event.id }) {
            return existing
        }
        let projection = CalendarService.meetingProjection(for: event)
        autoCreatedEventIDs.insert(event.id)
        return store.createMeeting(
            title: projection.title,
            source: .calendar,
            state: .scheduled,
            startDate: projection.startDate,
            endDate: projection.endDate,
            calendarEventID: projection.calendarEventID,
            seriesID: projection.seriesID,
            attendees: projection.attendees
        )
    }

    // MARK: - Freshness

    /// Whether a `.brief` output newer than the freshness window exists for `meeting`.
    private func hasFreshBrief(for meeting: Meeting, freshnessHours: Int, now: Date) -> Bool {
        guard let brief = store.latestOutput(ofKind: .brief, for: meeting) else { return false }
        let cutoff = now.addingTimeInterval(-TimeInterval(freshnessHours * 3600))
        return brief.createdAt >= cutoff
    }

    /// Whether a fresh `.brief` exists for the meeting backing `calendarEventID` (drives the
    /// "Brief ready" affordance and the start-notification line). Uses the current freshness setting.
    func hasFreshBrief(forCalendarEventID calendarEventID: String, now: Date = Date()) -> Bool {
        guard let meeting = store.meetings.first(where: { $0.calendarEventID == calendarEventID }) else {
            return false
        }
        return hasFreshBrief(for: meeting, freshnessHours: loadConfig().freshnessHours, now: now)
    }

    // MARK: - Enqueue onto the central job queue (llm lane, cap 1, background priority)

    /// Enqueue a background `.brief` job for `meeting`. The queue's `(brief, meetingID)` dedupe drops a
    /// second enqueue while one is queued/running, so repeated ticks in the lead window never stack.
    /// A failure fails silently (never propagates into the poll loop) and is remembered in
    /// `failedEventIDs`; it is still marked `.failed` on the job so a J3 user Retry can re-run it.
    private func enqueueBrief(meeting: Meeting, eventID: String) {
        jobQueue.enqueue(
            kind: .brief,
            meetingID: meeting.id,
            priority: .background,
            progressLabel: String(localized: "meetings.jobs.progress.generating")
        ) { [weak self, weak briefService] in
            guard let briefService else { return }
            do {
                _ = try await briefService.generateBrief(for: meeting)
            } catch {
                // Silent-fail (plan AD9): never propagate into the poll loop; remember it so the next
                // poll tick does not retry within the lead window (finding 3), then rethrow so the job
                // is marked `.failed` (J3 popover Retry).
                logger.info("Auto-brief generation skipped: \(error.localizedDescription, privacy: .public)")
                self?.recordAutoBriefFailure(eventID: eventID)
                throw error
            }
        }
    }

    /// Remember that an auto-brief for `eventID` failed so `tick` does not re-enqueue it within the
    /// lead window (the queue does not auto-retry; only a J3 user Retry does).
    private func recordAutoBriefFailure(eventID: String) {
        failedEventIDs.insert(eventID)
    }
}
