import XCTest
import TypeWhisperPluginSDK
@testable import TypeWhisper

/// A fake `MeetingEventEmitting` that records every emitted event so the capture/output choke
/// points can be asserted without a real bus or plugins (addendum AD4 emission points).
@MainActor
final class RecordingMeetingEventEmitter: MeetingEventEmitting {
    private(set) var events: [MeetingEvent] = []

    func emit(_ event: MeetingEvent) {
        events.append(event)
    }

    var startedPayloads: [MeetingStartedPayload] {
        events.compactMap { if case let .started(p) = $0 { return p } else { return nil } }
    }
    var segmentPayloads: [MeetingTranscriptSegmentPayload] {
        events.compactMap { if case let .transcriptSegment(p) = $0 { return p } else { return nil } }
    }
    var readyPayloads: [MeetingTranscriptReadyPayload] {
        events.compactMap { if case let .transcriptReady(p) = $0 { return p } else { return nil } }
    }
    var outputPayloads: [MeetingOutputGeneratedPayload] {
        events.compactMap { if case let .outputGenerated(p) = $0 { return p } else { return nil } }
    }
    var endedPayloads: [MeetingEndedPayload] {
        events.compactMap { if case let .ended(p) = $0 { return p } else { return nil } }
    }
}

@MainActor
final class MeetingEventEmissionTests: XCTestCase {
    private var previousPluginManager: PluginManager?
    /// [Track J] The final pass (and its transcriptReady/ended emissions) now runs on this queue.
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

    // MARK: - Capture lifecycle emits started / transcriptSegment / transcriptReady / ended

    func testCaptureLifecycleEmitsAllFourPointsWithMeetingID() async throws {
        let dir = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(dir) }

        let emitter = RecordingMeetingEventEmitter()
        let meetingService = MeetingService(appSupportDirectory: dir)
        let recorder = makeRecorder(recordingsDirectory: dir.appendingPathComponent("recordings"))
        let defaults = UserDefaults(suiteName: "MeetingEventEmissionTests-\(UUID().uuidString)")!
        let capture = MeetingCaptureService(
            meetingService: meetingService,
            audioRecorderService: recorder,
            modelManager: ModelManagerService(),
            jobQueue: captureJobQueue,
            defaults: defaults,
            flushIntervalSeconds: 0,
            eventEmitter: emitter
        )

        let meeting = meetingService.createMeeting(
            title: "Sync",
            source: .calendar,
            state: .scheduled,
            attendees: [Attendee(name: "A", email: "a@acme.com"), Attendee(name: "B", email: "b@acme.com")]
        )
        let meetingID = meeting.id

        try await capture.start(meeting: meeting)

        // .started fired exactly once with the right identity/metadata.
        XCTAssertEqual(emitter.startedPayloads.count, 1)
        let started = try XCTUnwrap(emitter.startedPayloads.first)
        XCTAssertEqual(started.meetingID, meetingID)
        XCTAssertTrue(started.isCalendarMeeting)
        XCTAssertEqual(started.attendeeCount, 2)

        // Two distinct stable flushes → two .transcriptSegment batches.
        capture.ingestLiveTranscript("Hello world.", elapsed: 1)
        capture.ingestLiveTranscript("Hello world. This is a test.", elapsed: 2)
        XCTAssertEqual(emitter.segmentPayloads.count, 2)
        XCTAssertTrue(emitter.segmentPayloads.allSatisfy { $0.meetingID == meetingID })
        XCTAssertEqual(emitter.segmentPayloads.first?.segments.first?.text, "Hello world.")
        XCTAssertEqual(emitter.segmentPayloads.last?.segments.first?.text, "This is a test.")

        await capture.stop()
        // [Track J] transcriptReady/ended now emit inside the queued final job; the off-main teardown
        // must settle (to enqueue it) before the queue is drained.
        await capture.awaitFinalizeTeardownForTesting()
        await captureJobQueue.drain()

        // .transcriptReady then .ended, both with the meeting id.
        XCTAssertEqual(emitter.readyPayloads.count, 1)
        XCTAssertEqual(emitter.readyPayloads.first?.meetingID, meetingID)
        XCTAssertEqual(emitter.endedPayloads.count, 1)
        XCTAssertEqual(emitter.endedPayloads.first?.meetingID, meetingID)
        XCTAssertEqual(emitter.endedPayloads.first?.stateRaw, MeetingState.completed.rawValue)

        // Ordering: started precedes all segments; ready precedes ended.
        if case .started = emitter.events.first {} else { XCTFail("first event should be .started") }
        if case .ended = emitter.events.last {} else { XCTFail("last event should be .ended") }
    }

    // MARK: - transcriptSegment fires only on a stable flush, never on repeated identical snapshots

    func testTranscriptSegmentOnlyOnStableFlushNotOnRepeatedPartials() async throws {
        let dir = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(dir) }

        let emitter = RecordingMeetingEventEmitter()
        let meetingService = MeetingService(appSupportDirectory: dir)
        let recorder = makeRecorder(recordingsDirectory: dir.appendingPathComponent("recordings"))
        let defaults = UserDefaults(suiteName: "MeetingEventEmissionTests-\(UUID().uuidString)")!
        let capture = MeetingCaptureService(
            meetingService: meetingService,
            audioRecorderService: recorder,
            modelManager: ModelManagerService(),
            jobQueue: captureJobQueue,
            defaults: defaults,
            flushIntervalSeconds: 0,
            eventEmitter: emitter
        )

        let meeting = meetingService.createMeeting(title: "Ad-hoc", source: .adHoc, state: .scheduled)
        try await capture.start(meeting: meeting)

        capture.ingestLiveTranscript("Same text.", elapsed: 1)
        capture.ingestLiveTranscript("Same text.", elapsed: 2) // identical → no new stable suffix
        capture.ingestLiveTranscript("Same text.", elapsed: 3)

        XCTAssertEqual(emitter.segmentPayloads.count, 1, "repeated identical snapshots must not re-emit")

        await capture.stop()
        await capture.awaitFinalizeTeardownForTesting()
        await captureJobQueue.drain()
    }

    // MARK: - addOutput emits outputGenerated (single choke point covers all output kinds)

    func testAddOutputEmitsOutputGenerated() async throws {
        let dir = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(dir) }

        let emitter = RecordingMeetingEventEmitter()
        let meetingService = MeetingService(appSupportDirectory: dir, eventEmitter: emitter)
        let meeting = meetingService.createMeeting(title: "Retro", source: .adHoc, state: .completed)
        let templateID = UUID()

        _ = meetingService.addOutput(
            to: meeting,
            kind: .summary,
            content: "The summary body.",
            templateID: templateID,
            providerUsed: "openai",
            modelUsed: "gpt-4o"
        )

        XCTAssertEqual(emitter.outputPayloads.count, 1)
        let payload = try XCTUnwrap(emitter.outputPayloads.first)
        XCTAssertEqual(payload.meetingID, meeting.id)
        XCTAssertEqual(payload.kindRaw, MeetingOutputKind.summary.rawValue)
        XCTAssertEqual(payload.templateID, templateID)
        XCTAssertEqual(payload.content, "The summary body.")
        XCTAssertEqual(payload.provider, "openai")
        XCTAssertEqual(payload.model, "gpt-4o")
    }
}
