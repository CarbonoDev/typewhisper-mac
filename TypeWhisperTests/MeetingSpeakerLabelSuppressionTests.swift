import XCTest
@testable import TypeWhisper

/// Speaker-recognition amendment — carried hotfix (bug hunt Fix A + Fix B): the live transcript must
/// never show a speaker while capturing, and restarting a previously-labeled meeting must clear the
/// stale segment labels + speaker map (they can't be honestly extended across the stitched timeline).
final class MeetingSpeakerLabelSuppressionTests: XCTestCase {
    // MARK: - Fix A: render-suppression on the pure `transcriptBubbles` choke point

    private func segment(
        order: Int,
        start: Double,
        end: Double,
        text: String,
        speaker: String? = nil,
        source: MeetingSegmentSource = .liveCapture
    ) -> MeetingSegment {
        MeetingSegment(order: order, start: start, end: end, text: text, speakerLabel: speaker, source: source)
    }

    /// A meeting with SPEAKER_ME / SPEAKER_OTHERS labels, rendered with `suppressSpeakers: true`
    /// (capturing), yields zero `isMe` bubbles and nil name/label on every entry.
    func testSuppressSpeakersHidesAllAttribution() {
        let segments = [
            segment(order: 0, start: 0, end: 1, text: "hello", speaker: MeetingDiarizationEnricher.micSpeakerLabel),
            segment(order: 1, start: 1, end: 2, text: "hi there", speaker: MeetingDiarizationEnricher.systemSpeakerLabel)
        ]
        let map = [
            MeetingDiarizationEnricher.micSpeakerLabel: "Marco",
            MeetingDiarizationEnricher.systemSpeakerLabel: "Alex"
        ]

        let bubbles = MeetingsViewModel.transcriptBubbles(
            segments: segments, speakerMap: map, suppressSpeakers: true
        )
        let speech = bubbles.filter { $0.kind == .speech }

        XCTAssertEqual(speech.count, 2)
        for bubble in speech {
            XCTAssertFalse(bubble.isMe, "no bubble may be attributed to Me while capturing")
            XCTAssertNil(bubble.displayName, "no display name while capturing")
            XCTAssertNil(bubble.speakerLabel, "no raw speaker label while capturing")
        }
        // The transcript text itself is untouched — only attribution is suppressed.
        XCTAssertEqual(speech.map(\.text), ["hello", "hi there"])
    }

    /// The same segments in the resting state (`suppressSpeakers: false`, the default) render their
    /// labels — suppression is scoped to live capture, not a permanent change.
    func testUnsuppressedRendersLabels() {
        let segments = [
            segment(order: 0, start: 0, end: 1, text: "hello", speaker: MeetingDiarizationEnricher.micSpeakerLabel),
            segment(order: 1, start: 1, end: 2, text: "hi there", speaker: MeetingDiarizationEnricher.systemSpeakerLabel)
        ]
        let map = [
            MeetingDiarizationEnricher.micSpeakerLabel: "Marco",
            MeetingDiarizationEnricher.systemSpeakerLabel: "Alex"
        ]

        let bubbles = MeetingsViewModel.transcriptBubbles(segments: segments, speakerMap: map)
        let speech = bubbles.filter { $0.kind == .speech }

        XCTAssertTrue(speech[0].isMe)
        XCTAssertEqual(speech[0].displayName, "Marco")
        XCTAssertFalse(speech[1].isMe)
        XCTAssertEqual(speech[1].displayName, "Alex")
    }

    // MARK: - Fix B: restart clears stale segment labels + speaker map

    @MainActor
    private func makeStore() throws -> MeetingService {
        let dir = try TestSupport.makeTemporaryDirectory(prefix: "SpeakerHotfix")
        addTeardownBlock { TestSupport.remove(dir) }
        return MeetingService(appSupportDirectory: dir)
    }

    @MainActor
    func testClearSpeakerLabelsClearsSegmentsAndMap() throws {
        let service = try makeStore()
        let meeting = service.createMeeting(title: "Labeled", source: .adHoc, state: .completed)
        service.appendStableSegments([
            TranscriptionSegment(text: "a", start: 0, end: 1),
            TranscriptionSegment(text: "b", start: 1, end: 2)
        ], to: meeting)
        let ids = meeting.segments.sorted { $0.order < $1.order }.map(\.id)
        service.applySpeakerLabels(
            [
                MeetingSpeakerAssignment(segmentID: ids[0], label: MeetingDiarizationEnricher.micSpeakerLabel, confidence: 0.9),
                MeetingSpeakerAssignment(segmentID: ids[1], label: MeetingDiarizationEnricher.systemSpeakerLabel, confidence: 0.8)
            ],
            speakerMap: [MeetingDiarizationEnricher.micSpeakerLabel: "Me"],
            to: meeting
        )
        XCTAssertTrue(meeting.segments.contains { $0.speakerLabel != nil })
        XCTAssertFalse(meeting.speakerMap.isEmpty)

        service.clearSpeakerLabels(for: meeting)

        XCTAssertTrue(meeting.segments.allSatisfy { $0.speakerLabel == nil && $0.speakerConfidence == nil })
        XCTAssertTrue(meeting.speakerMap.isEmpty)
        // Text is preserved — only attribution is cleared.
        XCTAssertEqual(meeting.segments.sorted { $0.order < $1.order }.map(\.text), ["a", "b"])
    }

