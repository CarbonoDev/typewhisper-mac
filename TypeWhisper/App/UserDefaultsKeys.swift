import Foundation

/// Central registry for all UserDefaults keys used throughout the app.
/// Prevents typo-induced bugs and makes keys discoverable via autocomplete.
enum UserDefaultsKeys {
    // MARK: - Dictation
    static let audioDuckingEnabled = "audioDuckingEnabled"
    static let audioDuckingLevel = "audioDuckingLevel"
    static let soundFeedbackEnabled = "soundFeedbackEnabled"
    static let soundRecordingStarted = "soundRecordingStarted"
    static let soundTranscriptionSuccess = "soundTranscriptionSuccess"
    static let soundError = "soundError"
    static let indicatorStyle = "indicatorStyle"
    static let indicatorTranscriptPreviewEnabled = "indicatorTranscriptPreviewEnabled"
    static let indicatorTranscriptPreviewFontSizeOffset = "indicatorTranscriptPreviewFontSizeOffset"
    static let preserveClipboard = "preserveClipboard"
    static let mediaPauseEnabled = "mediaPauseEnabled"
    static let dictationHotkeysPaused = "dictationHotkeysPaused"
    static let transcribeShortQuietClipsAggressively = "transcribeShortQuietClipsAggressively"
    static let microphoneBoostEnabled = "microphoneBoostEnabled"

    // MARK: - Hotkey (JSON-encoded UnifiedHotkey per slot, legacy mirror for first binding)
    static let hybridHotkey = "hybridHotkey"
    static let pttHotkey = "pttHotkey"
    static let toggleHotkey = "toggleHotkey"
    static let promptPaletteHotkey = "promptPaletteHotkey"
    static let recentTranscriptionsHotkey = "recentTranscriptionsHotkey"
    static let copyLastTranscriptionHotkey = "copyLastTranscriptionHotkey"
    static let recorderToggleHotkey = "recorderToggleHotkey"

    // MARK: - Hotkeys (JSON-encoded [UnifiedHotkey] per slot)
    static let hybridHotkeys = "hybridHotkeys"
    static let pttHotkeys = "pttHotkeys"
    static let toggleHotkeys = "toggleHotkeys"
    static let promptPaletteHotkeys = "promptPaletteHotkeys"
    static let recentTranscriptionsHotkeys = "recentTranscriptionsHotkeys"
    static let copyLastTranscriptionHotkeys = "copyLastTranscriptionHotkeys"
    static let recorderToggleHotkeys = "recorderToggleHotkeys"

    // MARK: - Model / Engine
    static let selectedEngine = "selectedEngine"
    static let selectedModelId = "selectedModelId"
    static let loadedModelIds = "loadedModelIds"
    static let modelAutoUnloadSeconds = "modelAutoUnloadSeconds"

    // MARK: - Settings
    static let selectedLanguage = "selectedLanguage"
    static let selectedTask = "selectedTask"
    static let translationEnabled = "translationEnabled"
    static let translationTargetLanguage = "translationTargetLanguage"
    static let preferredAppLanguage = "preferredAppLanguage"

    // MARK: - API Server
    static let apiServerEnabled = "apiServerEnabled"
    static let apiServerPort = "apiServerPort"
    static let apiServerRequiresAuthentication = "apiServerRequiresAuthentication"
    static let updateChannel = "updateChannel"

    // MARK: - Audio Device
    static let selectedInputDeviceUID = "selectedInputDeviceUID"
    static let inputDevicePriorityList = "inputDevicePriorityList"

    // MARK: - Home / Setup
    static let setupWizardCompleted = "setupWizardCompleted"
    static let setupWizardCurrentStep = "setupWizardCurrentStep"

    // MARK: - Dictionary
    static let activatedTermPacks = "activatedTermPacks" // Legacy - kept for migration cleanup
    static let activatedTermPackStates = "activatedTermPackStates"
    static let termPackRegistryLastUpdateCheck = "termPackRegistryLastUpdateCheck"
    static let selectedIndustryPreset = "selectedIndustryPreset"
    static let targetAppCorrectionLearningEnabled = "targetAppCorrectionLearningEnabled"

    // MARK: - History
    static let historyEnabled = "historyEnabled"
    static let historyRetentionDays = "historyRetentionDays"
    static let saveAudioWithHistory = "saveAudioWithHistory"

    // MARK: - Notch Indicator
    static let overlayPosition = "overlayPosition"
    static let notchIndicatorVisibility = "notchIndicatorVisibility"
    static let notchIndicatorLeftContent = "notchIndicatorLeftContent"
    static let notchIndicatorRightContent = "notchIndicatorRightContent"
    static let notchIndicatorDisplay = "notchIndicatorDisplay"

    // MARK: - Appearance
    static let showMenuBarIcon = "showMenuBarIcon"
    static let dockIconBehaviorWhenMenuBarHidden = "dockIconBehaviorWhenMenuBarHidden"
    static let menuBarIconHiddenAlertShown = "menuBarIconHiddenAlertShown"

