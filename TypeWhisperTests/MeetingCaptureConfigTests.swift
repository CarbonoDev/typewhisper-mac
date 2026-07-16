import XCTest
@testable import TypeWhisper

/// [Track C] MeetingCaptureService integration of capture-context rules (AD7) and configurable
/// final re-transcription (AD8). CI never touches a real audio engine — the recorder is driven
/// through overrides and the empty test `PluginManager` makes transcription fail (keep-live path).
@MainActor
final class MeetingCaptureConfigTests: XCTestCase {
    private var previousPluginManager: PluginManager?
    /// [Track J] The final pass runs on this queue; tests settle it with `drain()` after `stop()`.
    private let captureJobQueue = JobQueueService()

    override func setUp() {
        super.setUp()
        previousPluginManager = PluginManager.shared
        PluginManager.shared = PluginManager()
    }

    override func tearDown() {
        PluginManager.shared = previousPluginManager
        previousPluginManager = nil
        super.tearDown()
    }

    // MARK: - Fakes

    /// Returns a fixed match (or nil) for any context.
    private final class FakeRuleMatcher: MeetingContextRuleMatching {
        var result: MeetingRuleMatchResult?
        init(result: MeetingRuleMatchResult?) { self.result = result }
        func match(_ context: MeetingContext) -> MeetingRuleMatchResult? { result }
    }

    /// Evaluates a real `MeetingRuleTrigger` against the context the capture service builds, so a
    /// test can prove the calendar name actually reaches matching at capture time.
    private final class TriggerMatcher: MeetingContextRuleMatching {
        let trigger: MeetingRuleTrigger
        let actions: MeetingRuleActions
        init(trigger: MeetingRuleTrigger, actions: MeetingRuleActions) {
            self.trigger = trigger
            self.actions = actions
        }
        func match(_ context: MeetingContext) -> MeetingRuleMatchResult? {
            guard trigger.matches(context) else { return nil }
            return MeetingRuleMatchResult(
                ruleID: UUID(), ruleName: "R", specificity: trigger.specificity, actions: actions
            )
        }
    }

