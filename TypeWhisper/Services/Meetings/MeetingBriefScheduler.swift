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
        attendees: [Attendee],
        calendarNotes: String?,
        conferencingURL: String?
    ) -> Meeting
    func latestOutput(ofKind kind: MeetingOutputKind, for meeting: Meeting) -> MeetingOutput?
}

/// Brief-generation seam (plan AD9). `MeetingBriefService` conforms; tests inject a stub that never
/// touches an LLM.
@MainActor
protocol MeetingBriefGenerating: AnyObject {
    @discardableResult
    func generateBrief(
        for meeting: Meeting,
        providerOverride: String?,
        modelOverride: String?
    ) async throws -> MeetingOutput
}

extension MeetingBriefGenerating {
    /// The auto-brief scheduler never picks a one-shot override — a scheduled brief uses the routing
    /// ladder's persisted rungs (plan D9). This convenience keeps its call site override-free.
    @discardableResult
    func generateBrief(for meeting: Meeting) async throws -> MeetingOutput {
        try await generateBrief(for: meeting, providerOverride: nil, modelOverride: nil)
    }
}

/// Related-docs discovery seam (Amendment 2, DB6). `MeetingRelatedDocsService` conforms; tests inject a
/// stub that never touches an LLM.
@MainActor
protocol MeetingRelatedDiscovering: AnyObject {
    func discoverRelated(for meeting: Meeting) async throws
}

