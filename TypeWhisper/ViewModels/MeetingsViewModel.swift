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

    // Outputs / templates (M4)
    @Published private(set) var templates: [MeetingTemplate] = []
    @Published private(set) var isGeneratingOutput = false
    @Published var outputErrorMessage: String?

    // Calendar (M2)
    @Published private(set) var calendarAuthorizationStatus: CalendarAuthorizationStatus = .notDetermined
    @Published private(set) var upcomingEvents: [CalendarEventDTO] = []
    @Published private(set) var calendarErrorMessage: String?

    // Capture (M3)
    @Published private(set) var activeMeeting: Meeting?
    @Published private(set) var isCapturing = false
    @Published private(set) var liveTranscript: String = ""
    @Published private(set) var captureElapsedSeconds: TimeInterval = 0
    @Published private(set) var isDegradedLiveMode = false
    @Published private(set) var captureErrorMessage: String?

    // Knowledge base + brief (M5)
    @Published private(set) var isVaultConnected = false
    @Published private(set) var vaultName: String?
    @Published private(set) var isGeneratingBrief = false
    @Published var briefErrorMessage: String?

    // In-meeting Q&A (M6)
    @Published private(set) var isAnswering = false
    @Published var qaErrorMessage: String?

    // Obsidian export (M7)
    @Published var exportErrorMessage: String?

    private let meetingService: MeetingService
    private let calendarService: CalendarService
    private let captureService: MeetingCaptureService
    private let startNotificationService: MeetingStartNotificationService
    private let llmService: MeetingLLMService
    private let vaultService: ObsidianVaultService
    private let briefService: MeetingBriefService
    private let exporter: MeetingObsidianExporter
    private var cancellables = Set<AnyCancellable>()
    private var pollingCancellable: AnyCancellable?

    init(
        meetingService: MeetingService,
        calendarService: CalendarService,
        captureService: MeetingCaptureService,
        startNotificationService: MeetingStartNotificationService,
        llmService: MeetingLLMService,
        vaultService: ObsidianVaultService,
        briefService: MeetingBriefService,
        exporter: MeetingObsidianExporter
    ) {
        self.meetingService = meetingService
        self.calendarService = calendarService
        self.captureService = captureService
        self.startNotificationService = startNotificationService
        self.llmService = llmService
        self.vaultService = vaultService
        self.briefService = briefService
        self.exporter = exporter
        self.meetings = meetingService.meetings
        self.templates = meetingService.templates
        self.calendarAuthorizationStatus = calendarService.authorizationStatus
        self.upcomingEvents = calendarService.upcomingEvents
        self.calendarErrorMessage = calendarService.errorMessage
        self.isVaultConnected = vaultService.isConnected
        self.vaultName = vaultService.vaultName

        meetingService.$meetings
            .receive(on: DispatchQueue.main)
            .sink { [weak self] meetings in
                self?.meetings = meetings
            }
            .store(in: &cancellables)

        meetingService.$templates
            .receive(on: DispatchQueue.main)
            .sink { [weak self] templates in
                self?.templates = templates
            }
            .store(in: &cancellables)

        llmService.$isGenerating
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in self?.isGeneratingOutput = value }
            .store(in: &cancellables)
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
        captureService.$liveTranscript
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in self?.liveTranscript = value }
            .store(in: &cancellables)
        captureService.$elapsedSeconds
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in self?.captureElapsedSeconds = value }
            .store(in: &cancellables)
        captureService.$isDegradedLiveMode
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in self?.isDegradedLiveMode = value }
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
    }

    var hasMeetings: Bool { !meetings.isEmpty }

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
    /// currently owns the capture stack) via `captureErrorMessage`.
    func startCapture(for meeting: Meeting) async {
        captureErrorMessage = nil
        do {
            try await captureService.start(meeting: meeting)
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
        guard !captureService.isCapturing else { return nil }
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

    /// Create (or reuse) the meeting backing a calendar event, then begin capture.
    func startCapture(from event: CalendarEventDTO) async {
        let meeting = createMeeting(from: event)
        await startCapture(for: meeting)
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
    func templates(ofKind kind: MeetingOutputKind) -> [MeetingTemplate] {
        meetingService.templates(ofKind: kind)
    }

    /// The newest output of a kind for a meeting (what the detail view surfaces).
    func latestOutput(ofKind kind: MeetingOutputKind, for meeting: Meeting) -> MeetingOutput? {
        meetingService.latestOutput(ofKind: kind, for: meeting)
    }

    /// Generate (or regenerate) an output for a meeting from a template. Regeneration inserts a
    /// new row; the detail view shows the newest per kind. Surfaces failures via
    /// `outputErrorMessage`.
    func generateOutput(for meeting: Meeting, using template: MeetingTemplate) async {
        outputErrorMessage = nil
        do {
            try await llmService.generateOutput(for: meeting, using: template)
        } catch {
            outputErrorMessage = error.localizedDescription
        }
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
        do {
            try await briefService.generateBrief(for: meeting)
        } catch {
            briefErrorMessage = error.localizedDescription
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
        let offset: Double? = (isCapturing && activeMeeting?.id == meeting.id) ? captureElapsedSeconds : nil
        do {
            try await llmService.answerQuestion(for: meeting, question: question, asOfOffset: offset)
            return true
        } catch {
            qaErrorMessage = error.localizedDescription
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
            return urls.count
        } catch {
            exportErrorMessage = error.localizedDescription
            return nil
        }
    }

    // MARK: - Template CRUD (editor)

    @discardableResult
    func addTemplate(
        name: String,
        kind: MeetingOutputKind,
        prompt: String
    ) -> MeetingTemplate {
        meetingService.addTemplate(name: name, kind: kind, prompt: prompt)
    }

    func updateTemplate(_ template: MeetingTemplate) {
        meetingService.updateTemplate(template)
    }

    func deleteTemplate(_ template: MeetingTemplate) {
        meetingService.deleteTemplate(template)
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
    private var existingCalendarEventIDs: Set<String> {
        Set(meetingService.meetings.compactMap { $0.calendarEventID })
    }

    #if DEBUG
    func seedDemoMeeting() {
        meetingService.seedDemoMeeting()
    }
    #endif
}
