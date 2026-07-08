import Foundation
import Combine

@MainActor
final class MeetingsViewModel: ObservableObject {
    nonisolated(unsafe) static var _shared: MeetingsViewModel?
    static var shared: MeetingsViewModel {
        guard let instance = _shared else {
            fatalError("MeetingsViewModel not initialized")
        }
        return instance
    }

    @Published private(set) var meetings: [Meeting] = []

    // Outputs / templates (M4; unified into PromptAction meeting rows — plan AD6)
    @Published private(set) var templates: [PromptAction] = []
    @Published var outputErrorMessage: String?
    /// Set alongside `outputErrorMessage` when the failure is specifically "no LLM provider
    /// configured", so the document body can offer a deep link into Settings › Library › Prompts.
    @Published var outputErrorNeedsProvider = false

    // Calendar (M2)
    @Published private(set) var calendarAuthorizationStatus: CalendarAuthorizationStatus = .notDetermined
    @Published private(set) var upcomingEvents: [CalendarEventDTO] = []
    /// [M10] Already-ended events from the lookback window (since start of day) — the collapsible
    /// "Earlier" section. Mirrored from `CalendarService.earlierEvents`.
    @Published private(set) var earlierEvents: [CalendarEventDTO] = []
    @Published private(set) var calendarErrorMessage: String?

    /// [M10] A meeting the UI should navigate to / focus (e.g. after "Start Meeting Recording" from
    /// the menu bar, or opening a past meeting from the Earlier section). The Meetings window
    /// observes this and clears it via `consumeFocusRequest()`.
    @Published var pendingFocusMeetingID: UUID?

    // Capture (M3)
    @Published private(set) var activeMeeting: Meeting?
    @Published private(set) var isCapturing = false
    @Published private(set) var liveTranscript: String = ""
    @Published private(set) var captureElapsedSeconds: TimeInterval = 0
    @Published private(set) var isDegradedLiveMode = false
    @Published private(set) var captureErrorMessage: String?
    // [Track C] AD8 final re-transcription degradation, mirrored from the capture service so the
    // detail view can surface a status (never an error dialog) when a meeting's final pass ran in a
    // reduced mode. `finalRetranscriptionDegradedMeetingID` scopes the banner to the affected meeting.
    @Published private(set) var finalRetranscriptionDegraded = false
    @Published private(set) var finalRetranscriptionDegradedMeetingID: UUID?

    // Knowledge base + brief (M5)
    @Published private(set) var isVaultConnected = false
    @Published private(set) var vaultName: String?
    @Published private(set) var isGeneratingBrief = false
    @Published var briefErrorMessage: String?
    @Published var briefErrorNeedsProvider = false

    // In-meeting Q&A (M6)
    @Published private(set) var isAnswering = false
    @Published var qaErrorMessage: String?
    @Published var qaErrorNeedsProvider = false

    // Obsidian export (M7)
    @Published var exportErrorMessage: String?

    // Import / merge (M8)
    @Published private(set) var isImporting = false
    @Published var importErrorMessage: String?

    // Speaker diarization & mapping (M9)
    @Published private(set) var isEnriching = false
    @Published var diarizationErrorMessage: String?
    /// A localized status shown after enrichment finishes without labeling (e.g. "no speakers
    /// detected"). Cleared when a new enrichment starts.
    @Published var diarizationStatusMessage: String?

    // [Track D] Automatic pre-meeting briefs (plan AD9). Mirrors the scheduler's coarse status.
    @Published private(set) var briefSchedulerStatus: MeetingBriefSchedulerStatus = .idle