    // MARK: - Main window (meetings-first UI, UI Step 0 · D2/D10)
    /// Whether the meetings-first main window opens automatically at launch (registered default ON).
    /// Launch precedence: first-run setup > post-update license prompt > this toggle (D2).
    static let showMainWindowAtLaunch = "mainwindow.showAtLaunch"

    // MARK: - Memory
    static let memoryEnabled = "memoryEnabled"
    static let memoryExtractionProvider = "memoryExtractionProvider"
    static let memoryExtractionModel = "memoryExtractionModel"
    static let memoryMinTextLength = "memoryMinTextLength"
    static let memoryExtractionPrompt = "memoryExtractionPrompt"
    static let memoryCaptureScope = "memoryCaptureScope"

    // MARK: - Formatting
    static let appFormattingEnabled = "appFormattingEnabled"
    static let transcriptionNumberNormalizationEnabled = "transcriptionNumberNormalizationEnabled"
    static let dictationPunctuationProfiles = "dictationPunctuationProfiles"

    // MARK: - Accessibility
    static let spokenFeedbackEnabled = "spokenFeedbackEnabled"
    static let spokenFeedbackProviderId = "spokenFeedbackProviderId"

    // MARK: - Plugin Registry
    static let pluginRegistryLastFetch = "pluginRegistryLastFetch"
    static let selectedIntegrationTab = "selectedIntegrationTab"

    // MARK: - Recorder
    static let recorderMicEnabled = "recorderMicEnabled"
    static let recorderSystemAudioEnabled = "recorderSystemAudioEnabled"
    static let recorderOutputFormat = "recorderOutputFormat"
    static let recorderTranscriptionEnabled = "recorderTranscriptionEnabled"
    static let recorderLivePreviewEnabled = "recorderLivePreviewEnabled"
    static let recorderTranscriptionEngine = "recorderTranscriptionEngine"
    static let recorderTranscriptionModel = "recorderTranscriptionModel"
    static let recorderMicDuckingMode = "recorderMicDuckingMode"
    static let recorderTrackMode = "recorderTrackMode"

    // MARK: - File Transcription
    static let fileTranscriptionEngine = "fileTranscriptionEngine"
    static let fileTranscriptionModel = "fileTranscriptionModel"
    static let fileTranscriptionLanguage = "fileTranscriptionLanguage"

    // MARK: - Dictation Recovery
    static let dictationRecoveryEngine = "dictationRecoveryEngine"
    static let dictationRecoveryModel = "dictationRecoveryModel"
    static let dictationRecoveryLanguage = "dictationRecoveryLanguage"
    static let dictationRecoveryAutomaticFallbackEnabled = "dictationRecoveryAutomaticFallbackEnabled"

    // MARK: - Watch Folder
    static let watchFolderBookmark = "watchFolderBookmark"
    static let watchFolderOutputBookmark = "watchFolderOutputBookmark"
    static let watchFolderOutputFormat = "watchFolderOutputFormat"
    static let watchFolderDeleteSource = "watchFolderDeleteSource"
    static let watchFolderAutoStart = "watchFolderAutoStart"
    static let watchFolderLanguage = "watchFolderLanguage"
    static let watchFolderEngine = "watchFolderEngine"
    static let watchFolderModel = "watchFolderModel"

    // MARK: - Workflows
    static let workflowDefaultLLMProviderId = "workflowDefaultLLMProviderId"
    static let workflowDefaultLLMCloudModel = "workflowDefaultLLMCloudModel"
    static let workflowShortTranscriptionMinimumWords = "workflowShortTranscriptionMinimumWords"

    // MARK: - Post-update release tracking
    // TypeWhisper is free and open source (GPLv3); the licensing/supporter keys
    // have been removed. `usageIntent` and `welcomeSheetShown` are retained only
    // because a couple of tests still reference them.
    static let usageIntent = "usageIntent"
    static let welcomeSheetShown = "welcomeSheetShown"
    static let lastSeenReleaseFingerprint = "lastSeenReleaseFingerprint"
    static let lastAcknowledgedPostUpdatePromptRelease = "lastAcknowledgedPostUpdatePromptRelease"