extension MeetingService: MeetingBriefSchedulerStore {}
extension MeetingBriefService: MeetingBriefGenerating {}
extension MeetingRelatedDocsService: MeetingRelatedDiscovering {}

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
    /// Related-docs discovery (Amendment 2, DB6). Optional so predating call sites/tests construct the
    /// scheduler without it — a nil service means no auto-discovery is enqueued (briefs are unaffected).
    private let relatedDocsService: MeetingRelatedDiscovering?
    /// Whether a vault is connected (Amendment 2, DB6 gate). A closure so the scheduler needs no hard
    /// dependency on `ObsidianVaultService`; defaults to "not connected" (no discovery).
    private let isVaultConnected: () -> Bool

    /// Calendar-event ids whose backing `Meeting` this scheduler pre-created as an auto-brief
    /// placeholder (no user action), mapped to that meeting's id. These must NOT be treated as
    /// "already handled" by the upcoming-list exclusion, or the event would drop out of the Upcoming
    /// section ~lead-minutes before it starts — taking the "Brief ready" affordance and the
    /// start-notification prompt with it (finding 1). Once the user engages the meeting (capture
    /// starts → state leaves `.scheduled`) it is excluded like any other.
    ///
    /// Persisted in `defaults` (`meetingsAutoBriefPlaceholders`): kept only in memory, a relaunch
    /// forgot every placeholder and an untouched one from an earlier launch hid its event (a
    /// rescheduled occurrence never reached "Coming up"). Keyed to the meeting id, not just the
    /// event id, so a placeholder deleted and then re-created by hand from the same event counts as
    /// engaged.
    private var placeholderMeetingIDs: [String: UUID] = [:]

    /// How long a placeholder is remembered after its meeting's start before it is pruned — far past
    /// any calendar window, so an old entry can no longer affect what is listed.
    static let placeholderRetention: TimeInterval = 14 * 24 * 3600

    /// Read-only view of the calendar-event ids whose backing meeting is still an untouched
    /// scheduler-pre-created placeholder (exists and is still `.scheduled`).
    var placeholderEventIDs: Set<String> {
        guard !placeholderMeetingIDs.isEmpty else { return [] }
        let wanted = Set(placeholderMeetingIDs.values)
        let live = Set(store.meetings.lazy.filter { wanted.contains($0.id) && $0.state == .scheduled }.map(\.id))
        return Set(placeholderMeetingIDs.compactMap { live.contains($0.value) ? $0.key : nil })
    }

    /// Events whose auto-brief generation threw. Suppresses re-enqueue on every subsequent poll tick
    /// within the same lead window (finding 3): without this a persistent failure (no LLM configured,
    /// network down, or a colliding manual `alreadyGenerating`) would re-attempt generation ~once a
    /// minute for the whole ~20 min window. Cleared when the event leaves the lead window.
    private var failedEventIDs: Set<String> = []

    init(
        store: MeetingBriefSchedulerStore,
        briefService: MeetingBriefGenerating,
        jobQueue: JobQueueService,
        defaults: UserDefaults = .standard,
        relatedDocsService: MeetingRelatedDiscovering? = nil,
        isVaultConnected: @escaping () -> Bool = { false }
    ) {
        self.store = store
        self.briefService = briefService
        self.jobQueue = jobQueue
        self.defaults = defaults
        self.relatedDocsService = relatedDocsService
        self.isVaultConnected = isVaultConnected
        loadPlaceholders()
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

    /// [Perf Phase 2] The lead window `tick` gates on (`[start − lead, start]`), for the calendar wake
    /// planner; `nil` when auto-briefs are off.
    var consumerWindow: CalendarWakePlanner.ConsumerWindow? {
        let config = loadConfig()
        guard config.enabled else { return nil }
        return CalendarWakePlanner.ConsumerWindow(lead: TimeInterval(config.leadMinutes * 60), trail: 0)
    }

    // MARK: - Poll hook

    /// Called from the calendar poll (plan AD9). Synchronously resolves eligible events, pre-creates
    /// their backing meetings, and enqueues brief generation for those lacking a fresh brief. Returns
    /// immediately; generation runs on the serial worker.
    func tick(events: [CalendarEventDTO], now: Date = Date()) {
        let config = loadConfig()
        guard config.enabled else { return }

        prunePlaceholders(now: now)
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
            // Amendment 2 (DB6): enqueue a gated `.background` `relatedDiscovery` *ahead* of the brief on
            // the same cap-1 llm lane so it runs first (FIFO within priority) and the brief consumes fresh
            // related docs. A fail-closed discovery just means the brief falls back to folder scope.
            enqueueRelatedDiscoveryIfNeeded(meeting: meeting, freshnessHours: config.freshnessHours, now: now)
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
        let meeting = store.createMeeting(
            title: projection.title,
            source: .calendar,
            state: .scheduled,
            startDate: projection.startDate,
            endDate: projection.endDate,
            calendarEventID: projection.calendarEventID,
            seriesID: projection.seriesID,
            attendees: projection.attendees,
            // [Google Phase 1 · M5] Auto-created meetings snapshot the event's rich detail too, so
            // a meeting pre-created for its brief still shows notes + join link.
            calendarNotes: projection.calendarNotes,
            conferencingURL: projection.conferencingURL
        )
        placeholderMeetingIDs[event.id] = meeting.id
        savePlaceholders()
        return meeting
    }

    // MARK: - Placeholder persistence

    private func loadPlaceholders() {
        if let stored = defaults.dictionary(forKey: UserDefaultsKeys.meetingsAutoBriefPlaceholders) {
            placeholderMeetingIDs = stored.reduce(into: [:]) { result, entry in
                if let raw = entry.value as? String, let id = UUID(uuidString: raw) { result[entry.key] = id }
            }
        } else {
            // One-time seed for placeholders created before the set was persisted.
            placeholderMeetingIDs = Self.inferLegacyPlaceholders(in: store.meetings, now: Date())
        }
        prunePlaceholders(now: Date(), forceSave: true)
    }

    private func savePlaceholders() {
        defaults.set(
            placeholderMeetingIDs.mapValues(\.uuidString),
            forKey: UserDefaultsKeys.meetingsAutoBriefPlaceholders
        )
    }

    /// Forget placeholders whose meeting was deleted, was engaged (left `.scheduled`), or started
    /// longer than `placeholderRetention` ago.
    private func prunePlaceholders(now: Date, forceSave: Bool = false) {
        var changed = false
        if !placeholderMeetingIDs.isEmpty {
            let byID = Dictionary(
                store.meetings.lazy.map { ($0.id, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            let cutoff = now.addingTimeInterval(-Self.placeholderRetention)
            let kept = placeholderMeetingIDs.filter { _, meetingID in
                guard let meeting = byID[meetingID], meeting.state == .scheduled else { return false }
                return (meeting.startDate ?? now) >= cutoff
            }
            changed = kept.count != placeholderMeetingIDs.count
            placeholderMeetingIDs = kept
        }
        if changed || forceSave { savePlaceholders() }
    }

    /// Placeholders created before the set was persisted carry no marker, so recognise them by the
    /// shape `resolveMeeting(for:)` leaves: an untouched (`.scheduled`, no transcript)
    /// calendar meeting created inside the maximum lead window (60 min) before its start, within the
    /// retention period. A meeting the user created by hand from an event in that window is
    /// indistinguishable; treating it as a placeholder only keeps its event listed in Upcoming.
    static func inferLegacyPlaceholders(in meetings: [Meeting], now: Date) -> [String: UUID] {
        let maxLead: TimeInterval = 60 * 60
        let cutoff = now.addingTimeInterval(-placeholderRetention)
        var result: [String: UUID] = [:]
        for meeting in meetings {
            guard meeting.state == .scheduled, meeting.source == .calendar,
                  let eventID = meeting.calendarEventID, let start = meeting.startDate, start >= cutoff
            else { continue }
            let lead = start.timeIntervalSince(meeting.createdAt)
            guard lead >= 0, lead <= maxLead + 60 else { continue }
            guard CalendarMeetingReconciler.isUntouched(meeting) else { continue }
            if result[eventID] == nil { result[eventID] = meeting.id }
        }
        return result
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

    // MARK: - Auto related-docs discovery (Amendment 2, DB6)

    /// Enqueue a gated `.background` `relatedDiscovery` for `meeting` when: a discovery service + vault
    /// are present; the meeting has a folder path *or* a non-trivial wider-vault query; and no *fresh*
    /// discovery exists (`relatedDiscoveryAt` within the brief freshness window). Deduped by
    /// `(relatedDiscovery, meetingID)`, so repeated ticks never stack a second one.
    private func enqueueRelatedDiscoveryIfNeeded(meeting: Meeting, freshnessHours: Int, now: Date) {
        guard let relatedDocsService, isVaultConnected() else { return }
        let hasFolder = !MeetingService.folderComponents(meeting.folderPath).isEmpty
        let query = discoveryQuery(for: meeting)
        guard hasFolder || !query.isEmpty else { return }

        if let lastRun = meeting.relatedDiscoveryAt {
            let cutoff = now.addingTimeInterval(-TimeInterval(freshnessHours * 3600))
            if lastRun >= cutoff { return }
        }

        jobQueue.enqueue(
            kind: .relatedDiscovery,
            meetingID: meeting.id,
            priority: .background,
            progressLabel: String(localized: "meetings.jobs.progress.findingRelated")
        ) { [weak relatedDocsService] in
            try await relatedDocsService?.discoverRelated(for: meeting)
        }
    }

    /// The wider-vault query used to decide whether discovery is worthwhile: title + attendee names
    /// (mirrors `MeetingRelatedDocsService.retrievalQuery`).
    private func discoveryQuery(for meeting: Meeting) -> String {
        var terms = [meeting.title]
        terms.append(contentsOf: meeting.attendees.map(\.name))
        return terms.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
