import XCTest
@testable import TypeWhisper

@MainActor
final class MeetingCaptureServiceTests: XCTestCase {
    // `ModelManagerService` and `StreamingHandler` dereference the `PluginManager.shared`
    // singleton (an implicitly-unwrapped global set by `ServiceContainer` in the real app). The
    // isolated test host never constructs `ServiceContainer`, so provide an empty manager — with
    // no transcription plugins loaded, live streaming is skipped and the final transcription
    // throws, exercising the keep-live-segments fallback (plan D3).
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

    // MARK: - Test helpers

    /// A recorder wired entirely through the injectable overrides so CI never touches a real
    /// audio engine (plan D1: capture is driven through `startRecordingOverride` /
    /// `currentBufferOverride`).
    private func makeRecorder(
        recordingsDirectory: URL,
        samples: [Float] = Array(repeating: 0.2, count: 16_000)
    ) -> AudioRecorderService {
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
        recorder.currentBufferOverride = { samples }
        return recorder
    }

    private func makeCaptureService(
        meetingService: MeetingService,
        recorder: AudioRecorderService,
        flushIntervalSeconds: TimeInterval = 0
    ) -> MeetingCaptureService {
        let defaults = UserDefaults(suiteName: "MeetingCaptureServiceTests-\(UUID().uuidString)")!
        return MeetingCaptureService(
            meetingService: meetingService,
            audioRecorderService: recorder,
            modelManager: ModelManagerService(),
            defaults: defaults,
            flushIntervalSeconds: flushIntervalSeconds
        )
    }

    // MARK: - Incremental persistence + mid-capture crash-sim visibility

    func testStableSegmentsPersistIncrementallyAndAreVisibleMidCapture() async throws {
        let dir = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(dir) }

        let meetingService = MeetingService(appSupportDirectory: dir)
        let recorder = makeRecorder(recordingsDirectory: dir.appendingPathComponent("recordings"))
        let capture = makeCaptureService(meetingService: meetingService, recorder: recorder)

        let meeting = meetingService.createMeeting(title: "Live Capture", source: .adHoc, state: .scheduled)
        try await capture.start(meeting: meeting)

        capture.ingestLiveTranscript("Hello world.", elapsed: 1)
        capture.ingestLiveTranscript("Hello world. This is a test.", elapsed: 2)

