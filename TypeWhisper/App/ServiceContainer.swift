import Foundation
import Combine

@MainActor
final class ServiceContainer: ObservableObject {
    static let shared = ServiceContainer()

    // Services
    let modelManagerService: ModelManagerService
    let audioFileService: AudioFileService
    let audioRecordingService: AudioRecordingService
    let hotkeyService: HotkeyService
    let textInsertionService: TextInsertionService
    let historyService: HistoryService
    let recentTranscriptionStore: RecentTranscriptionStore
    let textDiffService: TextDiffService
    let profileService: ProfileService
    let workflowService: WorkflowService
    let translationService: AnyObject? // TranslationService (macOS 15+)
    let audioDuckingService: AudioDuckingService
    let mediaPlaybackService: MediaPlaybackService
    let dictionaryService: DictionaryService
    let targetAppCorrectionLearningService: TargetAppCorrectionLearningService
    let snippetService: SnippetService
    let userDataSyncStore: TypeWhisperUserDataSyncStore
    let cloudFolderSyncController: CloudFolderSyncController
    let soundService: SoundService
    let audioDeviceService: AudioDeviceService
    let promptActionService: PromptActionService
    let promptProcessingService: PromptProcessingService
    let pluginManager: PluginManager
    let pluginRegistryService: PluginRegistryService
    let termPackRegistryService: TermPackRegistryService
    let widgetDataService: WidgetDataService
    let memoryService: MemoryService
    let appFormatterService: AppFormatterService
    let dictationPunctuationProfileStore: DictationPunctuationProfileStore
    let punctuationRulesLoader: PunctuationRulesLoader
    let punctuationStrategyResolver: PunctuationStrategyResolver
    let punctuationVerificationService: PunctuationVerificationService
    let audioRecorderService: AudioRecorderService
    let watchFolderService: WatchFolderService
    let accessibilityAnnouncementService: AccessibilityAnnouncementService
    let speechFeedbackService: SpeechFeedbackService
    let errorLogService: ErrorLogService
    let licenseService: LicenseService
    // [Track A] Meeting-event capability bus (addendum AD4).
    let meetingEventBus: MeetingEventBus
    let meetingService: MeetingService
    let calendarService: CalendarService
    let meetingCaptureService: MeetingCaptureService
    // [Track C] Capture-context rules (addendum AD7) in an isolated `meeting-rules.store`.
    let meetingContextRuleService: MeetingContextRuleService
    let meetingStartNotificationService: MeetingStartNotificationService
    /// Posts a one-shot reminder when a calendar meeting's scheduled end passes while capture is still
    /// recording (owner request 2). Mirrors `meetingStartNotificationService`'s registration.
    let meetingEndReminderService: MeetingEndReminderService
    let meetingLLMService: MeetingLLMService
    let meetingLanguageService: MeetingLanguageService // [M2]
    let meetingModelRouter: MeetingModelRouter // [M4] per-purpose model routing (plan D9)
    let obsidianVaultService: ObsidianVaultService
    let meetingBriefService: MeetingBriefService
    // [M8] Agentic related-document discovery (Amendment 2).
    let meetingRelatedDocsService: MeetingRelatedDocsService
    let meetingObsidianExporter: MeetingObsidianExporter
    let meetingImportService: MeetingImportService
    let meetingDiarizationEnricher: MeetingDiarizationEnricher
    let meetingBriefScheduler: MeetingBriefScheduler // [Track D]
    // [Track J] Central in-memory background-job queue for per-meeting long-running work (J1).
    let meetingJobQueue: JobQueueService
    // [M3] Derived, in-memory tag/organization index over `meetingService.$meetings` (plan D6).
    let meetingOrganizationIndex: MeetingOrganizationIndex
    let meetingFolderMetadataStore: MeetingFolderMetadataStore // [M7]
    // [M2-Participants] Single-writer participant directory in an isolated `participants.store` (plan
    // D4/D5). Fed by `meetingService`'s attendee choke points via the ingest seam.
    let participantDirectoryService: ParticipantDirectoryService

    // HTTP API
    let httpServer: HTTPServer
    let apiServerViewModel: APIServerViewModel

