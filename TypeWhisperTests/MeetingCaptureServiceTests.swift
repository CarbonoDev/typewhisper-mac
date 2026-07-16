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
    /// [Track J] The capture service now enqueues the final re-transcription on this queue instead of
    /// awaiting it inline; tests settle it with `await captureJobQueue.drain()` after `stop()`.
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
            jobQueue: captureJobQueue,
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

    // MARK: - [M1/D3] Meeting capture records separate mic/system tracks (per session)

    /// Meeting capture must record separate mic (L) / system (R) tracks so the two-person channel
    /// labeling path is structurally reachable — and it must do so **per session**, never mutating the
    /// shared recorder instance's `trackMode` (the standalone Recorder's preference). Verified by the
    /// captured `sessionTrackMode` after `start()` while the instance `trackMode` stays `.mixed`.
    func testCaptureStartsRecorderInSeparateTrackModeWithoutLeaking() async throws {
        let dir = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(dir) }

        let meetingService = MeetingService(appSupportDirectory: dir)
        let recorder = makeRecorder(recordingsDirectory: dir.appendingPathComponent("recordings"))
        // The instance preference the standalone Recorder would use — must be left untouched.
        recorder.trackMode = .mixed
        let capture = makeCaptureService(meetingService: meetingService, recorder: recorder)

        let meeting = meetingService.createMeeting(title: "Two Person", source: .adHoc, state: .scheduled)
        try await capture.start(meeting: meeting)

        XCTAssertEqual(recorder.sessionTrackMode, .separate, "meeting session records separate tracks")
        XCTAssertEqual(recorder.trackMode, .mixed, "the shared instance preference must not leak")

        await capture.stop()
        await capture.awaitFinalizeTeardownForTesting()
        await captureJobQueue.drain()

        // The leak guard also holds after teardown: a later standalone recording still mixes.
        XCTAssertEqual(recorder.trackMode, .mixed)
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
        // The heavy teardown now runs off the MainActor; settle it (it enqueues the final pass), then
        // drain the queued job before asserting the outcome.
        await capture.awaitFinalizeTeardownForTesting()
        await captureJobQueue.drain()

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
        // Ownership is released by the off-main teardown, not inline in `stop()`; settle it first.
        await capture.awaitFinalizeTeardownForTesting()
        await captureJobQueue.drain()
        // Ownership is released after stop, so the recorder can claim it again.
        XCTAssertNil(recorder.currentCaptureOwner)
        XCTAssertTrue(recorder.acquireCaptureOwnership(.recorder))
    }

    // MARK: - Restart preserves prior session's segments and audio (M3 review finding 1)

    func testRestartCapturePreservesPriorSegmentsAndAudio() async throws {
        let dir = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(dir) }

        let meetingService = MeetingService(appSupportDirectory: dir)
        let recorder = makeRecorder(recordingsDirectory: dir.appendingPathComponent("recordings"))
        let capture = makeCaptureService(meetingService: meetingService, recorder: recorder)

        // A meeting with a prior finalized live-capture session ending at t=10.
        let meeting = meetingService.createMeeting(title: "Restart", source: .adHoc, state: .completed)
        meetingService.appendStableSegments(
            [
                TranscriptionSegment(text: "prior one", start: 0, end: 5),
                TranscriptionSegment(text: "prior two", start: 5, end: 10)
            ],
            to: meeting
        )
        let priorIDs = Set(meeting.segments.map(\.id))

        // A pre-existing `<uuid>.wav` from that prior session must not be overwritten on restart.
        let audioDir = dir.appendingPathComponent("meetings-audio", isDirectory: true)
        let existingAudio = audioDir.appendingPathComponent("\(meeting.id.uuidString).wav")
        try Data("OLD_AUDIO".utf8).write(to: existingAudio)

        // Restart capture, add new content, stop.
        try await capture.start(meeting: meeting)
        capture.ingestLiveTranscript("New content.", elapsed: 2)
        await capture.stop()
        // [Track J] The restart's final replace runs on the queued job; settle the off-main teardown
        // (which adopts the audio and enqueues the pass), then drain before asserting.
        await capture.awaitFinalizeTeardownForTesting()
        await captureJobQueue.drain()

        // Prior segments survive verbatim.
        let texts = meeting.segments.sorted { $0.order < $1.order }.map(\.text)
        XCTAssertTrue(texts.contains("prior one"))
        XCTAssertTrue(texts.contains("prior two"))
        XCTAssertTrue(texts.contains("New content."))
        XCTAssertEqual(meeting.segments.filter { priorIDs.contains($0.id) }.count, 2)

        // Orders are contiguous and monotonic across the whole meeting.
        let orders = meeting.segments.map(\.order).sorted()
        XCTAssertEqual(orders, Array(0..<meeting.segments.count))

        // New segment(s) start at/after the prior session's end (t=10).
        let newSegments = meeting.segments.filter { !priorIDs.contains($0.id) }
        XCTAssertFalse(newSegments.isEmpty)
        for segment in newSegments {
            XCTAssertGreaterThanOrEqual(segment.start, 10)
        }

        // The pre-existing audio file is untouched; the new session's audio got a -2 suffix.
        XCTAssertEqual(try String(contentsOf: existingAudio, encoding: .utf8), "OLD_AUDIO")
        let audioFiles = try FileManager.default.contentsOfDirectory(atPath: audioDir.path)
            .filter { $0.hasPrefix(meeting.id.uuidString) }
        XCTAssertTrue(audioFiles.contains("\(meeting.id.uuidString).wav"))
        XCTAssertTrue(
            audioFiles.contains { $0.hasPrefix("\(meeting.id.uuidString)-2") },
            "restarted session audio must be versioned, got \(audioFiles)"
        )
        XCTAssertEqual(meeting.audioFileName, audioFiles.first { $0.hasPrefix("\(meeting.id.uuidString)-2") })
    }

    // MARK: - A failed restart must not destroy the meeting's speaker labels (M2 carried finding)

    /// Fix B clears a labeled meeting's speaker labels + map when capture is *restarted* on it (the
    /// stitched timeline can never be honestly re-verified). That clear now runs only *after*
    /// `startRecording` succeeds: a restart whose recorder start throws returns with the meeting's
    /// valid labels intact instead of destroying honest attribution on a session that never began.
    func testFailedRestartPreservesSpeakerLabels() async throws {
        let dir = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(dir) }

        let meetingService = MeetingService(appSupportDirectory: dir)
        let recorder = makeRecorder(recordingsDirectory: dir.appendingPathComponent("recordings"))
        // The recorder start fails (e.g. device unavailable) on this restart attempt.
        struct StartBoom: Error {}
        recorder.startRecordingOverride = { _, _, _, _, _ in throw StartBoom() }

        let capture = makeCaptureService(meetingService: meetingService, recorder: recorder)

        // A previously-labeled, finalized meeting.
        let meeting = meetingService.createMeeting(title: "Labeled", source: .adHoc, state: .completed)
        meetingService.appendStableSegments(
            [
                TranscriptionSegment(text: "prior one", start: 0, end: 5),
                TranscriptionSegment(text: "prior two", start: 5, end: 10)
            ],
            to: meeting
        )
        let ids = meeting.segments.sorted { $0.order < $1.order }.map(\.id)
        meetingService.applySpeakerLabels(
            [
                MeetingSpeakerAssignment(segmentID: ids[0], label: "SPEAKER_00", confidence: 0.9),
                MeetingSpeakerAssignment(segmentID: ids[1], label: "SPEAKER_01", confidence: 0.8)
            ],
            speakerMap: ["SPEAKER_00": "Marco", "SPEAKER_01": "Alex"],
            to: meeting
        )

        do {
            try await capture.start(meeting: meeting)
            XCTFail("Expected the recorder start failure to propagate")
        } catch {
            XCTAssertTrue(error is StartBoom)
        }

        // Labels + map survive the failed restart; the meeting's state is restored.
        XCTAssertEqual(meeting.speakerMap, ["SPEAKER_00": "Marco", "SPEAKER_01": "Alex"])
        XCTAssertEqual(
            meeting.segments.sorted { $0.order < $1.order }.compactMap(\.speakerLabel),
            ["SPEAKER_00", "SPEAKER_01"]
        )
        XCTAssertEqual(meeting.state, .completed)
        XCTAssertNil(capture.activeMeeting)
        XCTAssertFalse(capture.isCapturing)
    }

    /// The other half of the moved clear: a *successful* restart on a labeled meeting still clears the
    /// stale labels + map (the stitched timeline is a `.timelineMismatch`).
    func testSuccessfulRestartClearsSpeakerLabels() async throws {
        let dir = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(dir) }

        let meetingService = MeetingService(appSupportDirectory: dir)
        let recorder = makeRecorder(recordingsDirectory: dir.appendingPathComponent("recordings"))
        let capture = makeCaptureService(meetingService: meetingService, recorder: recorder)

        let meeting = meetingService.createMeeting(title: "Labeled", source: .adHoc, state: .completed)
        meetingService.appendStableSegments(
            [TranscriptionSegment(text: "prior", start: 0, end: 5)],
            to: meeting
        )
        let id = try XCTUnwrap(meeting.segments.first?.id)
        meetingService.applySpeakerLabels(
            [MeetingSpeakerAssignment(segmentID: id, label: "SPEAKER_00", confidence: 0.9)],
            speakerMap: ["SPEAKER_00": "Marco"],
            to: meeting
        )

        try await capture.start(meeting: meeting)
        await capture.stop()
        await capture.awaitFinalizeTeardownForTesting()
        await captureJobQueue.drain()

        // The prior label + map were cleared by the successful restart.
        XCTAssertTrue(meeting.speakerMap.isEmpty)
        XCTAssertTrue(meeting.segments.allSatisfy { $0.speakerLabel == nil })
    }

    // MARK: - Concurrent start is rejected without side effects (M3 review finding 2)

    func testSecondConcurrentStartIsRejectedAndCreatesNoSideEffects() async throws {
        let dir = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(dir) }

        let meetingService = MeetingService(appSupportDirectory: dir)
        let recorder = makeRecorder(recordingsDirectory: dir.appendingPathComponent("recordings"))
        let capture = makeCaptureService(meetingService: meetingService, recorder: recorder)

        let first = meetingService.createMeeting(title: "First", source: .adHoc, state: .scheduled)
        try await capture.start(meeting: first)

        // The synchronous `isCapturing` guard rejects a second start before it can take effect —
        // the underpinning of the window's stray-empty-meeting fix.
        let second = meetingService.createMeeting(title: "Second", source: .adHoc, state: .scheduled)
        do {
            try await capture.start(meeting: second)
            XCTFail("Expected alreadyCapturing")
        } catch {
            XCTAssertEqual(error as? MeetingCaptureService.CaptureError, .alreadyCapturing)
        }
        XCTAssertEqual(capture.activeMeeting?.id, first.id)
        XCTAssertEqual(second.state, .scheduled)

        await capture.stop()
        await capture.awaitFinalizeTeardownForTesting()
        await captureJobQueue.drain()
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

    // MARK: - Notes stamp on the meeting timeline across a restart (finding 5)

    func testNotesDuringRestartedSessionStampOnMeetingTimeline() async throws {
        let dir = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(dir) }

        let meetingService = MeetingService(appSupportDirectory: dir)
        let recorder = makeRecorder(recordingsDirectory: dir.appendingPathComponent("recordings"))
        let capture = makeCaptureService(meetingService: meetingService, recorder: recorder)

        // A meeting with a prior finalized session ending at t=10.
        let meeting = meetingService.createMeeting(title: "Restart Notes", source: .adHoc, state: .completed)
        meetingService.appendStableSegments(
            [TranscriptionSegment(text: "prior", start: 0, end: 10)],
            to: meeting
        )

        try await capture.start(meeting: meeting)
        let note = capture.addNote("restart note")
        XCTAssertNotNil(note)

        // The note offset sits on the meeting timeline (after the prior session), not at ~0 where it
        // would collide with session 1's timeline in outputs/export.
        let offset = try XCTUnwrap(meeting.notes.first?.timestampOffset)
        XCTAssertGreaterThanOrEqual(offset, 10)

        await capture.stop()
        await capture.awaitFinalizeTeardownForTesting()
        await captureJobQueue.drain()
    }

    // MARK: - Start is refused during stop()'s finalize window (finding 2)

    func testConcurrentStartRefusedWhileStopIsFinalizing() async throws {
        let dir = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(dir) }

        let meetingService = MeetingService(appSupportDirectory: dir)
        let recorder = makeRecorder(recordingsDirectory: dir.appendingPathComponent("recordings"))
        let capture = makeCaptureService(meetingService: meetingService, recorder: recorder)

        let first = meetingService.createMeeting(title: "First", source: .adHoc, state: .scheduled)
        try await capture.start(meeting: first)

        // Hold the off-main teardown open inside its `stopRecording` step so the test can probe the
        // finalize window (isCapturing already false, but a new session must still be refused).
        let gate = FinalizeGate()
        recorder.stopRecordingOverride = { outputURL in
            await gate.enter()
            await gate.awaitReleased()
            try Data("recorded".utf8).write(to: outputURL)
            return outputURL
        }

        let second = meetingService.createMeeting(title: "Second", source: .adHoc, state: .scheduled)
        // `stop()` now returns immediately; its heavy teardown runs off the MainActor. Driving the
        // gate below lets that teardown advance to the (held) `stopRecording` step.
        await capture.stop()

        await gate.awaitEntered()
        XCTAssertFalse(capture.isCapturing)
        XCTAssertTrue(capture.isFinalizing, "isFinalizing stays closed across the whole off-main teardown")

        do {
            try await capture.start(meeting: second)
            XCTFail("Expected start to be refused during the finalize window")
        } catch {
            XCTAssertEqual(error as? MeetingCaptureService.CaptureError, .alreadyCapturing)
        }
        // No side effects: the second meeting was never touched.
        XCTAssertEqual(second.state, .scheduled)
        XCTAssertEqual(capture.activeMeeting?.id, first.id)

        await gate.release()
        // Settle the off-main teardown: it releases the gate, adopts the audio, reopens `isFinalizing`,
        // and enqueues the final pass (still just a queued job until drained).
        await capture.awaitFinalizeTeardownForTesting()
        XCTAssertFalse(capture.isFinalizing)
        XCTAssertFalse(capture.isCapturing)
        await captureJobQueue.drain()

        XCTAssertEqual(first.state, .completed)
        XCTAssertEqual(second.state, .scheduled)
    }

    // MARK: - Stop returns instantly; heavy teardown runs off the MainActor (freeze fix)

    /// The window-freeze fix: `stop()` must return *before* the heavy teardown (buffer snapshot,
    /// recorder mixdown) finishes, flipping the meeting to a visible `.processing` / finalizing state
    /// immediately. Asserted with a slow `stopRecording` stub — `stop()` completes while the stub is
    /// still blocked, `isFinalizing` is true, the meeting is `.processing`, and the final-transcription
    /// job is only enqueued once teardown settles.
    func testStopReturnsWhileHeavyTeardownStillRunning() async throws {
        let dir = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(dir) }

        let meetingService = MeetingService(appSupportDirectory: dir)
        let recorder = makeRecorder(recordingsDirectory: dir.appendingPathComponent("recordings"))
        let capture = makeCaptureService(meetingService: meetingService, recorder: recorder)

        // A slow "mixdown": stop-recording blocks until the test releases it.
        let gate = FinalizeGate()
        recorder.stopRecordingOverride = { outputURL in
            await gate.enter()
            await gate.awaitReleased()
            try Data("recorded".utf8).write(to: outputURL)
            return outputURL
        }

        let meeting = meetingService.createMeeting(title: "Freeze", source: .adHoc, state: .scheduled)
        try await capture.start(meeting: meeting)
        capture.ingestLiveTranscript("Live words.", elapsed: 1)

        // `stop()` returns without awaiting the (slow) teardown.
        await capture.stop()

        // Drive the off-main teardown up to the held `stopRecording` stub. That we can observe the
        // stub still running proves `stop()` did not await it.
        await gate.awaitEntered()
        XCTAssertFalse(capture.isCapturing, "recording indicator is already off")
        XCTAssertTrue(capture.isFinalizing, "meeting shows the finalizing state while teardown runs")
        XCTAssertEqual(meeting.state, .processing, "meeting is marked processing immediately")
        // The final-transcription job is NOT enqueued yet — teardown enqueues it only after the buffer
        // snapshot / recorder stop / audio adopt complete.
        XCTAssertFalse(captureJobQueue.hasActiveJob(kind: .finalTranscription, meetingID: meeting.id))

        // Release the slow stub and let teardown finish.
        await gate.release()
        await capture.awaitFinalizeTeardownForTesting()
        XCTAssertFalse(capture.isFinalizing)
        XCTAssertTrue(captureJobQueue.hasActiveJob(kind: .finalTranscription, meetingID: meeting.id))

        await captureJobQueue.drain()
        XCTAssertEqual(meeting.state, .completed, "meeting is never left stuck in .processing")
        XCTAssertNotNil(meeting.audioFileName, "audio was adopted by the off-main teardown")
    }

    // MARK: - [Track J] Final re-transcription runs as a queued, cancellable job

    private func waitUntil(
        _ condition: @escaping () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        var iterations = 0
        while !condition() {
            if iterations > 100_000 { XCTFail("condition never met", file: file, line: line); return }
            await Task.yield()
            iterations += 1
        }
    }

    private func result(_ text: String, start: Double = 0, end: Double = 3) -> TranscriptionResult {
        TranscriptionResult(
            text: text,
            detectedLanguage: "en",
            duration: end,
            processingTime: 0.1,
            engineUsed: "stub",
            segments: [TranscriptionSegment(text: text, start: start, end: end)]
        )
    }

    /// The meeting stays `.processing` after `stop()` returns and only reaches `.completed` once the
    /// queued final-transcription job runs (the J2 split of `stop()`).
    func testMeetingStaysProcessingUntilFinalJobRunsThenCompletes() async throws {
        let dir = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(dir) }
        let meetingService = MeetingService(appSupportDirectory: dir)
        let recorder = makeRecorder(recordingsDirectory: dir.appendingPathComponent("recordings"))
        let capture = makeCaptureService(meetingService: meetingService, recorder: recorder)
        capture.finalizeTranscribeOverrideForTesting = { _, _ in self.result("Final clean transcript.") }

        let meeting = meetingService.createMeeting(title: "Proc", source: .adHoc, state: .scheduled)
        try await capture.start(meeting: meeting)
        capture.ingestLiveTranscript("Live rough.", elapsed: 1)
        await capture.stop()
        // Settle the off-main teardown (it enqueues the final pass); the queued job has still not run.
        await capture.awaitFinalizeTeardownForTesting()

        // Teardown finished but the queued job has not run yet: still processing.
        XCTAssertEqual(meeting.state, .processing)
        XCTAssertTrue(captureJobQueue.hasActiveJob(kind: .finalTranscription, meetingID: meeting.id))

        await captureJobQueue.drain()
        XCTAssertEqual(meeting.state, .completed)
    }

    /// A successful final pass replaces the live segments with the re-transcribed ones.
    func testFinalTranscriptionSuccessReplacesLiveSegments() async throws {
        let dir = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(dir) }
        let meetingService = MeetingService(appSupportDirectory: dir)
        let recorder = makeRecorder(recordingsDirectory: dir.appendingPathComponent("recordings"))
        let capture = makeCaptureService(meetingService: meetingService, recorder: recorder)
        capture.finalizeTranscribeOverrideForTesting = { _, _ in self.result("Final clean transcript.") }

        let meeting = meetingService.createMeeting(title: "Success", source: .adHoc, state: .scheduled)
        try await capture.start(meeting: meeting)
        capture.ingestLiveTranscript("live rough.", elapsed: 1)
        await capture.stop()
        await capture.awaitFinalizeTeardownForTesting()
        await captureJobQueue.drain()

        XCTAssertEqual(meeting.state, .completed)
        XCTAssertEqual(meeting.segments.sorted { $0.order < $1.order }.map(\.text), ["Final clean transcript."])
    }

    /// Cancelling the running final-transcription job keeps the live segments and still completes the
    /// meeting — it must never be left stuck in `.processing` (mirrors the failure path).
    func testCancelledFinalTranscriptionKeepsLiveSegmentsAndCompletes() async throws {
        let dir = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(dir) }
        let meetingService = MeetingService(appSupportDirectory: dir)
        let recorder = makeRecorder(recordingsDirectory: dir.appendingPathComponent("recordings"))
        let capture = makeCaptureService(meetingService: meetingService, recorder: recorder)
        // Blocks long enough that the test cancels it first; the cancelled sleep throws, so the
        // override's result is never used and the keep-live fallback fires.
        capture.finalizeTranscribeOverrideForTesting = { _, _ in
            try await Task.sleep(nanoseconds: 5_000_000_000)
            return self.result("SHOULD_NOT_BE_USED")
        }

        let meeting = meetingService.createMeeting(title: "Cancel", source: .adHoc, state: .scheduled)
        try await capture.start(meeting: meeting)
        capture.ingestLiveTranscript("Live one.", elapsed: 1)
        capture.ingestLiveTranscript("Live one. Live two.", elapsed: 2)
        await capture.stop()
        // The off-main teardown enqueues the final pass; settle it before grabbing the job id.
        await capture.awaitFinalizeTeardownForTesting()

        let jobID = try XCTUnwrap(captureJobQueue.jobs.first { $0.kind == .finalTranscription }?.id)
        await waitUntil { self.captureJobQueue.jobs.first { $0.id == jobID }?.state == .running }
        captureJobQueue.cancel(jobID)
        await captureJobQueue.drain()

        XCTAssertEqual(meeting.state, .completed, "meeting must never stay stuck in .processing")
        XCTAssertEqual(meeting.segments.sorted { $0.order < $1.order }.map(\.text), ["Live one.", "Live two."])
        XCTAssertTrue(meeting.segments.allSatisfy { $0.source == .liveCapture })
        XCTAssertEqual(captureJobQueue.jobs.first { $0.id == jobID }?.state, .cancelled)
    }
}

/// Two-way async gate that lets a test suspend `stop()`'s finalize at the `stopRecording` hook,
/// probe the window, then release it.
private actor FinalizeGate {
    private var entered = false
    private var released = false
    private var enterWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    /// Called from inside the finalize hook to announce it has entered the window.
    func enter() {
        entered = true
        enterWaiters.forEach { $0.resume() }
        enterWaiters.removeAll()
    }

    /// The test awaits this to know finalize is in progress.
    func awaitEntered() async {
        if entered { return }
        await withCheckedContinuation { enterWaiters.append($0) }
    }

    /// The test calls this to let finalize proceed.
    func release() {
        released = true
        releaseWaiters.forEach { $0.resume() }
        releaseWaiters.removeAll()
    }

    /// The finalize hook awaits this until the test releases it.
    func awaitReleased() async {
        if released { return }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }
}