        // A fresh service instance on the same directory must see the persisted segments while
        // capture is still in progress (durability / crash simulation, plan D2).
        let reader = MeetingService(appSupportDirectory: dir)
        let persisted = try XCTUnwrap(reader.meetings.first)
        XCTAssertEqual(persisted.state, .live)
        let texts = persisted.segments.sorted { $0.order < $1.order }.map(\.text)
        XCTAssertEqual(texts, ["Hello world.", "This is a test."])
        XCTAssertTrue(persisted.segments.allSatisfy { $0.source == .liveCapture })
    }

    // MARK: - Duplicate stable text upserts, not duplicates

    func testDuplicateStableTextDoesNotDuplicateSegments() async throws {
        let dir = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(dir) }

        let meetingService = MeetingService(appSupportDirectory: dir)
        let recorder = makeRecorder(recordingsDirectory: dir.appendingPathComponent("recordings"))
        let capture = makeCaptureService(meetingService: meetingService, recorder: recorder)

        let meeting = meetingService.createMeeting(title: "Dup", source: .adHoc, state: .scheduled)
        try await capture.start(meeting: meeting)

        capture.ingestLiveTranscript("Same text arrives.", elapsed: 1)
        capture.ingestLiveTranscript("Same text arrives.", elapsed: 2)
        capture.ingestLiveTranscript("Same text arrives.", elapsed: 3)

        XCTAssertEqual(meeting.segments.count, 1)
        XCTAssertEqual(meeting.segments.first?.text, "Same text arrives.")
    }

    // MARK: - Final transcription failure keeps live segments

    func testFinalTranscriptionFailureKeepsLiveSegments() async throws {
        let dir = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(dir) }

        let meetingService = MeetingService(appSupportDirectory: dir)
        // Non-empty buffer (> 8000 samples) so stop attempts a final transcription, which fails
        // because no transcription plugin is loaded in the test host.
        let recorder = makeRecorder(
            recordingsDirectory: dir.appendingPathComponent("recordings"),
            samples: Array(repeating: 0.2, count: 16_000)
        )
        let capture = makeCaptureService(meetingService: meetingService, recorder: recorder)

        let meeting = meetingService.createMeeting(title: "Final", source: .adHoc, state: .scheduled)
        try await capture.start(meeting: meeting)
        capture.ingestLiveTranscript("Live one.", elapsed: 1)
        capture.ingestLiveTranscript("Live one. Live two.", elapsed: 2)

        await capture.stop()

        XCTAssertEqual(meeting.state, .completed)
        let texts = meeting.segments.sorted { $0.order < $1.order }.map(\.text)
        XCTAssertEqual(texts, ["Live one.", "Live two."])
        XCTAssertTrue(meeting.segments.allSatisfy { $0.source == .liveCapture })
        // Audio was moved into the meetings library.
        XCTAssertNotNil(meeting.audioFileName)
        XCTAssertNotNil(meetingService.audioFileURL(for: meeting))
    }

    // MARK: - Recovery of interrupted meetings

    func testRecoverInterruptedMeetingsMarksLiveAsInterruptedAndKeepsSegments() throws {
        let dir = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(dir) }

        do {
            let service = MeetingService(appSupportDirectory: dir)
            let meeting = service.createMeeting(title: "Crashed", source: .adHoc, state: .live)
            service.appendStableSegments(
                [TranscriptionSegment(text: "captured before crash", start: 0, end: 2)],
                to: meeting
            )
        }

        let reopened = MeetingService(appSupportDirectory: dir)
        let recovered = reopened.recoverInterruptedMeetings()
        XCTAssertEqual(recovered.count, 1)

        let meeting = try XCTUnwrap(reopened.meetings.first)
        XCTAssertEqual(meeting.state, .interrupted)
        XCTAssertEqual(meeting.segments.count, 1)
        XCTAssertEqual(meeting.segments.first?.text, "captured before crash")

        // Idempotent: a second pass finds nothing left in `.live`.
        XCTAssertTrue(reopened.recoverInterruptedMeetings().isEmpty)
    }

    // MARK: - Mutual exclusion (captureOwner) in both directions

    func testMeetingCaptureRefusesWhenRecorderOwnsCaptureStack() async throws {
        let dir = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(dir) }

        let meetingService = MeetingService(appSupportDirectory: dir)
        let recorder = makeRecorder(recordingsDirectory: dir.appendingPathComponent("recordings"))
        // The standalone Recorder claims the stack first.
        XCTAssertTrue(recorder.acquireCaptureOwnership(.recorder))

        let capture = makeCaptureService(meetingService: meetingService, recorder: recorder)
        let meeting = meetingService.createMeeting(title: "Blocked", source: .adHoc, state: .scheduled)

        do {
            try await capture.start(meeting: meeting)
            XCTFail("Expected capture to be refused while the recorder owns the stack")
        } catch {
            XCTAssertEqual(error as? MeetingCaptureService.CaptureError, .recorderBusy)
        }
        XCTAssertFalse(capture.isCapturing)
        XCTAssertEqual(meeting.state, .scheduled)
    }

    func testRecorderRefusedWhileMeetingOwnsCaptureStack() async throws {
        let dir = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(dir) }

        let meetingService = MeetingService(appSupportDirectory: dir)
        let recorder = makeRecorder(recordingsDirectory: dir.appendingPathComponent("recordings"))
        let capture = makeCaptureService(meetingService: meetingService, recorder: recorder)

        let meeting = meetingService.createMeeting(title: "Owner", source: .adHoc, state: .scheduled)
        try await capture.start(meeting: meeting)

        XCTAssertEqual(recorder.currentCaptureOwner, .meeting)
        // The Recorder side must not be able to claim the stack now.
        XCTAssertFalse(recorder.acquireCaptureOwnership(.recorder))

        await capture.stop()
        // Ownership is released after stop, so the recorder can claim it again.
        XCTAssertNil(recorder.currentCaptureOwner)
        XCTAssertTrue(recorder.acquireCaptureOwnership(.recorder))
    }

    // MARK: - Notes persist with offsets

    func testNotesPersistWithElapsedOffsets() async throws {
        let dir = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(dir) }

        let meetingService = MeetingService(appSupportDirectory: dir)
        let recorder = makeRecorder(recordingsDirectory: dir.appendingPathComponent("recordings"))
        let capture = makeCaptureService(meetingService: meetingService, recorder: recorder)

        let meeting = meetingService.createMeeting(title: "Notes", source: .adHoc, state: .scheduled)
        try await capture.start(meeting: meeting)

        let note = capture.addNote("Follow up on schema")
        XCTAssertNotNil(note)
        XCTAssertEqual(meeting.notes.count, 1)
        XCTAssertEqual(meeting.notes.first?.text, "Follow up on schema")
        let offset = try XCTUnwrap(meeting.notes.first?.timestampOffset)
        XCTAssertGreaterThanOrEqual(offset, 0)

        // Blank notes are ignored.
        XCTAssertNil(capture.addNote("   "))
        XCTAssertEqual(meeting.notes.count, 1)
    }
}