    // ViewModels
    let fileTranscriptionViewModel: FileTranscriptionViewModel
    let dictationRecoveryViewModel: DictationRecoveryViewModel
    let settingsViewModel: SettingsViewModel
    let dictationViewModel: DictationViewModel
    let historyViewModel: HistoryViewModel
    let profilesViewModel: ProfilesViewModel
    let dictionaryViewModel: DictionaryViewModel
    let snippetsViewModel: SnippetsViewModel
    let homeViewModel: HomeViewModel
    let promptActionsViewModel: PromptActionsViewModel
    let audioRecorderViewModel: AudioRecorderViewModel
    let watchFolderViewModel: WatchFolderViewModel
    let meetingsViewModel: MeetingsViewModel
    let homeFeedViewModel: HomeFeedViewModel // [Track C]
    let spaceViewModel: SpaceViewModel // [Track E] Vault-browser (Space) view model

    private init() {
        // Services
        let inputActivationGuard = AudioInputDeviceActivationGuard()
        modelManagerService = ModelManagerService()
        audioFileService = AudioFileService()
        audioRecordingService = AudioRecordingService(
            inputActivationGuard: inputActivationGuard
        )
        hotkeyService = HotkeyService()
        textInsertionService = TextInsertionService()
        historyService = HistoryService()
        recentTranscriptionStore = RecentTranscriptionStore()
        textDiffService = TextDiffService()
        profileService = ProfileService()
        workflowService = WorkflowService()
        promptActionService = PromptActionService()
        #if canImport(Translation)
        if #available(macOS 15, *) {
            translationService = TranslationService()
        } else {
            translationService = nil
        }
        #else
        translationService = nil
        #endif
        audioDuckingService = AudioDuckingService()
        mediaPlaybackService = MediaPlaybackService()
        dictionaryService = DictionaryService()
        targetAppCorrectionLearningService = TargetAppCorrectionLearningService(
            textInsertionService: textInsertionService,
            textDiffService: textDiffService,
            dictionaryService: dictionaryService
        )
        snippetService = SnippetService()
        userDataSyncStore = TypeWhisperUserDataSyncStore(
            dictionaryService: dictionaryService,
            snippetService: snippetService
        )
        soundService = SoundService()
        audioDeviceService = AudioDeviceService(
            inputActivationGuard: inputActivationGuard
        )
        promptProcessingService = PromptProcessingService()
        pluginManager = PluginManager()
        pluginRegistryService = PluginRegistryService()
        termPackRegistryService = TermPackRegistryService()
        widgetDataService = WidgetDataService(historyService: historyService)
        memoryService = MemoryService(promptProcessingService: promptProcessingService)
        appFormatterService = AppFormatterService()
        dictationPunctuationProfileStore = DictationPunctuationProfileStore()
        punctuationRulesLoader = PunctuationRulesLoader()
        punctuationStrategyResolver = PunctuationStrategyResolver(profileStore: dictationPunctuationProfileStore)
        punctuationVerificationService = PunctuationVerificationService(rulesLoader: punctuationRulesLoader)
        audioRecorderService = AudioRecorderService(
            inputActivationGuard: inputActivationGuard
        )
        promptProcessingService.memoryService = memoryService
        promptProcessingService.modelManagerService = modelManagerService
        watchFolderService = WatchFolderService(audioFileService: audioFileService, modelManagerService: modelManagerService)
        accessibilityAnnouncementService = AccessibilityAnnouncementService()
        speechFeedbackService = SpeechFeedbackService()
        errorLogService = ErrorLogService()
        licenseService = LicenseService()
        cloudFolderSyncController = CloudFolderSyncController(
            licenseService: licenseService,
            syncStore: userDataSyncStore
        )
        // [Track A] Construct the meeting-event bus BEFORE the services that emit through it
        // (`meetingService`, `meetingCaptureService`) — the emitter holds a concrete reference and
        // never reads `.shared` lazily (addendum AD4 ordering trap). `MeetingEventBus.shared` is
        // assigned later beside `EventBus.shared` for `PluginManager`'s per-plugin host wiring.
        let meetingEventBus = MeetingEventBus()
        self.meetingEventBus = meetingEventBus
        let meetingEventEmitter = MeetingEventBusEmitter(bus: meetingEventBus)
        // [Track B] Meeting output templates are unified into `promptActions.store` (plan AD6);
        // MeetingService delegates `templates(ofKind:)` to the injected prompt-action service.
        meetingService = MeetingService(
            eventEmitter: meetingEventEmitter,
            promptActionService: promptActionService
        )
        calendarService = CalendarService()
        // [M3] Derived tag/organization index (plan D6). Subscribes to `meetingService.$meetings`, so
        // it is constructed right after the service; publishes low-cardinality tag counts the sidebar,
        // chips, and filters observe. `_shared` assigned below beside the view models.
        meetingOrganizationIndex = MeetingOrganizationIndex(meetingService: meetingService)
        // [M2-Participants] Isolated participant directory (plan D4/D5). Constructed right after the
        // meeting service and wired to its attendee choke points so every roster write folds into the
        // directory through the directory's single `ingest(_:)` writer. Startup backfill runs in
        // `initialize()`.
        let participantDirectoryService = ParticipantDirectoryService()
        self.participantDirectoryService = participantDirectoryService
        meetingService.onAttendeesIngested = { [weak participantDirectoryService] attendees in
            participantDirectoryService?.ingest(attendees)
        }
        // [M3-Participants] Prior-meeting matching union on resolved directory identity (plan D8) — the
        // headline win for the owner's largely email-less imported archive. Wired here so
        // `priorMeetings(matching:)` can resolve two rosters against the live directory; unwired in unit
        // tests, where the query falls back to the email-OR-series rule.
        meetingService.resolvePersonIDs = { [weak participantDirectoryService] attendees in
            participantDirectoryService?.resolvePersonIDs(for: attendees) ?? []
        }
        // [M4] (M3 review minor) Factory seam so `priorMeetings(matching:)` builds the directory
        // resolution index once per query and reuses it for the target + every candidate, instead of
        // rebuilding it per candidate (was O(meetings × persons) on the MainActor).
        meetingService.makePersonIDResolver = { [weak participantDirectoryService] in
            participantDirectoryService?.makePersonIDResolver() ?? { _ in [] }
        }
        // [M7] Per-folder context config store (Amendment 1, DA4). UserDefaults-backed; attaches to
        // M4's folder-mutator seams so a folder's config follows a rename and dies with the folder,
        // and feeds the organization index's union point so configured-but-empty folders appear in the
        // tree. Threaded into the brief + LLM services below to scope vault retrieval.
        let meetingFolderMetadataStore = MeetingFolderMetadataStore()
        self.meetingFolderMetadataStore = meetingFolderMetadataStore
        meetingService.onFolderPathRewrite = { [weak meetingFolderMetadataStore] old, new in
            meetingFolderMetadataStore?.handleFolderRewrite(from: old, to: new)
        }
        meetingService.onFolderDeleted = { [weak meetingFolderMetadataStore] path in
            meetingFolderMetadataStore?.handleFolderDeleted(path)
        }
        meetingOrganizationIndex.configuredFolderPathsProvider = { [weak meetingFolderMetadataStore] in
            meetingFolderMetadataStore?.configuredFolderPaths() ?? []
        }
        // [Track J] Central background-job queue (plan J1). Depends on nothing; constructed early so
        // the view model can enqueue through it and leaf views can `@ObservedObject` the singleton.
        meetingJobQueue = JobQueueService(clock: SystemJobClock())
        // [Track C] Capture-context rules constructed after `meetingService` (addendum AD7); the
        // matcher feeds `meetingCaptureService.start()` and the rules UI in the view model.
        let meetingContextRuleService = MeetingContextRuleService()
        self.meetingContextRuleService = meetingContextRuleService
        meetingCaptureService = MeetingCaptureService(
            meetingService: meetingService,
            audioRecorderService: audioRecorderService,
            modelManager: modelManagerService,
            jobQueue: meetingJobQueue,
            eventEmitter: meetingEventEmitter,
            ruleMatcher: meetingContextRuleService
        )
        meetingStartNotificationService = MeetingStartNotificationService()
        meetingEndReminderService = MeetingEndReminderService()
        // Obsidian vault knowledge base (plan M5), constructed before the LLM service because M6's
        // in-meeting Q&A retrieves KB passages through it.
        obsidianVaultService = ObsidianVaultService()
        // [M4] Per-purpose model router (plan D9): resolves `template > purpose > app default` per call
        // over the shared `.standard` defaults the Models settings section writes. One shared instance
        // is threaded into every meeting LLM service and read by the settings view for the live
        // effective-value display, so the ladder and its provenance stay single-sourced.
        let meetingModelRouter = MeetingModelRouter(processor: promptProcessingService)
        self.meetingModelRouter = meetingModelRouter
        // Constructed after `promptProcessingService` (its single-turn `process` seam),
        // `meetingService`, and `obsidianVaultService` (KB passages for Q&A — plan M4/M6).
        meetingLLMService = MeetingLLMService(
            meetingService: meetingService,
            vaultService: obsidianVaultService,
            processor: promptProcessingService,
            // [M7] Q&A honors the same per-folder vault scope as the brief (Amendment 1, DA6).
            folderMetadataStore: meetingFolderMetadataStore,
            modelRouter: meetingModelRouter // [M4]
        )
        // [M2] Per-meeting language detection (plan D5). Runs a single-turn LLM call over a transcript
        // sample and persists a `.detected` language; enqueues on the shared job queue's cap-1 `llm`
        // lane. Depends on `meetingService`, the `promptProcessingService` single-turn seam, and the
        // job queue. Provider/model are resolved per call from UserDefaults ("Use prompt provider" by
        // default), so nothing is snapshotted here.
        meetingLanguageService = MeetingLanguageService(
            meetingService: meetingService,
            processor: promptProcessingService,
            jobQueue: meetingJobQueue,
            modelRouter: meetingModelRouter // [M4] languageDetection purpose (reuses detection keys)
        )
        // Auto-detect at the capture transcript-ready choke point (plan D5): once a final pass completes
        // and the meeting is unset, enqueue a background detection. Wired as a closure so the capture
        // service (constructed earlier) needs no hard dependency on the language service.
        meetingCaptureService.onTranscriptReady = { [weak meetingLanguageService] meeting in
            meetingLanguageService?.enqueueAutoDetection(for: meeting)
        }
        // Pre-meeting brief (plan M5). The brief service depends on `meetingService` (prior
        // meetings), `obsidianVaultService` (KB passages), and the `promptProcessingService`
        // single-turn seam.
        meetingBriefService = MeetingBriefService(
            meetingService: meetingService,
            vaultService: obsidianVaultService,
            processor: promptProcessingService,
            // Plan M6 (amendment DA2): the brief prompt is the editable `.brief` template resolved
            // from the unified prompt store.
            promptActionService: promptActionService,
            // [M7] The meeting's folder config scopes brief knowledge-base retrieval (Amendment 1, DA5).
            folderMetadataStore: meetingFolderMetadataStore,
            modelRouter: meetingModelRouter // [M4] briefs purpose
        )
        // [M8] Agentic related-document discovery (Amendment 2). Searches the vault folder-first then
        // wider (LLM-judge junk-filtered) to curate per-meeting related notes; writes only through
        // `meetingService`'s single-writer setters. Reuses the same vault enumerator + folder config as
        // the brief, and the `promptProcessingService` single-turn judge seam.
        meetingRelatedDocsService = MeetingRelatedDocsService(
            meetingService: meetingService,
            vaultService: obsidianVaultService,
            folderMetadataStore: meetingFolderMetadataStore,
            processor: promptProcessingService,
            modelRouter: meetingModelRouter // [M4] relatedDocsJudge purpose
        )
        // Obsidian meeting export (plan M7): first-party core exporter that reuses the vault path
        // from `obsidianVaultService` (no second vault picker).
        // Reads the meetings root folder (plan D7/M4) from the shared defaults so exports nest under
        // `<vault>/<root>/<folderPath>`.
        meetingObsidianExporter = MeetingObsidianExporter(vaultService: obsidianVaultService)
        // Import / merge (plan M8): new meetings from audio or transcript files, and merging an
        // imported transcript into an existing captured meeting. Reuses `audioFileService` +
        // `modelManagerService.transcribe` for audio and `TranscriptFileParser` for transcripts.
        meetingImportService = MeetingImportService(
            meetingService: meetingService,
            audioFileService: audioFileService,
            transcriber: modelManagerService
        )
        // Opt-in post-finalize speaker diarization (plan M9): labels a completed meeting's segments
        // via the local pyannote sidecar (or an offline separate-track heuristic) and persists a
        // SPEAKER_xx → attendee-name map. Depends only on `meetingService`.
        // [M9-SPK-B / D-A6] The `transcriber` seam drives the keep-live timing re-pass: when Identify
        // runs on a coarse-timed keep-live meeting, a timing-only reference transcription (via
        // `ModelManagerService`) refines per-segment timings before diarization. Wiring it here enables
        // the re-pass in production; unit tests stub it or pass `nil` to disable it.
        meetingDiarizationEnricher = MeetingDiarizationEnricher(
            meetingService: meetingService,
            transcriber: modelManagerService
        )
        // [Speaker-recognition amendment, M9-SPK-A] Automatic post-stop speaker labeling (D-A2/D-A4):
        // at the end of finalization, adopt provider labels when present, else label a two-person call
        // by audio channel — zero user action for the common 1:1 call. Wired as a closure so the
        // capture service (constructed earlier) needs no hard dependency on the enricher.
        meetingCaptureService.onFinalizeSpeakerLabeling = { [weak meetingDiarizationEnricher] meeting in
            let prefer = UserDefaults.standard.object(
                forKey: UserDefaultsKeys.meetingsPreferProviderSpeakerLabels
            ) as? Bool ?? true
            await meetingDiarizationEnricher?.autoAssignSpeakers(for: meeting, preferProviderLabels: prefer)
        }