    private func makeRecorder(recordingsDirectory: URL, sampleCount: Int = 16_000) -> AudioRecorderService {
        let recorder = AudioRecorderService()
        recorder.recordingsDirectoryOverride = recordingsDirectory
        recorder.startRecordingOverride = { _, _, _, outputURL, _ in
            try FileManager.default.createDirectory(
                at: outputURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data("placeholder".utf8).write(to: outputURL)
            return outputURL
        }
        recorder.stopRecordingOverride = { outputURL in
            try Data("recorded".utf8).write(to: outputURL)
            return outputURL
        }
        recorder.currentBufferOverride = { Array(repeating: Float(0.2), count: sampleCount) }
        return recorder
    }

    private func makeCapture(
        meetingService: MeetingService,
        recorder: AudioRecorderService,
        defaults: UserDefaults,
        ruleMatcher: MeetingContextRuleMatching? = nil,
        engineAvailabilityCheck: ((String) -> Bool)? = nil,
        engineIsCloudCheck: ((String) -> Bool)? = nil
    ) -> MeetingCaptureService {
        MeetingCaptureService(
            meetingService: meetingService,
            audioRecorderService: recorder,
            modelManager: ModelManagerService(),
            jobQueue: captureJobQueue,
            defaults: defaults,
            flushIntervalSeconds: 0,
            ruleMatcher: ruleMatcher,
            engineAvailabilityCheck: engineAvailabilityCheck,
            engineIsCloudCheck: engineIsCloudCheck
        )
    }

    private func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "MeetingCaptureConfigTests-\(UUID().uuidString)")!
    }

    // MARK: - Rule default template surfaced

    func testMatchedRuleSurfacesDefaultTemplateID() async throws {
        let dir = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(dir) }
        let meetingService = MeetingService(appSupportDirectory: dir)
        let recorder = makeRecorder(recordingsDirectory: dir.appendingPathComponent("rec"))
        let templateID = UUID()
        let matcher = FakeRuleMatcher(result: MeetingRuleMatchResult(
            ruleID: UUID(), ruleName: "R", specificity: 4,
            actions: MeetingRuleActions(defaultOutputTemplateID: templateID)
        ))
        let capture = makeCapture(
            meetingService: meetingService, recorder: recorder,
            defaults: makeDefaults(), ruleMatcher: matcher
        )

        let meeting = meetingService.createMeeting(title: "Sync", source: .adHoc, state: .scheduled)
        try await capture.start(meeting: meeting)
        XCTAssertEqual(capture.activeMeetingDefaultTemplateID, templateID)
        await capture.stop()
        await capture.awaitFinalizeTeardownForTesting()
        await captureJobQueue.drain()
    }

    /// Finding 1: a `calendarNamePatterns` rule can only fire if the calendar name reaches matching
    /// at capture time. Starting a capture with `calendarName: "Work"` must satisfy a `["Work"]`
    /// trigger (surfacing its default template); starting without it must not.
    func testCalendarNameRuleMatchesCaptureStartedWithCalendarName() async throws {
        let dir = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(dir) }
        let meetingService = MeetingService(appSupportDirectory: dir)
        let templateID = UUID()
        let matcher = TriggerMatcher(
            trigger: MeetingRuleTrigger(calendarNamePatterns: ["Work"]),
            actions: MeetingRuleActions(defaultOutputTemplateID: templateID)
        )

        // With the calendar name threaded through, the calendar-name trigger fires.
        let recorder = makeRecorder(recordingsDirectory: dir.appendingPathComponent("rec"))
        let capture = makeCapture(
            meetingService: meetingService, recorder: recorder,
            defaults: makeDefaults(), ruleMatcher: matcher
        )
        let meeting = meetingService.createMeeting(title: "Sync", source: .calendar, state: .scheduled)
        try await capture.start(meeting: meeting, calendarName: "Work")
        XCTAssertEqual(capture.activeMeetingDefaultTemplateID, templateID)
        XCTAssertEqual(capture.defaultTemplateMeetingID, meeting.id)
        await capture.stop()
        await capture.awaitFinalizeTeardownForTesting()
        await captureJobQueue.drain()

        // Control: no calendar name → the calendar-name trigger cannot match.
        let recorder2 = makeRecorder(recordingsDirectory: dir.appendingPathComponent("rec2"))
        let capture2 = makeCapture(
            meetingService: meetingService, recorder: recorder2,
            defaults: makeDefaults(), ruleMatcher: matcher
        )
        let meeting2 = meetingService.createMeeting(title: "AdHoc", source: .adHoc, state: .scheduled)
        try await capture2.start(meeting: meeting2) // no calendarName
        XCTAssertNil(capture2.activeMeetingDefaultTemplateID)
        XCTAssertNil(capture2.defaultTemplateMeetingID)
        await capture2.stop()
        await capture2.awaitFinalizeTeardownForTesting()
        await captureJobQueue.drain()
    }

    // MARK: - Rule-selected default template pre-selection (finding 4)

    func testPreselectedTemplateResolvesRuleTemplateElseFirst() {
        let first = PromptAction(
            name: "Default", prompt: "a", sortOrder: 0,
            surfaceRaw: PromptSurface.meeting.rawValue,
            meetingKindRaw: MeetingOutputKind.summary.rawValue
        )
        let ruleTemplate = PromptAction(
            name: "Decision Log", prompt: "b", sortOrder: 1,
            surfaceRaw: PromptSurface.meeting.rawValue,
            meetingKindRaw: MeetingOutputKind.summary.rawValue
        )
        let templates = [first, ruleTemplate]

        // Rule id present → that template is pre-selected.
        XCTAssertEqual(
            MeetingsViewModel.preselectedTemplate(from: templates, ruleTemplateID: ruleTemplate.id)?.id,
            ruleTemplate.id
        )
        // Orphaned id (not in the set) → falls back to the first template.
        XCTAssertEqual(
            MeetingsViewModel.preselectedTemplate(from: templates, ruleTemplateID: UUID())?.id,
            first.id
        )
        // No rule id → first template.
        XCTAssertEqual(
            MeetingsViewModel.preselectedTemplate(from: templates, ruleTemplateID: nil)?.id,
            first.id
        )
        // Empty set → nil.
        XCTAssertNil(MeetingsViewModel.preselectedTemplate(from: [], ruleTemplateID: ruleTemplate.id))
    }

    // MARK: - Live engine override reaches startStreaming

    func testRuleLiveEngineOverrideFlipsDegradedLiveMode() async throws {
        let dir = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(dir) }

        // Deterministically clear the machine-global recorder engine selection so the baseline
        // (no override) is undegraded and the override is the *sole* cause of degradation. Restored
        // afterward so no other test is affected.
        let savedSelection = UserDefaults.standard.string(forKey: UserDefaultsKeys.selectedEngine)
        UserDefaults.standard.removeObject(forKey: UserDefaultsKeys.selectedEngine)
        defer {
            if let savedSelection {
                UserDefaults.standard.set(savedSelection, forKey: UserDefaultsKeys.selectedEngine)
            } else {
                UserDefaults.standard.removeObject(forKey: UserDefaultsKeys.selectedEngine)
            }
        }

        let meetingService = MeetingService(appSupportDirectory: dir)

        // Baseline: no rule → no engine selected → not degraded.
        let baselineRecorder = makeRecorder(recordingsDirectory: dir.appendingPathComponent("rec-base"))
        let baseline = makeCapture(
            meetingService: meetingService, recorder: baselineRecorder, defaults: makeDefaults()
        )
        let baseMeeting = meetingService.createMeeting(title: "Base", source: .adHoc, state: .scheduled)
        try await baseline.start(meeting: baseMeeting)
        XCTAssertFalse(baseline.isDegradedLiveMode)
        await baseline.stop()
        await baseline.awaitFinalizeTeardownForTesting()
        await captureJobQueue.drain()

        // With a rule live-engine override to a non-live-capable engine in the empty test host,
        // `startStreaming` marks the session degraded — proving the override reached it.
        let recorder = makeRecorder(recordingsDirectory: dir.appendingPathComponent("rec"))
        let matcher = FakeRuleMatcher(result: MeetingRuleMatchResult(
            ruleID: UUID(), ruleName: "R", specificity: 4,
            actions: MeetingRuleActions(liveEngineId: "assemblyai")
        ))
        let capture = makeCapture(
            meetingService: meetingService, recorder: recorder,
            defaults: makeDefaults(), ruleMatcher: matcher
        )
        let meeting = meetingService.createMeeting(title: "Sync", source: .adHoc, state: .scheduled)
        try await capture.start(meeting: meeting)
        XCTAssertTrue(capture.isDegradedLiveMode, "Rule live-engine override should reach startStreaming")
        await capture.stop()
        await capture.awaitFinalizeTeardownForTesting()
        await captureJobQueue.drain()
    }

    func testNoRuleLeavesLiveModeUndegraded() async throws {
        let dir = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(dir) }
        let meetingService = MeetingService(appSupportDirectory: dir)
        let recorder = makeRecorder(recordingsDirectory: dir.appendingPathComponent("rec"))
        let capture = makeCapture(
            meetingService: meetingService, recorder: recorder, defaults: makeDefaults()
        )

        let meeting = meetingService.createMeeting(title: "Sync", source: .adHoc, state: .scheduled)
        try await capture.start(meeting: meeting)
        // No matched rule → no rule-selected default template. (`isDegradedLiveMode` is not asserted
        // here: it depends on the machine-global recorder engine selection in `UserDefaults.standard`,
        // not the injected test defaults.)
        XCTAssertNil(capture.activeMeetingDefaultTemplateID)
        await capture.stop()
        await capture.awaitFinalizeTeardownForTesting()
        await captureJobQueue.drain()
    }

    // MARK: - Final re-transcription policy

    func testPerMeetingOffKeepsLiveSegmentsWithoutDegrading() async throws {
        let dir = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(dir) }
        let meetingService = MeetingService(appSupportDirectory: dir)
        let recorder = makeRecorder(recordingsDirectory: dir.appendingPathComponent("rec"))
        let capture = makeCapture(
            meetingService: meetingService, recorder: recorder, defaults: makeDefaults()
        )

        let meeting = meetingService.createMeeting(title: "Off", source: .adHoc, state: .scheduled)
        meeting.finalRetranscriptionPolicy = .off
        meetingService.update(meeting)

        try await capture.start(meeting: meeting)
        capture.ingestLiveTranscript("Live one.", elapsed: 1)
        capture.ingestLiveTranscript("Live one. Live two.", elapsed: 2)
        await capture.stop()
        await capture.awaitFinalizeTeardownForTesting()
        await captureJobQueue.drain()

        XCTAssertEqual(meeting.state, .completed)
        let texts = meeting.segments.sorted { $0.order < $1.order }.map(\.text)
        XCTAssertEqual(texts, ["Live one.", "Live two."])
        XCTAssertFalse(capture.finalRetranscriptionDegraded, ".off is not a degradation")
    }

    func testRuleOffPolicyKeepsLiveSegments() async throws {
        let dir = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(dir) }
        let meetingService = MeetingService(appSupportDirectory: dir)
        let recorder = makeRecorder(recordingsDirectory: dir.appendingPathComponent("rec"))
        let matcher = FakeRuleMatcher(result: MeetingRuleMatchResult(
            ruleID: UUID(), ruleName: "R", specificity: 4,
            actions: MeetingRuleActions(finalRetranscription: .off)
        ))
        let capture = makeCapture(
            meetingService: meetingService, recorder: recorder,
            defaults: makeDefaults(), ruleMatcher: matcher
        )

        let meeting = meetingService.createMeeting(title: "RuleOff", source: .adHoc, state: .scheduled)
        try await capture.start(meeting: meeting)
        capture.ingestLiveTranscript("Only live.", elapsed: 1)
        await capture.stop()
        await capture.awaitFinalizeTeardownForTesting()
        await captureJobQueue.drain()

        XCTAssertEqual(meeting.segments.map(\.text), ["Only live."])
        XCTAssertFalse(capture.finalRetranscriptionDegraded)
    }

    func testUnavailableOverrideEngineDegradesButKeepsContent() async throws {
        let dir = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(dir) }
        let meetingService = MeetingService(appSupportDirectory: dir)
        let recorder = makeRecorder(recordingsDirectory: dir.appendingPathComponent("rec"))
        let matcher = FakeRuleMatcher(result: MeetingRuleMatchResult(
            ruleID: UUID(), ruleName: "R", specificity: 4,
            actions: MeetingRuleActions(finalRetranscription: .engine(id: "assemblyai", model: "best"))
        ))
        let capture = makeCapture(
            meetingService: meetingService, recorder: recorder,
            defaults: makeDefaults(), ruleMatcher: matcher,
            engineAvailabilityCheck: { _ in false }, // engine unavailable at stop
            engineIsCloudCheck: { _ in true }
        )

        let meeting = meetingService.createMeeting(title: "Degrade", source: .adHoc, state: .scheduled)
        try await capture.start(meeting: meeting)
        capture.ingestLiveTranscript("Kept segment.", elapsed: 1)
        await capture.stop()
        await capture.awaitFinalizeTeardownForTesting()
        await captureJobQueue.drain()

        XCTAssertTrue(capture.finalRetranscriptionDegraded, "Unavailable override engine should degrade")
        // Content is never lost — the live segment survives.
        XCTAssertEqual(meeting.segments.map(\.text), ["Kept segment."])
        XCTAssertEqual(meeting.state, .completed)
    }

    func testOversizedCloudOverrideDegrades() async throws {
        let dir = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(dir) }
        let meetingService = MeetingService(appSupportDirectory: dir)
        // Buffer duration far beyond the cloud ceiling.
        let recorder = makeRecorder(recordingsDirectory: dir.appendingPathComponent("rec"), sampleCount: 16_000)
        let matcher = FakeRuleMatcher(result: MeetingRuleMatchResult(
            ruleID: UUID(), ruleName: "R", specificity: 4,
            actions: MeetingRuleActions(finalRetranscription: .engine(id: "assemblyai", model: nil))
        ))
        let capture = MeetingCaptureService(
            meetingService: meetingService,
            audioRecorderService: recorder,
            modelManager: ModelManagerService(),
            jobQueue: captureJobQueue,
            defaults: makeDefaults(),
            flushIntervalSeconds: 0,
            ruleMatcher: matcher,
            cloudCeilingSeconds: 0.1, // tiny ceiling so 1 s of audio exceeds it
            engineAvailabilityCheck: { _ in true },
            engineIsCloudCheck: { _ in true }
        )

        let meeting = meetingService.createMeeting(title: "Oversize", source: .adHoc, state: .scheduled)
        try await capture.start(meeting: meeting)
        capture.ingestLiveTranscript("Kept.", elapsed: 1)
        await capture.stop()
        await capture.awaitFinalizeTeardownForTesting()
        await captureJobQueue.drain()

        XCTAssertTrue(capture.finalRetranscriptionDegraded)
        XCTAssertEqual(meeting.segments.map(\.text), ["Kept."])
    }
}