    @MainActor
    func testClearSpeakerLabelsIsNoOpWhenNothingLabeled() throws {
        let service = try makeStore()
        let meeting = service.createMeeting(title: "Plain", source: .adHoc, state: .completed)
        service.appendStableSegments([TranscriptionSegment(text: "a", start: 0, end: 1)], to: meeting)
        let updatedBefore = meeting.updatedAt

        service.clearSpeakerLabels(for: meeting)

        // No labels/map to clear: idempotent no-op (no spurious write).
        XCTAssertEqual(meeting.updatedAt, updatedBefore)
    }

    // MARK: - Fix B: restart integration (capture start on a labeled meeting clears its labels)

    @MainActor
    private func makeRecorder(recordingsDirectory: URL) -> AudioRecorderService {
        let recorder = AudioRecorderService()
        recorder.recordingsDirectoryOverride = recordingsDirectory
        recorder.startRecordingOverride = { _, _, _, outputURL in
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
        recorder.currentBufferOverride = { Array(repeating: Float(0.2), count: 16_000) }
        return recorder
    }

    @MainActor
    func testCaptureRestartClearsStaleLabels() async throws {
        let previousPluginManager = PluginManager.shared
        PluginManager.shared = PluginManager()
        defer { PluginManager.shared = previousPluginManager }

        let dir = try TestSupport.makeTemporaryDirectory(prefix: "SpeakerHotfixRestart")
        defer { TestSupport.remove(dir) }
        let service = MeetingService(appSupportDirectory: dir)
        let recorder = makeRecorder(recordingsDirectory: dir.appendingPathComponent("rec"))
        let jobQueue = JobQueueService()
        let suite = "SpeakerHotfixRestart-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let capture = MeetingCaptureService(
            meetingService: service,
            audioRecorderService: recorder,
            modelManager: ModelManagerService(),
            jobQueue: jobQueue,
            defaults: defaults,
            flushIntervalSeconds: 0
        )

        // A completed meeting that was already labeled.
        let meeting = service.createMeeting(title: "Restarted", source: .adHoc, state: .completed)
        service.appendStableSegments([TranscriptionSegment(text: "prior", start: 0, end: 1)], to: meeting)
        let id = try XCTUnwrap(meeting.segments.first?.id)
        service.applySpeakerLabels(
            [MeetingSpeakerAssignment(segmentID: id, label: MeetingDiarizationEnricher.micSpeakerLabel, confidence: 0.9)],
            speakerMap: [MeetingDiarizationEnricher.micSpeakerLabel: "Me"],
            to: meeting
        )
        XCTAssertFalse(meeting.speakerMap.isEmpty)

        try await capture.start(meeting: meeting)

        // The restart (non-empty meeting) cleared the pre-restart labels + map immediately.
        XCTAssertTrue(meeting.segments.allSatisfy { $0.speakerLabel == nil })
        XCTAssertTrue(meeting.speakerMap.isEmpty)

        await capture.stop()
        await capture.awaitFinalizeTeardownForTesting()
        await jobQueue.drain()
    }

    // MARK: - [M1/D2] Never co-render a path caption with a contradictory status

    /// A resolved `.channel`/`.cloud` path names a labeling source, so a "no path" status (e.g. the
    /// persisted "unavailable" line — the owner's screenshot) must be suppressed beneath it.
    func testStatusSuppressedUnderResolvedChannelAndCloudPaths() {
        let status = "Speaker identification is unavailable."
        XCTAssertFalse(MeetingsViewModel.showsDiarizationStatus(status, under: .channel))
        XCTAssertFalse(MeetingsViewModel.showsDiarizationStatus(status, under: .cloud))
    }

    /// The pyannote / none / not-yet-resolved paths may still surface a legitimate status.
    func testStatusShownUnderPyannoteNoneAndUnresolvedPaths() {
        let status = "No speakers detected."
        XCTAssertTrue(MeetingsViewModel.showsDiarizationStatus(status, under: .pyannote(numSpeakers: nil)))
        XCTAssertTrue(MeetingsViewModel.showsDiarizationStatus(status, under: SpeakerSource.none))
        XCTAssertTrue(MeetingsViewModel.showsDiarizationStatus(status, under: nil))
    }

    /// A nil status never renders, regardless of the resolved path.
    func testNilStatusNeverShown() {
        XCTAssertFalse(MeetingsViewModel.showsDiarizationStatus(nil, under: .pyannote(numSpeakers: 2)))
        XCTAssertFalse(MeetingsViewModel.showsDiarizationStatus(nil, under: SpeakerSource.none))
        XCTAssertFalse(MeetingsViewModel.showsDiarizationStatus(nil, under: .channel))
    }
}