        // [Track D] Automatic pre-meeting briefs (plan AD9). Hooked into the calendar poll via the
        // meetings view model; pre-creates backing meetings and generates briefs for events entering
        // the lead window, deduped/freshness-gated and concurrency-capped, failing silently.
        meetingBriefScheduler = MeetingBriefScheduler(
            store: meetingService,
            briefService: meetingBriefService,
            jobQueue: meetingJobQueue,
            // [M8] Enqueue a gated related-docs discovery ahead of the auto-brief (Amendment 2, DB6) so
            // its brief is already scoped; only when a vault is connected.
            relatedDocsService: meetingRelatedDocsService,
            isVaultConnected: { [weak obsidianVaultService] in obsidianVaultService?.isConnected ?? false }
        )
        // Let the start-notification body mention a ready brief (plan AD9) without depending on the
        // scheduler at construction time (it is created after the notification service).
        meetingStartNotificationService.freshBriefLookup = { [weak meetingBriefScheduler] eventID, now in
            meetingBriefScheduler?.hasFreshBrief(forCalendarEventID: eventID, now: now) ?? false
        }

        // ViewModels (created before HTTP API so DictationViewModel is available)
        fileTranscriptionViewModel = FileTranscriptionViewModel(
            modelManager: modelManagerService,
            audioFileService: audioFileService,
            dictionaryService: dictionaryService
        )
        let recoveryViewModel = DictationRecoveryViewModel(
            audioRecordingService: audioRecordingService,
            modelManager: modelManagerService,
            historyService: historyService,
            audioFileService: audioFileService,
            licenseService: licenseService
        )
        dictationRecoveryViewModel = recoveryViewModel
        settingsViewModel = SettingsViewModel(modelManager: modelManagerService)
        dictationViewModel = DictationViewModel(
            audioRecordingService: audioRecordingService,
            textInsertionService: textInsertionService,
            hotkeyService: hotkeyService,
            modelManager: modelManagerService,
            settingsViewModel: settingsViewModel,
            historyService: historyService,
            recentTranscriptionStore: recentTranscriptionStore,
            profileService: profileService,
            workflowService: workflowService,
            translationService: translationService,
            audioDuckingService: audioDuckingService,
            dictionaryService: dictionaryService,
            licenseService: licenseService,
            targetAppCorrectionLearningService: targetAppCorrectionLearningService,
            snippetService: snippetService,
            soundService: soundService,
            audioDeviceService: audioDeviceService,
            promptActionService: promptActionService,
            promptProcessingService: promptProcessingService,
            appFormatterService: appFormatterService,
            punctuationStrategyResolver: punctuationStrategyResolver,
            speechPunctuationService: SpeechPunctuationService(rulesLoader: punctuationRulesLoader),
            speechFeedbackService: speechFeedbackService,
            accessibilityAnnouncementService: accessibilityAnnouncementService,
            errorLogService: errorLogService,
            mediaPlaybackService: mediaPlaybackService,
            recoveryFallbackConfigurationProvider: { [recoveryViewModel] primaryEngineId, task in
                recoveryViewModel.automaticFallbackConfiguration(
                    excluding: primaryEngineId,
                    task: task
                )
            }
        )
        audioRecorderViewModel = AudioRecorderViewModel(
            recorderService: audioRecorderService,
            modelManager: modelManagerService,
            dictionaryService: dictionaryService,
            audioDeviceService: audioDeviceService
        )