    // MARK: - Meetings
    /// Absolute path of the Obsidian vault connected as a knowledge base (plan M5, D9).
    static let meetingsObsidianVaultPath = "meetings.obsidianVaultPath"
    /// Vault-relative root folder that all meeting exports are nested under (plan D7/M4). Registered
    /// default `"Meetings"`; an empty value collapses to exporting at the vault root (the escape
    /// hatch). The exporter prepends its sanitized components before the per-meeting `folderPath`.
    static let meetingsObsidianRootFolder = "meetings.obsidianRootFolder"
    /// JSON-encoded `[folderPath: FolderContextConfig]` map (Amendment 1, DA4): per-folder description,
    /// attached vault notes/folders, and the "No vault context" toggle that scope brief/Q&A retrieval.
    /// Absent/empty ⇒ no folder has context configured (every meeting retrieves whole-vault).
    static let meetingsFolderContextConfigs = "meetings.folderContextConfigs"
    /// Opt-in bridge (addendum AD5, default OFF): when true, finishing a meeting also emits a
    /// legacy `.transcriptionCompleted` on the classic dictation `EventBus` so dictation-keyed
    /// integrations (Obsidian auto-export, `transcriptionCompleted` webhooks) fire for meetings.
    static let meetingsBridgeToDictationEvents = "meetings.bridgeToDictationEvents"
    /// [M11] Identifiers (`EKCalendar.calendarIdentifier`) of calendars the user has DEselected in
    /// Settings › Meetings › Calendars. Deselected (not selected) ids are stored so that calendars
    /// added later default to selected: an id absent from this set — including a brand-new one — is
    /// shown. Empty/absent ⇒ all calendars selected.
    static let meetingsCalendarDeselectedIDs = "meetings.calendar.deselectedIDs"
    // MARK: - Meetings · Final re-transcription (addendum AD8, Track C)
    /// Global default final re-transcription mode: "off" | "sameEngine" | "engine".
    static let meetingsFinalPassDefaultMode = "meetings.finalPass.defaultMode"
    /// Override engine (plugin provider id) when the global mode is "engine".
    static let meetingsFinalPassEngineId = "meetings.finalPass.engineId"
    /// Override cloud model id when the global mode is "engine".
    static let meetingsFinalPassModel = "meetings.finalPass.model"

    // MARK: - Meetings · Language detection (plan D5, M2)
    /// LLM provider id used for per-meeting language detection. Empty/unset ⇒ inherit the current
    /// prompt-provider selection (the "Use prompt provider" default). Reused verbatim by
    /// `MeetingModelPurpose.languageDetection` (plan D9/M4 — detection is configured in one place).
    static let meetingsLanguageDetectionProviderId = "meetings.language.detectionProviderId"
    /// Cloud model id for language detection when a specific detection provider is chosen. Empty/unset
    /// ⇒ the provider default.
    static let meetingsLanguageDetectionModel = "meetings.language.detectionModel"

    // MARK: - Meetings · Per-purpose model routing (plan D9, M4)
    // Precedence `template > purpose > app default`, resolved per call by `MeetingModelRouter`. Empty/
    // unset ⇒ "Use app default" (inherit the prompt-provider selection). `languageDetection` reuses the
    // legacy `meetings.language.detection*` keys above rather than adding new ones (back-compat).
    /// Provider override for summaries / analysis outputs (`MeetingModelPurpose.summariesAnalysis`).
    static let meetingsModelSummariesProviderId = "meetings.models.summaries.providerId"
    /// Model override for summaries / analysis outputs.
    static let meetingsModelSummariesModel = "meetings.models.summaries.model"
    /// Provider override for pre-meeting briefs (`MeetingModelPurpose.briefs`).
    static let meetingsModelBriefsProviderId = "meetings.models.briefs.providerId"
    /// Model override for pre-meeting briefs.
    static let meetingsModelBriefsModel = "meetings.models.briefs.model"
    /// Provider override for in-meeting Q&A (`MeetingModelPurpose.qa`).
    static let meetingsModelQAProviderId = "meetings.models.qa.providerId"
    /// Model override for in-meeting Q&A.
    static let meetingsModelQAModel = "meetings.models.qa.model"
    /// Provider override for the related-documents relevance judge (`MeetingModelPurpose.relatedDocsJudge`).
    static let meetingsModelRelatedDocsProviderId = "meetings.models.relatedDocs.providerId"
    /// Model override for the related-documents relevance judge.
    static let meetingsModelRelatedDocsModel = "meetings.models.relatedDocs.model"

    // [Track D] Automatic pre-meeting briefs (plan AD9).
    /// Whether pre-meeting briefs are generated automatically (default ON).
    static let meetingsAutoBriefEnabled = "meetings.brief.auto.enabled"
    /// How many minutes before a meeting's start the brief is generated (default 20, range 5–60).
    static let meetingsAutoBriefLeadMinutes = "meetings.brief.auto.leadMinutes"
    /// How recent an existing brief must be to skip regeneration (default 6 hours).
    static let meetingsAutoBriefFreshnessHours = "meetings.brief.auto.freshnessHours"
    /// Minimum attendee count for an event to auto-generate a brief (default 1).
    static let meetingsAutoBriefMinAttendees = "meetings.brief.auto.minAttendees"

    // MARK: - Meetings · Speaker labels (speaker-recognition amendment, M9-SPK-A)
    /// Whether provider (cloud) speaker labels are adopted when a speaker-capable engine returns them,
    /// taking precedence over local diarization (D-A2/D-A7). Registered default ON.
    static let meetingsPreferProviderSpeakerLabels = "meetings.speakers.preferProviderLabels"
}