    // [Track C] `internal` (not `private`) so `MeetingsViewModel+Rules.swift` can persist the
    // per-meeting final re-transcription override through it.
    let meetingService: MeetingService
    // [Track B] Unified prompt/template library — meeting output templates are `.meeting`-surface
    // PromptAction rows owned by PromptActionService (plan AD6).
    private let promptActionService: PromptActionService
    private let calendarService: CalendarService
    // [Track C] `internal` (not `private`) so `MeetingsViewModel+Rules.swift` can read
    // `captureService.activeMeetingDefaultTemplateID` to pre-select the rule-selected default output
    // template in the generate flow (`defaultTemplate(ofKind:for:)`, addendum AD7).
    let captureService: MeetingCaptureService
    private let startNotificationService: MeetingStartNotificationService
    private let llmService: MeetingLLMService
    private let vaultService: ObsidianVaultService
    private let briefService: MeetingBriefService
    private let exporter: MeetingObsidianExporter
    private let importService: MeetingImportService
    private let diarizationEnricher: MeetingDiarizationEnricher
    // [Track C] Capture-context rules service (addendum AD7). Rule CRUD, context building, and
    // resolution preview live in `MeetingsViewModel+Rules.swift`.
    let contextRuleService: MeetingContextRuleService
    // [Track D] Auto pre-meeting briefs (plan AD9). Internal so `MeetingsViewModel+AutoBrief` reaches it.
    let briefScheduler: MeetingBriefScheduler
    // [Track J] Central background-job queue (plan J1). Output generation is routed through it so the
    // Generate spinner is meeting-scoped (does not follow navigation) and double-clicks are deduped.
    private let jobQueue: JobQueueService
    private var cancellables = Set<AnyCancellable>()
    private var pollingCancellable: AnyCancellable?

    init(
        meetingService: MeetingService,
        promptActionService: PromptActionService,
        calendarService: CalendarService,
        captureService: MeetingCaptureService,
        startNotificationService: MeetingStartNotificationService,
        llmService: MeetingLLMService,
        vaultService: ObsidianVaultService,
        briefService: MeetingBriefService,
        exporter: MeetingObsidianExporter,
        importService: MeetingImportService,
        diarizationEnricher: MeetingDiarizationEnricher,
        // [Track C]
        contextRuleService: MeetingContextRuleService,
        briefScheduler: MeetingBriefScheduler, // [Track D]
        jobQueue: JobQueueService // [Track J]
    ) {
        self.contextRuleService = contextRuleService
        self.jobQueue = jobQueue // [Track J]
        self.meetingService = meetingService
        self.promptActionService = promptActionService
        self.calendarService = calendarService
        self.captureService = captureService
        self.startNotificationService = startNotificationService
        self.llmService = llmService
        self.vaultService = vaultService
        self.briefService = briefService
        self.exporter = exporter
        self.importService = importService
        self.diarizationEnricher = diarizationEnricher
        self.briefScheduler = briefScheduler // [Track D]
        self.meetings = meetingService.meetings
        self.templates = promptActionService.meetingActions
        self.calendarAuthorizationStatus = calendarService.authorizationStatus
        self.upcomingEvents = calendarService.upcomingEvents
        self.earlierEvents = calendarService.earlierEvents
        self.calendarErrorMessage = calendarService.errorMessage
        self.isVaultConnected = vaultService.isConnected
        self.vaultName = vaultService.vaultName

        meetingService.$meetings
            .receive(on: DispatchQueue.main)
            .sink { [weak self] meetings in
                self?.meetings = meetings
            }
            .store(in: &cancellables)

        promptActionService.$meetingActions
            .receive(on: DispatchQueue.main)
            .sink { [weak self] templates in
                self?.templates = templates
            }
            .store(in: &cancellables)

        // [Track J] `isGeneratingOutput` is no longer a VM mirror of `llmService.$isGenerating` — the
        // Generate spinner is now meeting-scoped, derived from the job queue via
        // `isGeneratingOutput(for:)`, so it stays on the originating meeting across navigation (J1).
        llmService.$isAnswering
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in self?.isAnswering = value }
            .store(in: &cancellables)