        // HTTP API
        let apiAuthenticator = LocalAPIAuthenticator()
        let router = APIRouter(apiTokenProvider: apiAuthenticator.tokenForEnforcedRequests)
        let handlers = APIHandlers(
            modelManager: modelManagerService,
            audioFileService: audioFileService,
            translationService: translationService,
            historyService: historyService,
            workflowService: workflowService,
            dictionaryService: dictionaryService,
            dictationViewModel: dictationViewModel,
            audioRecorderViewModel: audioRecorderViewModel,
            meetingService: meetingService,
            meetingImportService: meetingImportService,
            calendarService: calendarService
        )
        handlers.register(on: router)
        httpServer = HTTPServer(router: router)
        apiServerViewModel = APIServerViewModel(httpServer: httpServer, apiAuthenticator: apiAuthenticator)
        historyViewModel = HistoryViewModel(
            historyService: historyService,
            textDiffService: textDiffService,
            dictionaryService: dictionaryService
        )
        profilesViewModel = ProfilesViewModel(
            profileService: profileService,
            historyService: historyService,
            settingsViewModel: settingsViewModel,
            textInsertionService: textInsertionService
        )
        dictionaryViewModel = DictionaryViewModel(
            dictionaryService: dictionaryService,
            licenseService: licenseService,
            termPackRegistryService: termPackRegistryService
        )
        snippetsViewModel = SnippetsViewModel(snippetService: snippetService)
        homeViewModel = HomeViewModel(historyService: historyService)
        promptActionsViewModel = PromptActionsViewModel(
            promptActionService: promptActionService,
            promptProcessingService: promptProcessingService,
            profileService: profileService
        )
        watchFolderViewModel = WatchFolderViewModel(
            watchFolderService: watchFolderService,
            modelManager: modelManagerService
        )
        meetingsViewModel = MeetingsViewModel(
            meetingService: meetingService,
            promptActionService: promptActionService, // [Track B]
            calendarService: calendarService,
            captureService: meetingCaptureService,
            startNotificationService: meetingStartNotificationService,
            endReminderService: meetingEndReminderService,
            llmService: meetingLLMService,
            languageService: meetingLanguageService, // [M2]
            vaultService: obsidianVaultService,
            briefService: meetingBriefService,
            relatedDocsService: meetingRelatedDocsService, // [M8]
            folderMetadataStore: meetingFolderMetadataStore, // [M7]
            exporter: meetingObsidianExporter,
            importService: meetingImportService,
            diarizationEnricher: meetingDiarizationEnricher,
            // [Track C]
            contextRuleService: meetingContextRuleService,
            briefScheduler: meetingBriefScheduler, // [Track D]
            jobQueue: meetingJobQueue, // [Track J]
            participantDirectoryService: participantDirectoryService // [M3-Participants]
        )
        homeFeedViewModel = HomeFeedViewModel() // [Track C]
        // [Track E] Space vault browser (ME-1): caches one `listEntries()` snapshot from the shared
        // vault reader and rebuilds the tree in memory; no second scanner, no second vault picker.
        spaceViewModel = SpaceViewModel(vaultService: obsidianVaultService)

