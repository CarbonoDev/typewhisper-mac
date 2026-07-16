import XCTest
@testable import TypeWhisper

/// M10 "ad-hoc meeting discoverability": creating an empty meeting without starting capture (the
/// "Create empty meeting" affordance) and the mutual-exclusion guard the menu-bar "Start Meeting
/// Recording" entry relies on. Exercised at the service layer (the view-model entry points are thin
/// delegations over these), matching the codebase's fakeable-seam testing convention.
@MainActor
final class MeetingAdHocMenuTests: XCTestCase {
    private var previousPluginManager: PluginManager?
    /// [Track J] The final pass runs on this queue; drained after `stop()`.
    private let captureJobQueue = JobQueueService()

    override func setUp() {
        super.setUp()
        // `ModelManagerService`/`StreamingHandler` dereference the `PluginManager.shared` global; the
        // isolated test host never builds `ServiceContainer`, so provide an empty manager (mirrors
        // `MeetingCaptureServiceTests`). With no plugins, live streaming is skipped.
        previousPluginManager = PluginManager.shared
        PluginManager.shared = PluginManager()
    }

    override func tearDown() {
        PluginManager.shared = previousPluginManager
        previousPluginManager = nil
        super.tearDown()
    }

    // MARK: - Helpers (recorder driven entirely through injectable overrides — no real audio engine)

    private func makeRecorder(recordingsDirectory: URL) -> AudioRecorderService {
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
        recorder.currentBufferOverride = { Array(repeating: Float(0.2), count: 16_000) }
        return recorder
    }

    private func makeCaptureService(
        meetingService: MeetingService,
        recorder: AudioRecorderService
    ) -> MeetingCaptureService {
        let defaults = UserDefaults(suiteName: "MeetingAdHocMenuTests-\(UUID().uuidString)")!
        return MeetingCaptureService(
            meetingService: meetingService,
            audioRecorderService: recorder,
            modelManager: ModelManagerService(),
            jobQueue: captureJobQueue,
            defaults: defaults,
            flushIntervalSeconds: 0
        )
    }

    // MARK: - Create empty meeting (no capture)

    /// "Create empty meeting" creates the ad-hoc meeting WITHOUT starting capture, so it stays
    /// `.scheduled` with no audio and no segments — ready to attach imports/notes to later.
    func testCreateEmptyAdHocMeetingLeavesScheduledWithNoAudio() throws {
        let dir = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(dir) }
        let meetingService = MeetingService(appSupportDirectory: dir)

        // Mirrors `MeetingsViewModel.createAdHocMeeting()` (no capture kick-off). No capture service
        // is constructed here: the point of "create empty meeting" is that it never touches the
        // capture stack, so asserting on an un-invoked capture service would be a tautology — we
        // instead verify the resulting meeting is a bare `.scheduled` ad-hoc row with no audio.
        let meeting = meetingService.createMeeting(title: "Ad-hoc", source: .adHoc, state: .scheduled, startDate: Date())

        XCTAssertEqual(meeting.state, .scheduled)
        XCTAssertEqual(meeting.source, .adHoc)
        XCTAssertNil(meeting.audioFileName, "no capture ran, so there is no audio")
        XCTAssertTrue(meeting.segments.isEmpty)
    }

    // MARK: - Menu guard (mutual exclusion when capture already active)

    /// The "Start Meeting Recording" menu entry must not start a second capture while one is active.
    /// The underlying guard is `MeetingCaptureService.start` throwing `.alreadyCapturing`; the guard
    /// surfaces (never crashes) and the active meeting is unchanged.
    func testStartWhileCapturingIsGuarded() async throws {
        let dir = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(dir) }
        let meetingService = MeetingService(appSupportDirectory: dir)
        let recorder = makeRecorder(recordingsDirectory: dir.appendingPathComponent("recordings"))
        let capture = makeCaptureService(meetingService: meetingService, recorder: recorder)

        let first = meetingService.createMeeting(title: "First", source: .adHoc, state: .scheduled)
        try await capture.start(meeting: first)
        XCTAssertTrue(capture.isCapturing)

        let second = meetingService.createMeeting(title: "Second", source: .adHoc, state: .scheduled)
        do {
            try await capture.start(meeting: second)
            XCTFail("expected a second concurrent capture to be rejected")
        } catch let error as MeetingCaptureService.CaptureError {
            XCTAssertEqual(error, .alreadyCapturing)
        }

        // The active meeting is still the first; the second never started.
        XCTAssertEqual(capture.activeMeeting?.id, first.id)
        XCTAssertTrue(capture.isCapturing)

        await capture.stop()
        await capture.awaitFinalizeTeardownForTesting()
        await captureJobQueue.drain()
    }
}
