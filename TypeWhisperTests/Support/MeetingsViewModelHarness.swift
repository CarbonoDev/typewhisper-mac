import TypeWhisperPluginSDK
import XCTest
@testable import TypeWhisper

/// [Perf · finding 12] Builds a real `MeetingsViewModel` over test-constructible services (temp
/// stores, isolated defaults, a fake calendar provider, a recorder whose start/stop are stubbed, an
/// LLM processor that never runs), so the VM's service mirrors can be exercised end to end. Call
/// `tearDown()` from the test's async `tearDown`.
@MainActor
final class MeetingsViewModelHarness {
    private final class IdleProcessor: PromptProcessing {
        var selectedProviderId = "p"
        var selectedCloudModel = "m"
        func process(
            prompt: String,
            text: String,
            providerOverride: String?,
            cloudModelOverride: String?,
            temperatureDirective: PluginLLMTemperatureDirective,
            skipMemoryInjection: Bool
        ) async throws -> String { "" }
    }

    final class FakeCalendar: CalendarEventProviding {
        var authorizationStatus: CalendarAuthorizationStatus = .notDetermined
        var requestResult: CalendarAuthorizationStatus = .authorized
        var eventsToReturn: [CalendarEventDTO] = []

        func requestAccess() async -> CalendarAuthorizationStatus {
            authorizationStatus = requestResult
            return requestResult
        }
        func events(from start: Date, to end: Date) -> [CalendarEventDTO] { eventsToReturn }
        func calendars() -> [CalendarInfo] { [] }
    }

    let viewModel: MeetingsViewModel
    let meetingService: MeetingService
    let calendarProvider: FakeCalendar
    let calendarService: CalendarService
    let captureService: MeetingCaptureService
    let jobQueue: JobQueueService
    /// Optional hook run inside the stubbed recorder start — after `isCapturing` is claimed, while
    /// `start()` is suspended.
    var duringRecorderStart: (() async -> Void)?
    /// Capture start resolves engines through `PluginManager.shared`, which the test host leaves
    /// unset; install an empty one for the harness's lifetime (as `MeetingLanguageTests` does).
    private let previousPluginManager: PluginManager?
    private let directory: URL
    private let defaultsSuite: String

    init() throws {
        previousPluginManager = PluginManager.shared
        PluginManager.shared = PluginManager()
        let dir = try TestSupport.makeTemporaryDirectory(prefix: "MeetingsViewModelHarness")
        let suite = "MeetingsViewModelHarness-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        // Removed in `tearDown()`, after capture stops and the queue drains — XCTest runs teardown
        // blocks *before* the test's `tearDown()`, which would pull the store out from under the
        // final-pass job.
        self.directory = dir
        self.defaultsSuite = suite

        let jobQueue = JobQueueService()
        let meetingService = MeetingService(appSupportDirectory: dir)
        let promptActionService = PromptActionService(appSupportDirectory: dir)
        let calendarProvider = FakeCalendar()
        let selection = CalendarSelectionStore(defaults: defaults, key: "calendar-selection")
        let calendarService = CalendarService(provider: calendarProvider, selectionStore: selection)
        let vault = ObsidianVaultService(defaults: defaults)
        let folders = MeetingFolderMetadataStore(defaults: defaults)
        let processor = IdleProcessor()

        let recorder = AudioRecorderService()
        recorder.recordingsDirectoryOverride = dir.appendingPathComponent("recordings", isDirectory: true)
        let capture = MeetingCaptureService(
            meetingService: meetingService,
            audioRecorderService: recorder,
            modelManager: ModelManagerService(),
            jobQueue: jobQueue,
            defaults: defaults,
            flushIntervalSeconds: 0
        )
        let briefService = MeetingBriefService(meetingService: meetingService, vaultService: vault, processor: processor)

        viewModel = MeetingsViewModel(
            meetingService: meetingService,
            promptActionService: promptActionService,
            calendarService: calendarService,
            captureService: capture,
            startNotificationService: MeetingStartNotificationService(center: nil),
            endReminderService: MeetingEndReminderService(center: nil),
            llmService: MeetingLLMService(meetingService: meetingService, vaultService: vault, processor: processor),
            languageService: MeetingLanguageService(
                meetingService: meetingService, processor: processor, jobQueue: jobQueue, defaults: defaults
            ),
            vaultService: vault,
            briefService: briefService,
            relatedDocsService: MeetingRelatedDocsService(
                meetingService: meetingService, vaultService: vault, folderMetadataStore: folders, processor: processor
            ),
            folderMetadataStore: folders,
            exporter: MeetingObsidianExporter(vaultService: vault, defaults: defaults),
            importService: MeetingImportService(
                meetingService: meetingService, audioFileService: AudioFileService(), transcriber: ModelManagerService()
            ),
            diarizationEnricher: MeetingDiarizationEnricher(meetingService: meetingService),
            contextRuleService: MeetingContextRuleService(appSupportDirectory: dir),
            briefScheduler: MeetingBriefScheduler(
                store: meetingService, briefService: briefService, jobQueue: jobQueue, defaults: defaults
            ),
            jobQueue: jobQueue,
            participantDirectoryService: ParticipantDirectoryService(appSupportDirectory: dir)
        )
        self.meetingService = meetingService
        self.calendarProvider = calendarProvider
        self.calendarService = calendarService
        self.captureService = capture
        self.jobQueue = jobQueue

        recorder.startRecordingOverride = { [weak self] _, _, _, outputURL, _ in
            await self?.duringRecorderStart?()
            try FileManager.default.createDirectory(
                at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try Data("placeholder".utf8).write(to: outputURL)
            return outputURL
        }
        recorder.stopRecordingOverride = { outputURL in
            try Data("recorded".utf8).write(to: outputURL)
            return outputURL
        }
        recorder.currentBufferOverride = { [] }
    }

    /// Stop any capture and drain the queue so nothing writes into a removed temp store.
    func tearDown() async {
        if captureService.isCapturing { await captureService.stop() }
        for job in jobQueue.jobs where job.state.isActive { jobQueue.cancel(job.id) }
        await jobQueue.drain()
        PluginManager.shared = previousPluginManager
        TestSupport.remove(directory)
        UserDefaults().removePersistentDomain(forName: defaultsSuite)
    }
}