        calendarService.$authorizationStatus
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                self?.calendarAuthorizationStatus = status
            }
            .store(in: &cancellables)
        calendarService.$upcomingEvents
            .receive(on: DispatchQueue.main)
            .sink { [weak self] events in
                guard let self else { return }
                self.upcomingEvents = events
                // Prompt (never silently record) when a scheduled meeting reaches its start (D10).
                self.startNotificationService.notifyStartingMeetings(events)
                // [Track D] Auto-generate pre-meeting briefs for events entering the lead window (AD9).
                self.briefScheduler.tick(events: events, now: Date())
            }
            .store(in: &cancellables)
        calendarService.$earlierEvents
            .receive(on: DispatchQueue.main)
            .sink { [weak self] events in
                self?.earlierEvents = events
            }
            .store(in: &cancellables)
        calendarService.$errorMessage
            .receive(on: DispatchQueue.main)
            .sink { [weak self] message in
                self?.calendarErrorMessage = message
            }
            .store(in: &cancellables)

        captureService.$activeMeeting
            .receive(on: DispatchQueue.main)
            .sink { [weak self] meeting in self?.activeMeeting = meeting }
            .store(in: &cancellables)
        captureService.$isCapturing
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in self?.isCapturing = value }
            .store(in: &cancellables)
        // `removeDuplicates` guards the singleton VM's `objectWillChange` from firing (and rebuilding
        // every transcript observer) on redundant republishes — the 350 ms live-preview poll and the
        // 1 s elapsed timer frequently re-emit an unchanged value.
        captureService.$liveTranscript
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in self?.liveTranscript = value }
            .store(in: &cancellables)
        captureService.$elapsedSeconds
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in self?.captureElapsedSeconds = value }
            .store(in: &cancellables)
        captureService.$isDegradedLiveMode
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in self?.isDegradedLiveMode = value }
            .store(in: &cancellables)
        captureService.$finalRetranscriptionDegraded
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in self?.finalRetranscriptionDegraded = value }
            .store(in: &cancellables)
        captureService.$finalRetranscriptionDegradedMeetingID
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in self?.finalRetranscriptionDegradedMeetingID = value }
            .store(in: &cancellables)
        captureService.$errorMessage
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in self?.captureErrorMessage = value }
            .store(in: &cancellables)

        vaultService.$vaultPath
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.isVaultConnected = self.vaultService.isConnected
                self.vaultName = self.vaultService.vaultName
            }
            .store(in: &cancellables)
        briefService.$isGenerating
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in self?.isGeneratingBrief = value }
            .store(in: &cancellables)
        importService.$isImporting
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in self?.isImporting = value }
            .store(in: &cancellables)
        diarizationEnricher.$isEnriching
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in self?.isEnriching = value }
            .store(in: &cancellables)
        // [Track D] Mirror the auto-brief scheduler status for optional UI surfacing (AD9).
        briefScheduler.$status
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in self?.briefSchedulerStatus = value }
            .store(in: &cancellables)
    }

    var hasMeetings: Bool { !meetings.isEmpty }

    /// Clear the per-meeting transient status/error banners. These are singleton `@Published` state
    /// (each reset at the start of its own operation), so without this they persist across a meeting
    /// switch and e.g. meeting A's "no speakers detected" status renders under meeting B (finding 7).
    /// Called from the window when the selected meeting changes.
    func clearTransientMessages() {
        outputErrorMessage = nil
        outputErrorNeedsProvider = false
        briefErrorMessage = nil
        briefErrorNeedsProvider = false
        qaErrorMessage = nil
        qaErrorNeedsProvider = false
        exportErrorMessage = nil
        diarizationErrorMessage = nil
        diarizationStatusMessage = nil
    }

    /// True when a caught generation error is specifically "no LLM provider configured", so the
    /// document UI can surface an actionable deep link instead of a dead-end message.
    private func needsProviderSetup(_ error: Error) -> Bool {
        (error as? LLMError)?.isNoProviderConfigured ?? false
    }

    /// Deep-link the user from the meeting document into Settings › Library › Prompts, where the
    /// default LLM provider is chosen. Opens the Settings window if it isn't already visible.
    func openProviderSettings() {
        SettingsNavigationCoordinator.shared?.navigate(to: .prompts)
        ManagedAppWindowOpener.shared.open(id: AppWindowID.settings)
    }

    // MARK: - Calendar

    var isCalendarAuthorized: Bool { calendarAuthorizationStatus == .authorized }

    /// Prompt for calendar access; refreshes the upcoming list on success.
    func requestCalendarAccess() async {
        await calendarService.requestAccess()
        loadUpcoming()
    }

    /// Re-query upcoming/current events, excluding any that already back a stored meeting.
    func loadUpcoming(now: Date = Date()) {
        calendarService.refresh(
            now: now,
            existingCalendarEventIDs: existingCalendarEventIDs
        )
    }

    /// Whether an upcoming event is happening right now (for the "in progress" badge).
    func isCurrent(_ event: CalendarEventDTO, now: Date = Date()) -> Bool {
        CalendarService.isCurrent(event, now: now)
    }

    /// [M10] Time-based classification for an event (drives the "in progress" / "ended" badges and
    /// the upcoming-vs-earlier sectioning).
    func timeStatus(for event: CalendarEventDTO, now: Date = Date()) -> CalendarService.EventTimeStatus {
        CalendarService.timeStatus(for: event, now: now)
    }

    /// [M10] The stored meeting already backing a calendar event, if any — lets an Earlier-section
    /// row navigate to an existing meeting instead of creating a duplicate.
    func existingMeeting(for event: CalendarEventDTO) -> Meeting? {
        meetingService.meetings.first { $0.calendarEventID == event.id }
    }

    /// [M10] Dismiss an overrunning (recently-ended) event from the Upcoming section for this
    /// session — the "dismiss" arm of "visible until created / started / dismissed".
    func dismissEvent(_ event: CalendarEventDTO) {
        calendarService.dismiss(eventID: event.id)
    }

    /// [M10] Request that the Meetings window navigate to / focus `meeting`.
    func requestFocus(on meeting: Meeting) {
        pendingFocusMeetingID = meeting.id
    }

    // MARK: - Calendar selection (M11)

    /// Rows for the "Calendars" settings list: every macOS calendar plus whether it is selected.
    func calendarSelectionRows() -> [CalendarSelectionRow] {
        Self.makeCalendarRows(
            calendars: calendarService.availableCalendars(),
            isSelected: calendarService.isCalendarSelected
        )
    }

    /// Toggle a calendar's inclusion, then re-query so the Upcoming/Earlier lists (and thereby the
    /// scheduler + notifications, which consume them) immediately reflect the change.
    func setCalendarSelected(_ selected: Bool, for calendarID: String, now: Date = Date()) {
        calendarService.setCalendarSelected(selected, for: calendarID)
        loadUpcoming(now: now)
    }

    /// Pure list-rendering projection for the "Calendars" settings section (M11), unit-testable
    /// without EventKit or the full view model: pairs each calendar with its selection state and
    /// sorts by account then title for a stable order.
    static func makeCalendarRows(
        calendars: [CalendarInfo],
        isSelected: (String) -> Bool
    ) -> [CalendarSelectionRow] {
        calendars
            .sorted { lhs, rhs in
                if lhs.sourceName != rhs.sourceName { return lhs.sourceName < rhs.sourceName }
                return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            }
            .map { CalendarSelectionRow(calendar: $0, isSelected: isSelected($0.id)) }
    }

    /// [M10] Clear a pending focus request once the window has honoured it.
    func consumeFocusRequest() {
        pendingFocusMeetingID = nil
    }

    /// Create (or return the existing) `.scheduled` meeting for a calendar event, deduping by
    /// `calendarEventID`. Refreshes the upcoming list so the created event drops out of it.
    @discardableResult
    func createMeeting(from event: CalendarEventDTO) -> Meeting {
        // Read the authoritative synchronous source, not the Combine-mirrored `self.meetings`
        // (updated via `$meetings.receive(on: .main)`, an async hop even on main). Using the
        // stale copy would let a rapid double-click insert a duplicate and would leave the
        // just-created event in the upcoming list until the next poll.
        if let existing = meetingService.meetings.first(where: { $0.calendarEventID == event.id }) {
            return existing
        }
        let projection = CalendarService.meetingProjection(for: event)
        let meeting = meetingService.createMeeting(
            title: projection.title,
            source: .calendar,
            state: .scheduled,
            startDate: projection.startDate,
            endDate: projection.endDate,
            calendarEventID: projection.calendarEventID,
            seriesID: projection.seriesID,
            attendees: projection.attendees
        )
        loadUpcoming()
        return meeting
    }

    // MARK: - Capture (M3)

    var canStartCapture: Bool { !isCapturing }

    /// Create an ad-hoc meeting so capture never hard-depends on the calendar (plan §1).
    @discardableResult
    func createAdHocMeeting(title: String? = nil) -> Meeting {
        let resolved = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalTitle = (resolved?.isEmpty == false) ? resolved! : String(localized: "meetings.adHoc.defaultTitle")
        return meetingService.createMeeting(title: finalTitle, source: .adHoc, state: .scheduled, startDate: Date())
    }

    /// Start live capture for an existing meeting. Surfaces a localized error (e.g. the Recorder
    /// currently owns the capture stack) via `captureErrorMessage`. `calendarName` (the originating
    /// calendar's source-list name) feeds the AD7 calendar-name rule tier; nil for ad-hoc captures.
    func startCapture(for meeting: Meeting, calendarName: String? = nil) async {
        captureErrorMessage = nil
        do {
            try await captureService.start(meeting: meeting, calendarName: calendarName)
        } catch {
            captureErrorMessage = error.localizedDescription
        }
    }

    /// Create an ad-hoc meeting and immediately begin capturing it.
    func startAdHocCapture(title: String? = nil) async {
        let meeting = createAdHocMeeting(title: title)
        await startCapture(for: meeting)
    }

    /// Create an ad-hoc meeting and begin capturing, guarding synchronously against a concurrent
    /// capture so a rapid double-click on "New Meeting" cannot persist a stray empty meeting
    /// (M3 review finding 2). Returns the created meeting, or `nil` if capture was already in
    /// progress (nothing is created) or start failed (the just-created meeting is removed).
    @discardableResult
    func createAndStartAdHocCapture(title: String? = nil) async -> Meeting? {
        // Authoritative *synchronous* flag on the capture service, not the Combine-mirrored
        // `self.isCapturing` (a main-queue hop behind). A second click arriving during the first
        // `start()`'s suspension is rejected here before it can create a second meeting.
        // Also refuse while a previous session is finalizing (its recorder/buffer are being torn
        // down), matching `start()`'s guard (finding 2).
        guard !captureService.isCapturing, !captureService.isFinalizing else { return nil }
        let meeting = createAdHocMeeting(title: title)
        do {
            try await captureService.start(meeting: meeting)
            return meeting
        } catch {
            captureErrorMessage = error.localizedDescription
            // start() never took ownership (recorderBusy / alreadyCapturing); the just-created
            // empty meeting would otherwise linger as a stray row. Remove it.
            meetingService.deleteMeeting(meeting)
            return nil
        }
    }

    /// [M10] Menu-bar entry point ("Start Meeting Recording"): create an ad-hoc meeting, start
    /// capture, and return it so the caller can focus the window on it. If a capture is already in
    /// progress (or finalizing) the mutual-exclusion guard surfaces a localized busy message via
    /// `captureErrorMessage` — never a crash — and returns the already-active meeting so the window
    /// can focus that instead of silently doing nothing.
    @discardableResult
    func startMeetingRecordingFromMenu() async -> Meeting? {
        // Authoritative synchronous flags on the capture service (not the Combine-mirrored copies).
        guard !captureService.isCapturing, !captureService.isFinalizing else {
            captureErrorMessage = String(localized: "meetings.recording.alreadyActive")
            return captureService.activeMeeting
        }
        return await createAndStartAdHocCapture()
    }

    /// Create (or reuse) the meeting backing a calendar event, then begin capture.
    func startCapture(from event: CalendarEventDTO) async {
        let meeting = createMeeting(from: event)
        // Thread the event's calendar (source-list) name through so a calendar-name capture-context
        // rule (AD7) can match — it is not persisted on `Meeting`, so it must ride the start call.
        await startCapture(for: meeting, calendarName: event.calendarName)
    }

    func stopCapture() async {
        await captureService.stop()
    }

    /// Add an in-meeting note to the active capture, timestamped with elapsed seconds.
    func addNote(_ text: String) {
        captureService.addNote(text)
    }

    // MARK: - Outputs & templates (M4)

    /// Templates of a given output kind, in sort order (drives the generate menus).
    func templates(ofKind kind: MeetingOutputKind) -> [PromptAction] {
        meetingService.templates(ofKind: kind)
    }

    /// The newest output of a kind for a meeting (what the detail view surfaces).
    func latestOutput(ofKind kind: MeetingOutputKind, for meeting: Meeting) -> MeetingOutput? {
        meetingService.latestOutput(ofKind: kind, for: meeting)
    }

    /// Generate (or regenerate) an output for a meeting from a template. Regeneration inserts a
    /// new row; the detail view shows the newest per kind. Surfaces failures via `outputErrorMessage`.
    ///
    /// [Track J] Routed through the job queue (plan J1): the actual LLM call runs on the `llm` lane
    /// (cap 1) as a `summary`/`extendedAnalysis` job. Enqueue is synchronous — the button no longer
    /// awaits — and a second click while the job is queued/running is deduped by `(kind, meetingID)`,
    /// so exactly one `MeetingOutput` is produced. A thrown error is recorded for the document's
    /// "needs provider" deep link *and* rethrown so the job is marked `.failed` for the J3 popover.
    func generateOutput(for meeting: Meeting, using template: PromptAction) {
        outputErrorMessage = nil
        outputErrorNeedsProvider = false
        let kind: MeetingJobKind = (template.meetingKind == .extended) ? .extendedAnalysis : .summary
        jobQueue.enqueue(
            kind: kind,
            meetingID: meeting.id,
            progressLabel: String(localized: "meetings.jobs.progress.generating")
        ) { [weak llmService, weak self] in
            guard let llmService else { return }
            do {
                _ = try await llmService.generateOutput(for: meeting, using: template)
            } catch {
                self?.recordOutputError(error)
                throw error
            }
        }
    }

    /// Publish an output-generation failure for the document body (the "needs provider" deep link).
    /// Split out of `generateOutput` so the job-queue closure can record it before rethrowing.
    private func recordOutputError(_ error: Error) {
        outputErrorMessage = error.localizedDescription
        outputErrorNeedsProvider = needsProviderSetup(error)
    }

    /// Whether an LLM-lane job (summary/extended today; brief once J2 routes it) is in flight for
    /// this meeting — drives the bottom bar's Generate spinner. Meeting-scoped so it does not follow
    /// navigation (the bug J1 targets).
    func isGeneratingOutput(for meeting: Meeting) -> Bool {
        jobQueue.hasActiveJob(inLane: .llm, meetingID: meeting.id)
    }

    /// Toggle whether in-meeting notes are folded into generated outputs.
    func setNotesIncluded(_ included: Bool, for meeting: Meeting) {
        meetingService.setNotesIncludedInOutputs(included, for: meeting)
    }

    func deleteOutput(_ output: MeetingOutput) {
        meetingService.deleteOutput(output)
    }

    // MARK: - Knowledge base & brief (M5)

    /// Auto-detect and connect the most-recently-opened Obsidian vault, if any.
    @discardableResult
    func autoConnectVault() -> Bool {
        vaultService.autoConnect()
    }

    /// Present a folder picker to choose a vault manually.
    func chooseVault() {
        vaultService.chooseVault()
    }

    /// Forget the connected vault.
    func disconnectVault() {
        vaultService.disconnect()
    }

    /// Detected Obsidian vaults (most-recent first) for a manual connect menu.
    func detectedVaults() -> [ObsidianVaultService.VaultInfo] {
        ObsidianVaultService.detectVaults()
    }

    func connectVault(to path: String) {
        vaultService.connect(to: path)
    }

    /// Generate (or regenerate) a pre-meeting brief for a meeting from prior related meetings and
    /// the connected knowledge base. Surfaces failures via `briefErrorMessage`.
    func generateBrief(for meeting: Meeting) async {
        briefErrorMessage = nil
        briefErrorNeedsProvider = false
        do {
            try await briefService.generateBrief(for: meeting)
        } catch {
            briefErrorMessage = error.localizedDescription
            briefErrorNeedsProvider = needsProviderSetup(error)
        }
    }

    // MARK: - In-meeting Q&A (M6)

    /// Ask a question against a meeting's transcript-so-far plus the connected knowledge base and
    /// prior turns. During live capture of this meeting the transcript is scoped to elapsed time so
    /// the answer can't draw on words spoken after the question. Persists one `MeetingQATurn` on
    /// success; surfaces failures via `qaErrorMessage`. Returns `true` on success so the composer can
    /// keep the user's typed question on failure (M6 review finding 4) instead of losing it.
    @discardableResult
    func askQuestion(_ question: String, for meeting: Meeting) async -> Bool {
        qaErrorMessage = nil
        qaErrorNeedsProvider = false
        // Scope on the *meeting timeline* (session-relative elapsed + `sessionTimeOffset`), matching
        // persisted `segment.start` values, so a restarted session's Q&A doesn't drop nearly the
        // whole transcript through the composer's `segment.start <= offset` filter (finding 1).
        let offset: Double? = (isCapturing && activeMeeting?.id == meeting.id) ? captureService.meetingTimelineElapsed : nil
        do {
            try await llmService.answerQuestion(for: meeting, question: question, asOfOffset: offset)
            return true
        } catch {
            qaErrorMessage = error.localizedDescription
            qaErrorNeedsProvider = needsProviderSetup(error)
            return false
        }
    }

    // MARK: - Obsidian export (M7)

    /// Persist the meeting's per-meeting export folder (a vault-relative path).
    func setObsidianFolder(_ folder: String, for meeting: Meeting) {
        meetingService.setObsidianFolder(folder, for: meeting)
    }

    /// Persist the meeting's export tags from a comma/space-separated string.
    func setObsidianTags(_ tagsText: String, for meeting: Meeting) {
        let tags = tagsText
            .split(whereSeparator: { $0 == "," || $0 == "\n" })
            .map { String($0) }
        meetingService.setObsidianTags(tags, for: meeting)
    }

    /// Export the selected sections of `meeting` to the connected vault. Returns the number of files
    /// written on success, or `nil` on failure (surfaced via `exportErrorMessage`).
    @discardableResult
    func export(_ meeting: Meeting, sections: [MeetingExportSection], combined: Bool) -> Int? {
        exportErrorMessage = nil
        do {
            let urls = try exporter.export(meeting, sections: sections, combined: combined)
            if !urls.isEmpty {
                // Record the real export event so the "In vault" badge reflects an actual write,
                // not merely a non-empty `obsidianFolder` field.
                meetingService.recordObsidianExport(for: meeting)
            }
            return urls.count
        } catch {
            exportErrorMessage = error.localizedDescription
            return nil
        }
    }

    // MARK: - Import / merge (M8)

    /// Supported transcript-file extensions for the import file picker (never the audio set).
    var transcriptFileExtensions: [String] { Array(TranscriptFileParser.supportedExtensions).sorted() }

    /// Supported audio-file extensions for the import file picker.
    var audioFileExtensions: [String] { Array(AudioFileService.supportedExtensions).sorted() }

    /// Import a transcript-only file (Google Meet / `Speaker:` / timestamped / plain text) as a new
    /// meeting. Returns the created meeting, or nil on failure (surfaced via `importErrorMessage`).
    @discardableResult
    func importTranscriptFile(at url: URL) -> Meeting? {
        importErrorMessage = nil
        do {
            return try importService.importTranscriptFile(at: url)
        } catch {
            importErrorMessage = error.localizedDescription
            return nil
        }
    }

    /// Import an audio file as a new meeting: it is decoded, transcribed, and adopted into the
    /// meetings library. Returns the created meeting, or nil on failure.
    @discardableResult
    func importAudioFile(at url: URL) async -> Meeting? {
        importErrorMessage = nil
        do {
            return try await importService.importAudioFile(at: url)
        } catch {
            importErrorMessage = error.localizedDescription
            return nil
        }
    }

    /// Merge an imported transcript file into an existing meeting, time-ordered and deduped against
    /// the captured transcript (plan D12). Returns true on success.
    @discardableResult
    func mergeTranscriptFile(at url: URL, into meeting: Meeting) -> Bool {
        importErrorMessage = nil
        do {
            try importService.mergeTranscriptFile(at: url, into: meeting)
            return true
        } catch {
            importErrorMessage = error.localizedDescription
            return false
        }
    }

    // MARK: - Speaker diarization & mapping (M9)

    /// Whether — and how — speaker identification can run for a meeting (drives showing/hiding the
    /// "Identify speakers" action). `.unavailable` when there is no audio and no sidecar.
    func diarizationAvailability(for meeting: Meeting) async -> MeetingDiarizationEnricher.Availability {
        await diarizationEnricher.availability(for: meeting)
    }

    /// Run opt-in diarization over a meeting's audio and persist speaker labels. Surfaces an explicit
    /// "no speakers detected" status (plan D8) and any hard failure via published messages.
    func identifySpeakers(for meeting: Meeting) async {
        diarizationErrorMessage = nil
        diarizationStatusMessage = nil
        do {
            let outcome = try await diarizationEnricher.enrich(meeting)
            switch outcome {
            case .labeled:
                break // labels now render in the transcript; nothing to announce
            case .noSpeakersDetected:
                diarizationStatusMessage = String(localized: "meetings.diarization.status.noSpeakers")
            case .unavailable:
                diarizationStatusMessage = String(localized: "meetings.diarization.status.unavailable")
            case .noAudio:
                diarizationStatusMessage = String(localized: "meetings.diarization.status.noAudio")
            case .noTranscript:
                diarizationStatusMessage = String(localized: "meetings.diarization.status.noTranscript")
            case .timelineMismatch:
                diarizationStatusMessage = String(localized: "meetings.diarization.status.timelineMismatch")
            }
        } catch {
            diarizationErrorMessage = error.localizedDescription
        }
    }

    /// The distinct `SPEAKER_xx` labels present on a meeting's transcript, sorted — the rows of the
    /// mapping editor.
    func speakerLabels(in meeting: Meeting) -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for segment in meeting.segments.sorted(by: { $0.order < $1.order }) {
            guard let label = segment.speakerLabel?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !label.isEmpty, seen.insert(label).inserted else { continue }
            ordered.append(label)
        }
        return ordered.sorted()
    }

    /// Persist the edited `SPEAKER_xx → name` map; empty names clear a label back to its raw form.
    func setSpeakerMap(_ map: [String: String], for meeting: Meeting) {
        meetingService.setSpeakerMap(map, for: meeting)
    }

    /// Attendee names (from a linked calendar event or manual entry) offered as mapping suggestions.
    func attendeeNameSuggestions(for meeting: Meeting) -> [String] {
        meeting.attendees
            .map { $0.name.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    // MARK: - Template CRUD (editor — plan AD6 unified library)

    @discardableResult
    func addMeetingTemplate(_ spec: PromptTemplateSpec) -> PromptAction? {
        promptActionService.addMeetingTemplate(spec)
    }

    func updateMeetingTemplate(_ template: PromptAction, with spec: PromptTemplateSpec) {
        promptActionService.updateMeetingTemplate(template, with: spec)
    }

    func deleteMeetingTemplate(_ template: PromptAction) {
        promptActionService.deleteMeetingTemplate(template)
    }

    /// Dictation-surface prompt actions (read-only) for the unified library's Dictation section.
    var dictationActions: [PromptAction] {
        promptActionService.promptActions
    }

    /// Poll the calendar roughly once a minute while the meetings UI is visible (plan D10).
    func startCalendarPolling() {
        loadUpcoming()
        guard pollingCancellable == nil else { return }
        pollingCancellable = Timer.publish(every: 60, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.loadUpcoming()
            }
    }

    func stopCalendarPolling() {
        pollingCancellable?.cancel()
        pollingCancellable = nil
    }

    /// Derived from the service's synchronously-updated `meetings` (not the Combine-mirrored
    /// `self.meetings`) so `loadUpcoming()` called right after `createMeeting` sees the newly
    /// created event and excludes it immediately.
    ///
    /// [Track D] Auto-brief placeholder meetings (pre-created by the scheduler without any user
    /// action, still `.scheduled`) are deliberately NOT excluded: excluding them would drop the
    /// event from the Upcoming section ~lead-minutes before it starts, taking the "Brief ready"
    /// affordance and the start-notification prompt with it (AD9/finding 1). Once the user engages
    /// such a meeting (capture starts → state leaves `.scheduled`), it is excluded like any other.
    private var existingCalendarEventIDs: Set<String> {
        Self.engagedCalendarEventIDs(
            meetings: meetingService.meetings,
            autoBriefPlaceholders: briefScheduler.placeholderEventIDs
        )
    }

    /// The calendar-event ids to exclude from the Upcoming list: every stored meeting's
    /// `calendarEventID` except auto-brief placeholders still in `.scheduled` state (finding 1).
    /// Static + pure so the exclusion rule is unit-testable without constructing the full view model.
    static func engagedCalendarEventIDs(
        meetings: [Meeting],
        autoBriefPlaceholders placeholders: Set<String>
    ) -> Set<String> {
        Set(
            meetings.compactMap { meeting -> String? in
                guard let id = meeting.calendarEventID else { return nil }
                if meeting.state == .scheduled, placeholders.contains(id) { return nil }
                return id
            }
        )
    }

    #if DEBUG
    func seedDemoMeeting() {
        meetingService.seedDemoMeeting()
    }
    #endif
}