        // Set shared references
        FileTranscriptionViewModel._shared = fileTranscriptionViewModel
        DictationRecoveryViewModel._shared = dictationRecoveryViewModel
        SettingsViewModel._shared = settingsViewModel
        DictationViewModel._shared = dictationViewModel
        APIServerViewModel._shared = apiServerViewModel
        HistoryViewModel._shared = historyViewModel
        ProfilesViewModel._shared = profilesViewModel
        DictionaryViewModel._shared = dictionaryViewModel
        SnippetsViewModel._shared = snippetsViewModel
        HomeViewModel._shared = homeViewModel
        PromptActionsViewModel._shared = promptActionsViewModel
        AudioRecorderViewModel._shared = audioRecorderViewModel
        WatchFolderViewModel._shared = watchFolderViewModel
        MeetingsViewModel._shared = meetingsViewModel
        HomeFeedViewModel._shared = homeFeedViewModel // [Track C]
        SpaceViewModel._shared = spaceViewModel // [Track E]
        JobQueueService._shared = meetingJobQueue // [Track J]
        MeetingOrganizationIndex._shared = meetingOrganizationIndex // [M3]
        MeetingFolderMetadataStore._shared = meetingFolderMetadataStore // [M7]
        MeetingRelatedDocsService._shared = meetingRelatedDocsService // [M8]

