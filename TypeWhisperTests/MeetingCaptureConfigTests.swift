import XCTest
@testable import TypeWhisper

/// [Track C] MeetingCaptureService integration of capture-context rules (AD7) and configurable
/// final re-transcription (AD8). CI never touches a real audio engine — the recorder is driven
/// through overrides and the empty test `PluginManager` makes transcription fail (keep-live path).
@MainActor
final class MeetingCaptureConfigTests: XCTestCase {
    private var previousPluginManager: PluginManager?

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

    private func makeRecorder(recordingsDirectory: URL, sampleCount: Int = 16_000) -> AudioRecorderService {
        let recorder = AudioRecorderService()
        recorder.recordingsDirectoryOverride = recordingsDirectory
        recorder.startRecordingOverride = { _, _, _, outputURL in
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

        XCTAssertTrue(capture.finalRetranscriptionDegraded)
        XCTAssertEqual(meeting.segments.map(\.text), ["Kept."])
    }
}
