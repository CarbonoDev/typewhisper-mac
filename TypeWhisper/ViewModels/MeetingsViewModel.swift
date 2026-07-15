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

    /// Multi-select on the Meetings list + folder detail surfaces (plan LX-1, D3; the `HistoryViewModel`
    /// `selectedRecordIDs` analog). Held on the list's data-source VM — not the navigation coordinator
    /// (frozen API) and not an extension file (extension-file discipline forbids stored state). The
    /// views bind this into `List(selection:)` (Meetings list) or the hand-rolled `SelectionGesture`
    /// (timeline) and normalize it to the visible set on filter change. LX-1 adds no action over it.
    @Published var selectedMeetingIDs: Set<UUID> = []

    /// The selection intersected with a supplied visible-id list (the `HistoryViewModel`
    /// `visibleSelectedRecordIDs` analog). A convenience for surfaces that want the effective, on-screen
    /// selection without mutating `selectedMeetingIDs`.
    func visibleSelection(in visibleIDs: [UUID]) -> Set<UUID> {
        selectedMeetingIDs.intersection(visibleIDs)
    }

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
    /// True while `stop()`'s off-MainActor teardown is finalizing this meeting (recorder mixdown,
    /// audio adopt). Mirrored from the capture service so the live band and the document bottom bar
    /// show a "Finalizing…" posture the instant Stop is pressed, without the window freezing.
    @Published private(set) var isFinalizing = false
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
    // [Track J] `isGeneratingBrief` is no longer a VM mirror — brief generation runs on the `.brief`
    // job (llm lane) and is surfaced meeting-scoped via `isGeneratingBrief(for:)`.
    @Published var briefErrorMessage: String?
    @Published var briefErrorNeedsProvider = false

    // In-meeting Q&A (M6)
    /// [Track J] Meeting-scoped Q&A activity (plan J2): mirrored from `MeetingLLMService`. Asking a
    /// question in meeting A must not disable meeting B's Ask field, so this is a set, not a bool.
    @Published private(set) var answeringMeetingIDs: Set<UUID> = []
    @Published var qaErrorMessage: String?
    @Published var qaErrorNeedsProvider = false

    // Obsidian export (M7)
    @Published var exportErrorMessage: String?

    // Import / merge (M8)
    // [Track J] `isImporting` is no longer a VM mirror — audio import runs on the `.audioImport` job
    // (transcription lane) and is surfaced via `isImporting()` (global: a new-meeting import has no
    // meeting id, and the import UI is a modal sheet).
    @Published var importErrorMessage: String?

    // Speaker diarization & mapping (M9)
    // [Track J] `isEnriching` is no longer a VM mirror — diarization runs on the `.diarization` job
    // (transcription lane) and is surfaced meeting-scoped via `isEnriching(for:)`.
    @Published var diarizationErrorMessage: String?
    /// A localized status shown after enrichment finishes without labeling (e.g. "no speakers
    /// detected"). Cleared when a new enrichment starts.
    @Published var diarizationStatusMessage: String?

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
    // [M2] Per-meeting language detection (plan D5). `internal` so `MeetingsViewModel+Language.swift`
    // (extension-file discipline) reaches it for the chip's Detect / Re-detect action and the
    // post-import auto-detect enqueue.
    let languageService: MeetingLanguageService
    // [M7] `internal` (not private) so `MeetingsViewModel+FolderContext.swift` reaches it for the
    // folder detail view's read-only vault search (attachment picker).
    let vaultService: ObsidianVaultService
    private let briefService: MeetingBriefService
    // [M8] Agentic related-document discovery (Amendment 2). `internal` so
    // `MeetingsViewModel+RelatedDocs.swift` reaches it for the meeting document's Related Documents
    // section (Find related, manual add/remove, resolved-union rows).
    let relatedDocsService: MeetingRelatedDocsService
    // [M7] Per-folder context config store (Amendment 1, DA4). `internal` so the folder-context
    // extension routes description/attachment/toggle writes through the single-writer store; the
    // folder detail view observes `MeetingFolderMetadataStore.shared` directly for live updates.
    let folderMetadataStore: MeetingFolderMetadataStore
    private let exporter: MeetingObsidianExporter
    private let importService: MeetingImportService
    private let diarizationEnricher: MeetingDiarizationEnricher
    // [Track C] Capture-context rules service (addendum AD7). Rule CRUD, context building, and
    // resolution preview live in `MeetingsViewModel+Rules.swift`.
    let contextRuleService: MeetingContextRuleService
    // [Track D] Auto pre-meeting briefs (plan AD9). Internal so `MeetingsViewModel+AutoBrief` reaches it.
    let briefScheduler: MeetingBriefScheduler
    // [Track J] Central background-job queue (plan J1/J2). Output/brief generation, audio import, and
    // diarization are routed through it so their spinners are meeting-scoped (do not follow
    // navigation) and double-clicks are deduped. `internal` so `MeetingsViewModel+AutoBrief` can
    // derive the auto-brief status line from the queue.
    let jobQueue: JobQueueService
    private var cancellables = Set<AnyCancellable>()
    private var pollingCancellable: AnyCancellable?

    init(
        meetingService: MeetingService,
        promptActionService: PromptActionService,
        calendarService: CalendarService,
        captureService: MeetingCaptureService,
        startNotificationService: MeetingStartNotificationService,
        llmService: MeetingLLMService,
        languageService: MeetingLanguageService, // [M2]
        vaultService: ObsidianVaultService,
        briefService: MeetingBriefService,
        relatedDocsService: MeetingRelatedDocsService, // [M8]
        folderMetadataStore: MeetingFolderMetadataStore, // [M7]
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
        self.languageService = languageService // [M2]
        self.vaultService = vaultService
        self.briefService = briefService
        self.relatedDocsService = relatedDocsService // [M8]
        self.folderMetadataStore = folderMetadataStore // [M7]
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
        // Q&A activity IS mirrored (Q&A stays out of the queue) but is now a per-meeting set (J2).
        llmService.$answeringMeetingIDs
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in self?.answeringMeetingIDs = value }
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
        captureService.$isFinalizing
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in self?.isFinalizing = value }
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
        // [Track J] `isGeneratingBrief`, `isImporting`, `isEnriching`, and the auto-brief scheduler
        // status are no longer VM mirrors: brief/import/diarization run as queue jobs and are surfaced
        // via `isGeneratingBrief(for:)` / `isImporting()` / `isEnriching(for:)`, and the auto-brief
        // status line is derived from the queue in `autoBriefStatusMessage`. Leaf views observe
        // `JobQueueService.shared` directly for reactivity (plan §CC7).
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

    // MARK: - Meeting identity: rename / date / calendar linking

    /// Rename a meeting from the document header's inline title editor. Routes through the
    /// single-writer `MeetingService.setTitle`, which never touches calendar linkage
    /// (`calendarEventID` / `seriesID` / `attendees`), so the upcoming-list dedupe and prior-meeting
    /// matching keep recognizing the renamed meeting (owner requirement 1).
    func renameMeeting(_ meeting: Meeting, to title: String) {
        meetingService.setTitle(title, for: meeting)
    }

    /// Whether the document should offer an editable date chip: only for meetings **not** linked to
    /// a calendar event (ad-hoc + imported). A linked meeting's date is owned by its event. Pure so
    /// the visibility rule is unit-testable without the full view model (owner requirement 2).
    nonisolated static func showsDateEditor(calendarEventID: String?) -> Bool {
        calendarEventID == nil
    }

    /// Set (or clear) an unlinked meeting's date via the single-writer `MeetingService.setMeetingDate`
    /// — the same `startDate` the timeline day-grouping, prior-meeting matching, and related-docs
    /// signals read (owner requirement 2). Callers gate on `showsDateEditor`.
    func setMeetingDate(_ date: Date?, for meeting: Meeting) {
        meetingService.setMeetingDate(date, for: meeting)
    }

    /// Ranked candidate events for the "Link to calendar event…" picker (owner requirement 3):
    /// historical events within `± window` of the meeting's date, optionally narrowed by the search
    /// field, ordered by title similarity + date proximity. Empty when calendar access is not
    /// granted.
    func linkCandidates(
        for meeting: Meeting,
        query: String = "",
        window: TimeInterval = CalendarService.defaultLinkWindow
    ) -> [CalendarEventDTO] {
        let reference = meeting.startDate ?? meeting.createdAt
        let raw = calendarService.linkCandidates(around: reference, window: window)
        let filtered = CalendarService.filterLinkCandidates(raw, query: query)
        return CalendarService.rankedLinkCandidates(
            events: filtered,
            targetTitle: meeting.title,
            targetDate: reference,
            window: window
        )
    }

    /// Link a meeting to a chosen historical calendar event: adopt its id/series/attendees and
    /// start date (title only if the meeting's is empty/default) via `MeetingService`, then refresh
    /// the upcoming list so the newly-backed event drops out of it (owner requirement 3).
    func linkMeeting(_ meeting: Meeting, to event: CalendarEventDTO) {
        let projection = CalendarService.meetingProjection(for: event)
        meetingService.linkToCalendarEvent(
            calendarEventID: projection.calendarEventID,
            seriesID: projection.seriesID,
            title: projection.title,
            startDate: projection.startDate,
            endDate: projection.endDate,
            attendees: projection.attendees,
            for: meeting
        )
        loadUpcoming()
    }

    /// Unlink a meeting from its calendar event (keeps all content), then refresh the upcoming list
    /// so the freed event can reappear as an upcoming/earlier candidate (owner requirement 3).
    func unlinkMeeting(_ meeting: Meeting) {
        meetingService.unlinkCalendarEvent(for: meeting)
        loadUpcoming()
    }

    // MARK: - Bulk / context-menu actions (plan LX-2, D4/D5/D6)

    /// The multi-selected meetings — `selectedMeetingIDs` intersected with the list, in list order.
    /// The bulk context-menu actions operate over this set.
    func selectedMeetings() -> [Meeting] {
        meetings.filter { selectedMeetingIDs.contains($0.id) }
    }

    /// Delete a single meeting (context-menu "Delete"), removing its audio blob, and drop it from the
    /// selection. Callers gate on a confirmation dialog.
    func deleteMeeting(_ meeting: Meeting) {
        meetingService.deleteMeeting(meeting)
        selectedMeetingIDs.remove(meeting.id)
    }

    /// Delete a set of meetings in one save (bulk "Delete N meetings"), dropping them from the
    /// selection. Callers gate on a count-aware confirmation dialog. No-op on an empty set.
    func deleteMeetings(_ meetings: [Meeting]) {
        guard !meetings.isEmpty else { return }
        meetingService.deleteMeetings(meetings)
        selectedMeetingIDs.subtract(meetings.map(\.id))
    }

    /// Generate a summary for a meeting using its default summary template (context-menu "Generate
    /// summary"). Enqueues an `llm`-lane `.summary` job via `generateOutput`; the queue's
    /// `(kind, meetingID)` dedupe collapses a double-fire. Surfaces an error when no summary template
    /// exists (the picker is normally seeded, so this is a defensive fallback).
    func generateSummary(for meeting: Meeting) {
        guard let template = defaultTemplate(ofKind: .summary, for: meeting) else {
            outputErrorMessage = String(localized: "meetings.menu.generate.noTemplate")
            outputErrorNeedsProvider = false
            return
        }
        generateOutput(for: meeting, using: template)
    }

    /// Bulk "Generate summaries": one `.summary` llm-lane job per meeting. The cap-1 `llm` lane
    /// serializes the provider and the `(summary, meetingID)` dedupe prevents doubles (plan LX-2 D6).
    func generateSummaries(for meetings: [Meeting]) {
        for meeting in meetings { generateSummary(for: meeting) }
    }

    /// Bulk "Generate briefs": one `.brief` llm-lane job per meeting, deduped on `(brief, meetingID)`
    /// (plan LX-2 D6).
    func generateBriefs(for meetings: [Meeting]) {
        for meeting in meetings { generateBrief(for: meeting) }
    }

    /// Default export sections for a one-click (context-menu) export — the export sheet's defaults.
    static let defaultExportSections: [MeetingExportSection] = [.summary, .transcript, .notes]

    /// Export a single meeting to the connected vault via the `.export` job (context-menu "Export to
    /// vault"). See `enqueueExport` — this is the first real use of the `.export` io lane (plan LX-2 D6).
    func exportToVault(_ meeting: Meeting) {
        enqueueExport([meeting])
    }

    /// Bulk "Export to vault": one `.export` io-lane job per meeting. The `io` lane is unbounded so the
    /// exports run in parallel without blocking the UI; each records `recordObsidianExport` on success
    /// so the "In vault" badge appears as each completes (plan LX-2 D6).
    func exportToVault(_ meetings: [Meeting]) {
        enqueueExport(meetings)
    }

    /// Enqueue a `.export` job per meeting on the `io` lane (plan LX-2 D6 — the first `.export`
    /// enqueue; export was synchronous before). The operation runs the existing synchronous exporter
    /// off the button, records a real export on success, and rethrows on failure so the job settles
    /// `.failed` for the activity popover.
    private func enqueueExport(
        _ meetings: [Meeting],
        sections: [MeetingExportSection] = MeetingsViewModel.defaultExportSections,
        combined: Bool = false
    ) {
        exportErrorMessage = nil
        for meeting in meetings {
            jobQueue.enqueue(
                kind: .export,
                meetingID: meeting.id,
                progressLabel: String(localized: "meetings.jobs.progress.exporting")
            ) { [weak self] in
                guard let self else { return }
                do {
                    // Off-main write: `exportOffMain` renders the meeting on the MainActor then hands
                    // the file I/O to a detached task, so the unbounded io lane's bulk exports overlap
                    // on disk instead of blocking the UI (plan LX-2 D6). Resumes on the MainActor.
                    let urls = try await self.exporter.exportOffMain(meeting, sections: sections, combined: combined)
                    if !urls.isEmpty {
                        self.meetingService.recordObsidianExport(for: meeting)
                    }
                } catch {
                    self.exportErrorMessage = error.localizedDescription
                    throw error
                }
            }
        }
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
        // Three-way kind mapping so a `.brief` template enqueues as `.brief` (not `.summary`): the
        // auto-brief dedupe on `(brief, meetingID)` and the brief-scoped spinner depend on the job
        // carrying the correct kind. `.extended` → `.extendedAnalysis`; everything else → `.summary`.
        //
        // DEDUPE-PRIORITY (J2 review finding 2): a user-selected `.brief` template shares the
        // `(brief, meetingID)` dedupe key with the auto-brief scheduler's `.background` jobs. Sharing
        // the key is intentional — both produce the same brief output — but this enqueue is
        // `.userInitiated` (the default), so if it dedupes against a still-`.queued` background
        // auto-brief, `JobQueueService.enqueue` promotes that queued job to `.userInitiated` and the
        // user no longer waits behind background work. See the promotion note in `JobQueueService`.
        let kind: MeetingJobKind
        switch template.meetingKind {
        case .extended: kind = .extendedAnalysis
        case .brief: kind = .brief
        default: kind = .summary
        }
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
    ///
    /// [Track J] Routed through the job queue (plan J2): a `.brief` job on the `llm` lane (cap 1),
    /// deduped on `(brief, meetingID)`, so a user brief and the auto-brief scheduler never run two LLM
    /// calls at once for the same meeting and a double-click produces one brief. Enqueue is synchronous.
    func generateBrief(for meeting: Meeting) {
        briefErrorMessage = nil
        briefErrorNeedsProvider = false
        jobQueue.enqueue(
            kind: .brief,
            meetingID: meeting.id,
            progressLabel: String(localized: "meetings.jobs.progress.generating")
        ) { [weak briefService, weak self] in
            guard let briefService else { return }
            do {
                _ = try await briefService.generateBrief(for: meeting)
            } catch {
                self?.recordBriefError(error)
                throw error
            }
        }
    }

    /// Publish a brief-generation failure for the brief view (the "needs provider" deep link). Split
    /// out so the job-queue closure can record it before rethrowing (which marks the job `.failed`).
    private func recordBriefError(_ error: Error) {
        briefErrorMessage = error.localizedDescription
        briefErrorNeedsProvider = needsProviderSetup(error)
    }

    /// Whether a `.brief` job is in flight for this meeting — drives the brief view spinner.
    /// Meeting-scoped so it does not follow navigation.
    func isGeneratingBrief(for meeting: Meeting) -> Bool {
        jobQueue.hasActiveJob(kind: .brief, meetingID: meeting.id)
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

    /// Whether a Q&A answer is currently in flight for `meetingID` (plan J2, meeting-scoped): asking
    /// in meeting A leaves this false for meeting B.
    func isAnswering(for meetingID: UUID) -> Bool {
        answeringMeetingIDs.contains(meetingID)
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
            let meeting = try importService.importTranscriptFile(at: url)
            // [M2] Transcript-ready choke point (plan D5): a transcript-file import creates a meeting
            // with content but no language — auto-enqueue a background detection.
            languageService.enqueueAutoDetection(for: meeting)
            return meeting
        } catch {
            importErrorMessage = error.localizedDescription
            return nil
        }
    }

    /// Import an audio file as a new meeting: it is decoded, transcribed, and adopted into the
    /// meetings library. `onImported` is called with the created meeting once transcription finishes.
    ///
    /// [Track J] Routed through the job queue (plan J2): an `.audioImport` job on the `transcription`
    /// lane (cap 1), so an import shares the lane with a meeting's final pass instead of contending for
    /// the same local compute. A new-meeting import has no meeting id (`nil` dedupe key), so two
    /// different files both import. Cancelling the job creates no meeting (transcription is awaited
    /// before `createFromImport` runs). Failures surface via `importErrorMessage`.
    ///
    /// `languageCode` (plan M1): an optional language chosen in the import sheet's picker. A specific
    /// code drives transcription and is persisted `.manual` on the created meeting; `nil` = Auto.
    func importAudioFile(
        at url: URL,
        languageCode: String? = nil,
        onImported: @escaping (Meeting) -> Void = { _ in }
    ) {
        importErrorMessage = nil
        jobQueue.enqueue(
            kind: .audioImport,
            meetingID: nil,
            progressLabel: String(localized: "meetings.jobs.progress.importing")
        ) { [weak importService, weak self] in
            guard let importService else { return }
            do {
                let meeting = try await importService.importAudioFile(at: url, languageCode: languageCode)
                // [M2] Transcript-ready choke point (plan D5): auto-enqueue a background detection when
                // the import was left on Auto (a chosen language persists `.manual`, so the enqueue's own
                // `languageCode == nil` guard makes this a no-op there).
                self?.languageService.enqueueAutoDetection(for: meeting)
                onImported(meeting)
            } catch {
                self?.importErrorMessage = error.localizedDescription
                throw error
            }
        }
    }

    /// Whether any audio-import job is active (plan J2). Global — a new-meeting import has no meeting
    /// id and the import UI is a modal sheet, so a global signal is correct (plan §CC6).
    func isImporting() -> Bool {
        jobQueue.jobs.contains { $0.kind == .audioImport && $0.state.isActive }
    }

    /// Merge an imported transcript file into an existing meeting, time-ordered and deduped against
    /// the captured transcript (plan D12). Returns true on success.
    @discardableResult
    func mergeTranscriptFile(at url: URL, into meeting: Meeting) -> Bool {
        importErrorMessage = nil
        do {
            try importService.mergeTranscriptFile(at: url, into: meeting)
            // [M2] Transcript-ready choke point (plan D5): a merge adds transcript content, so a
            // meeting that still has no language must auto-enqueue a background detection — same
            // trigger as the new-meeting transcript import. No-op when the language is already set
            // (the enqueue's own `languageCode == nil` guard).
            languageService.enqueueAutoDetection(for: meeting)
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
    ///
    /// [Track J] Routed through the job queue (plan J2): a `.diarization` job on the `transcription`
    /// lane (cap 1), so it serializes with a meeting's final pass / an audio import rather than
    /// oversubscribing local compute. Enqueue is synchronous; a cancelled pass writes no labels
    /// (`applySpeakerLabels` runs only after a successful return).
    func identifySpeakers(for meeting: Meeting) {
        diarizationErrorMessage = nil
        diarizationStatusMessage = nil
        // [Speaker-recognition amendment, D-A5] Hint pyannote with the known participant count so a
        // 2-person meeting that fell through to the sidecar (correlated channels) — or any exact-count
        // meeting — pins the right number of speakers instead of the global default.
        let numSpeakersHint = SpeakerSourcePlan.effectiveParticipantCount(for: meeting)
        // [M9-SPK-B / D-A6] When the meeting still carries coarse live timestamps, Identify first runs a
        // timing-only reference transcription (inside the same job) to refine per-segment timing, so the
        // spinner label discloses the extra work rather than showing a bare "identifying speakers".
        let refinesTimingFirst = pyannoteIdentifyRefinesTimingFirst(for: meeting)
        let progressLabel = refinesTimingFirst
            ? String(localized: "meetings.speakers.progress.refiningTiming")
            : String(localized: "meetings.jobs.progress.diarizing")
        jobQueue.enqueue(
            kind: .diarization,
            meetingID: meeting.id,
            progressLabel: progressLabel
        ) { [weak diarizationEnricher, weak self] in
            guard let diarizationEnricher else { return }
            do {
                let outcome = try await diarizationEnricher.enrich(meeting, numSpeakersHint: numSpeakersHint)
                self?.recordDiarizationOutcome(outcome)
            } catch is CancellationError {
                // A cancelled re-pass/diarization wrote nothing (times and labels persist only on
                // success); surface no error — the job settles `.cancelled` and the meeting is unchanged.
                throw CancellationError()
            } catch {
                self?.diarizationErrorMessage = error.localizedDescription
                throw error
            }
        }
    }

    /// Whether pressing Identify on `meeting` will first run the keep-live timing re-pass (M9-SPK-B /
    /// D-A6): true when the segments still carry coarse live timestamps (`timestampsRefined != true`).
    /// Drives the "(refines timing first)" button copy on the pyannote path so the extra transcription
    /// cost is disclosed only when it will actually be paid. A meeting whose times were already refined
    /// by a final pass or a prior re-pass reads `false` and shows the plain "Identify speakers" copy.
    func pyannoteIdentifyRefinesTimingFirst(for meeting: Meeting) -> Bool {
        meeting.timestampsRefined != true
    }

    /// Whether provider (cloud) speaker labels are preferred over local diarization (D-A2/D-A7).
    /// Registered default ON; read from UserDefaults so the setting drives both adoption and the
    /// path-aware Identify UI.
    var preferProviderSpeakerLabels: Bool {
        UserDefaults.standard.object(forKey: UserDefaultsKeys.meetingsPreferProviderSpeakerLabels) as? Bool ?? true
    }

    /// The speaker-labeling source that *will* run for a meeting (D-A2/D-A7), so the Identify UI can
    /// state the path (cloud / channel / pyannote) rather than being a mystery. Async because the
    /// track availability comes from a cheap audio-header probe.
    func plannedSpeakerSource(for meeting: Meeting) async -> SpeakerSource {
        let availability = await diarizationEnricher.availability(for: meeting)
        // Only *provider*-originated labels feed the cloud rung. A meeting the app already labeled
        // locally — the two-person channel path (SPEAKER_ME/OTHERS) or local pyannote (SPEAKER_00…) —
        // must NOT resolve `.cloud`, or it would lose its channel Undo/Redo affordance and hide the
        // pyannote Identify button (finding). The vocabulary test is shared with the finalization
        // adoption check so the two paths always agree.
        let labeled = meeting.segments.contains { SpeakerSourcePlan.isProviderOriginatedLabel($0.speakerLabel) }
        return SpeakerSourcePlan.resolve(SpeakerSourceAvailability(
            segmentsAlreadyLabeled: labeled,
            preferProviderLabels: preferProviderSpeakerLabels,
            effectiveParticipantCount: SpeakerSourcePlan.effectiveParticipantCount(for: meeting),
            trackAvailability: availability
        ))
    }

    /// Whether the two-person-call toggle should be offered for a meeting (D-A4): only for
    /// attendee-less (ad-hoc) meetings, where the participant count is otherwise unknown. Calendar
    /// meetings derive their count from attendees and never show the toggle.
    func showsTwoPersonToggle(for meeting: Meeting) -> Bool {
        meeting.attendees.isEmpty
    }

    /// The current state of the two-person-call toggle (D-A4).
    func isTwoPersonCall(_ meeting: Meeting) -> Bool {
        meeting.twoPersonCall == true
    }

    /// Persist the ad-hoc two-person-call override (D-A4).
    func setTwoPersonCall(_ enabled: Bool, for meeting: Meeting) {
        meetingService.setTwoPersonCall(enabled ? true : nil, for: meeting)
    }

    /// Undo speaker labels (D-A4): clear every segment label + the speaker map. Also the escape hatch
    /// for an automatic labeling the user disagrees with.
    func clearSpeakerLabels(for meeting: Meeting) {
        diarizationStatusMessage = nil
        diarizationErrorMessage = nil
        meetingService.clearSpeakerLabels(for: meeting)
    }

    /// Redo / re-run the two-person channel labeling (D-A4), e.g. after an Undo. Enqueued on the
    /// transcription lane like Identify so it serializes with other audio work; a no-op when the
    /// recording is not separate-track.
    func relabelByChannel(for meeting: Meeting) {
        diarizationErrorMessage = nil
        diarizationStatusMessage = nil
        let otherName = SpeakerSourcePlan.otherPartyName(for: meeting)
        jobQueue.enqueue(
            kind: .diarization,
            meetingID: meeting.id,
            progressLabel: String(localized: "meetings.jobs.progress.diarizing")
        ) { [weak diarizationEnricher, weak self] in
            guard let diarizationEnricher else { return }
            let outcome = await diarizationEnricher.autoLabelTwoPersonChannel(meeting, otherPartyName: otherName)
            self?.recordDiarizationOutcome(outcome)
        }
    }

    /// Surface an enrichment outcome as a status line (plan D8). Split out so the job-queue closure
    /// can publish it on the main actor after a successful (non-throwing) enrich.
    private func recordDiarizationOutcome(_ outcome: MeetingDiarizationEnricher.Outcome) {
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
    }

    /// Whether a `.diarization` job is in flight for this meeting — drives the "Identify speakers"
    /// spinner. Meeting-scoped so it does not follow navigation.
    func isEnriching(for meeting: Meeting) -> Bool {
        jobQueue.hasActiveJob(kind: .diarization, meetingID: meeting.id)
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