        // License
        LicenseService.shared = licenseService

        // Plugin system
        EventBus.shared = EventBus()
        // [Track A] Expose the already-constructed meeting-event bus for `PluginManager` to hand to
        // each plugin's `HostServicesImpl` (addendum AD4).
        MeetingEventBus.shared = meetingEventBus
        PluginManager.shared = pluginManager
        PluginRegistryService.shared = pluginRegistryService
        TermPackRegistryService.shared = termPackRegistryService

        modelManagerService.observePluginManager()
        promptProcessingService.observePluginManager()
        fileTranscriptionViewModel.observePluginManager()
        dictationRecoveryViewModel.observePluginManager()
        settingsViewModel.observePluginManager()
        audioRecorderViewModel.observePluginManager()
        watchFolderViewModel.observePluginManager()
    }

    func initialize() async {
        guard !AppConstants.isRunningTests else { return }

        // Crash recovery: mark any meeting left `.live` by a crash/force-quit as `.interrupted`
        // while keeping its persisted transcript segments visible (plan D2).
        meetingService.recoverInterruptedMeetings()

        // [M2-Participants] One-time, idempotent backfill of the participant directory over every
        // existing meeting's roster (plan D7). Runs inline for a normally-sized archive; a large archive
        // (e.g. a bulk email import) is offloaded to the `io` lane so launch never blocks. Re-running is
        // a no-op because `ingest` is idempotent.
        let existingMeetings = meetingService.meetings
        if existingMeetings.count > ParticipantDirectoryService.largeArchiveThreshold {
            meetingJobQueue.enqueue(
                kind: .participantBackfill,
                meetingID: nil,
                priority: .background
            ) { [weak participantDirectoryService, weak meetingService] in
                await participantDirectoryService?.backfill(from: meetingService?.meetings ?? [])
            }
        } else {
            await participantDirectoryService.backfill(from: existingMeetings)
        }

        // [Track B] Migrate legacy `MeetingTemplate` rows into unified `.meeting` PromptAction rows
        // and seed the curated presets (plan AD6). One-time + idempotent; preserves template UUIDs.
        promptActionService.migrateMeetingTemplatesIfNeeded(
            legacyTemplates: meetingService.legacyMeetingTemplateSnapshots()
        )

        hotkeyService.setup()
        dictationViewModel.registerInitialTriggerHotkeys()
        let retentionDays = UserDefaults.standard.integer(forKey: UserDefaultsKeys.historyRetentionDays)
        if retentionDays > 0 { historyService.purgeOldRecords(retentionDays: retentionDays) }

        if apiServerViewModel.isEnabled {
            apiServerViewModel.startServer()
        }

        pluginManager.setRuleNamesProvider { [weak self] in
            self?.workflowService.availableRuleNames ?? []
        }
        pluginManager.setWorkflowProvider { [weak self] in
            self?.workflowService.workflows.map(\.pluginWorkflowInfo) ?? []
        }
        pluginManager.scanAndLoadPlugins()

        // Re-restore provider selection now that plugins are loaded
        modelManagerService.restoreProviderSelection()
        audioRecorderViewModel.reconcileSelectionWithAvailablePlugins()
        watchFolderViewModel.reconcileSelectionWithAvailablePlugins()

        // Validate LLM provider selection against loaded plugins
        promptProcessingService.validateSelectionAfterPluginLoad()

        pluginRegistryService.checkForUpdatesInBackground()

        // Start memory service
        memoryService.startListening()

        // Auto-start watch folder if configured
        if UserDefaults.standard.bool(forKey: UserDefaultsKeys.watchFolderAutoStart),
           let bookmark = UserDefaults.standard.data(forKey: UserDefaultsKeys.watchFolderBookmark) {
            var isStale = false
            if let url = try? URL(resolvingBookmarkData: bookmark, options: .withSecurityScope, bookmarkDataIsStale: &isStale) {
                watchFolderService.startWatching(folderURL: url)
            }
        }

    }
}
