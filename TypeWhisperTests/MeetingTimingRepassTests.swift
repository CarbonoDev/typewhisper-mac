import XCTest
@testable import TypeWhisper

/// Speaker-recognition amendment (M9-SPK-B / D-A6) — the keep-live timing re-pass wired through the
/// diarization enricher, plus the times-only writer and its gating. Hermetic: a stub reference
/// transcriber, a stub diarization provider, and synthetic mono audio via a stub inspector — no
/// AVFoundation, no sidecar, no plugin graph.
@MainActor
final class MeetingTimingRepassTests: XCTestCase {

    // MARK: - Stubs

    /// Mono synthetic audio (a single non-silent channel), so `enrich` takes the pyannote/mono path.
    private struct MonoInspector: MeetingAudioInspecting {
        let audio: MeetingAudioData
        func channelCount(at url: URL) throws -> Int { audio.channels.count }
        func load(at url: URL) throws -> MeetingAudioData { audio }
    }

    /// A reference transcriber that returns canned well-timed segments, counts its calls, and can be
    /// made to throw (to simulate a cancelled/failed reference transcription).
    private final class SpyTranscriber: MeetingAudioTranscribing {
        private(set) var callCount = 0
        var result: TranscriptionResult
        var error: Error?
        init(result: TranscriptionResult, error: Error? = nil) {
            self.result = result
            self.error = error
        }
        func transcribeImportedAudio(samples: [Float], languageSelection: LanguageSelection) async throws -> TranscriptionResult {
            callCount += 1
            if let error { throw error }
            return result
        }
    }

    private struct StubProvider: DiarizationProvider {
        let available: Bool
        let segments: [SpeakerSegment]
        var isAvailable: Bool { get async { available } }
        func diarize(wavData: Data, numSpeakers: Int?) async throws -> [SpeakerSegment] { segments }
    }

    // MARK: - Helpers

    private func makeStore() throws -> (MeetingService, URL) {
        let dir = try TestSupport.makeTemporaryDirectory(prefix: "TimingRepass")
        addTeardownBlock { TestSupport.remove(dir) }
        return (MeetingService(appSupportDirectory: dir), dir)
    }

    private func giveAudio(_ meeting: Meeting, service: MeetingService, dir: URL) throws {
        let source = dir.appendingPathComponent("src-\(UUID().uuidString).wav")
        try Data("audio".utf8).write(to: source)
        service.adoptAudioFile(source, for: meeting)
    }

    /// ~10 s of non-silent mono audio (16 kHz), long enough that the coarse [0,10] transcript timeline
    /// is not flagged as a mismatch.
    private func monoInspector(seconds: Int = 10) -> MonoInspector {
        let sr = 16_000
        let mono = [Float](repeating: 0.1, count: sr * seconds)
        return MonoInspector(audio: MeetingAudioData(channels: [mono], sampleRate: Double(sr)))
    }

    private func referenceResult(_ segments: [(String, Double, Double)]) -> TranscriptionResult {
        TranscriptionResult(
            text: segments.map(\.0).joined(separator: " "),
            detectedLanguage: nil,
            duration: 0,
            processingTime: 0,
            engineUsed: "stub",
            segments: segments.map { TranscriptionSegment(text: $0.0, start: $0.1, end: $0.2) }
        )
    }

    private func makeEnricher(
        _ service: MeetingService,
        inspector: MeetingAudioInspecting,
        provider: DiarizationProvider,
        transcriber: MeetingAudioTranscribing?
    ) -> MeetingDiarizationEnricher {
        MeetingDiarizationEnricher(
            meetingService: service,
            provider: provider,
            audioInspector: inspector,
            numSpeakersProvider: { nil },
            transcriber: transcriber
        )
    }

    /// A coarse-timed keep-live meeting: two segments at ~batch boundaries, `timestampsRefined` unset.
    private func makeCoarseMeeting(_ service: MeetingService, dir: URL) throws -> Meeting {
        let meeting = service.createMeeting(title: "Keep-live", source: .adHoc, state: .completed)
        service.appendStableSegments([
            TranscriptionSegment(text: "hello world", start: 0, end: 5),
            TranscriptionSegment(text: "goodbye now", start: 5, end: 10)
        ], to: meeting)
        try giveAudio(meeting, service: service, dir: dir)
        XCTAssertNil(meeting.timestampsRefined)
        return meeting
    }

    // MARK: - End-to-end: re-time then label; text kept byte-identical

    func testIdentifyRefinesTimingThenLabelsKeepingTextByteIdentical() async throws {
        let (service, dir) = try makeStore()
        let meeting = try makeCoarseMeeting(service, dir: dir)
        let originalTexts = meeting.segments.sorted { $0.order < $1.order }.map(\.text)

        // Reference transcription puts the same words at their real (tight) speech times.
        let transcriber = SpyTranscriber(result: referenceResult([("hello world", 0, 1), ("goodbye now", 2, 3)]))
        // Diarization then attributes the (now-refined) spans to two speakers.
        let provider = StubProvider(available: true, segments: [
            SpeakerSegment(start: 0, end: 1.5, speaker: "SPEAKER_00"),
            SpeakerSegment(start: 1.5, end: 3.5, speaker: "SPEAKER_01")
        ])
        let enricher = makeEnricher(service, inspector: monoInspector(), provider: provider, transcriber: transcriber)

        let outcome = try await enricher.enrich(meeting)

        XCTAssertEqual(outcome, .labeled(speakerCount: 2))
        XCTAssertEqual(transcriber.callCount, 1, "the reference transcription ran exactly once")
        XCTAssertEqual(meeting.timestampsRefined, true, "the meeting is marked refined")

        let sorted = meeting.segments.sorted { $0.order < $1.order }
        // Text is the deliverable — never changed (O4).
        XCTAssertEqual(sorted.map(\.text), originalTexts)
        XCTAssertEqual(sorted.map(\.text), ["hello world", "goodbye now"])
        // Timings snapped to the reference speech times.
        XCTAssertEqual(sorted[0].start, 0, accuracy: 1e-6)
        XCTAssertEqual(sorted[0].end, 1, accuracy: 1e-6)
        XCTAssertEqual(sorted[1].start, 2, accuracy: 1e-6)
        XCTAssertEqual(sorted[1].end, 3, accuracy: 1e-6)
        // Speakers were assigned against the refined timeline.
        XCTAssertEqual(sorted[0].speakerLabel, "SPEAKER_00")
        XCTAssertEqual(sorted[1].speakerLabel, "SPEAKER_01")
    }

    // MARK: - Gating: an already-refined meeting skips the re-pass

    func testAlreadyRefinedMeetingSkipsRepass() async throws {
        let (service, dir) = try makeStore()
        let meeting = try makeCoarseMeeting(service, dir: dir)
        // A prior final pass / re-pass already refined the timings.
        service.setTimestampsRefined(true, for: meeting)

        let transcriber = SpyTranscriber(result: referenceResult([("hello world", 0, 1), ("goodbye now", 2, 3)]))
        let provider = StubProvider(available: true, segments: [
            SpeakerSegment(start: 0, end: 3, speaker: "SPEAKER_00")
        ])
        let enricher = makeEnricher(service, inspector: monoInspector(), provider: provider, transcriber: transcriber)

        _ = try await enricher.enrich(meeting)

        XCTAssertEqual(transcriber.callCount, 0, "no reference transcription when times are already refined")
        // The coarse times are left exactly as they were (no re-pass ran).
        let sorted = meeting.segments.sorted { $0.order < $1.order }
        XCTAssertEqual(sorted[0].start, 0, accuracy: 1e-9)
        XCTAssertEqual(sorted[0].end, 5, accuracy: 1e-9)
        XCTAssertEqual(sorted[1].start, 5, accuracy: 1e-9)
        XCTAssertEqual(sorted[1].end, 10, accuracy: 1e-9)
    }

    func testRepassDisabledWhenNoTranscriberWired() async throws {
        let (service, dir) = try makeStore()
        let meeting = try makeCoarseMeeting(service, dir: dir)
        let provider = StubProvider(available: true, segments: [SpeakerSegment(start: 0, end: 10, speaker: "SPEAKER_00")])
        // No transcriber → the re-pass cannot run; coarse times survive, meeting stays unrefined.
        let enricher = makeEnricher(service, inspector: monoInspector(), provider: provider, transcriber: nil)

        _ = try await enricher.enrich(meeting)

        XCTAssertNil(meeting.timestampsRefined)
        let sorted = meeting.segments.sorted { $0.order < $1.order }
        XCTAssertEqual(sorted[0].end, 5, accuracy: 1e-9)
        XCTAssertEqual(sorted[1].end, 10, accuracy: 1e-9)
    }

    // MARK: - Dead-end Identify pays nothing for the re-pass (M9-SPK-B minor)

    /// When the provider is unavailable and the recording is mono (not separate-track), `enrich` can
    /// only end in `.unavailable`. The keep-live timing re-pass must be gated *behind* that
    /// short-circuit so a dead-end Identify never pays for a full reference re-transcription.
    func testDeadEndIdentifySkipsTheTimingRepass() async throws {
        let (service, dir) = try makeStore()
        let meeting = try makeCoarseMeeting(service, dir: dir)

        let transcriber = SpyTranscriber(result: referenceResult([("hello world", 0, 1), ("goodbye now", 2, 3)]))
        // No sidecar + a mono recording → the only possible outcome is `.unavailable`.
        let provider = StubProvider(available: false, segments: [])
        let enricher = makeEnricher(service, inspector: monoInspector(), provider: provider, transcriber: transcriber)

        let outcome = try await enricher.enrich(meeting)

        XCTAssertEqual(outcome, .unavailable)
        XCTAssertEqual(transcriber.callCount, 0, "a dead-end Identify must not run a reference transcription")
        XCTAssertNil(meeting.timestampsRefined, "nothing was refined")
        // Coarse times are left exactly as they were.
        let sorted = meeting.segments.sorted { $0.order < $1.order }
        XCTAssertEqual(sorted[0].end, 5, accuracy: 1e-9)
        XCTAssertEqual(sorted[1].end, 10, accuracy: 1e-9)
    }

    // MARK: - Off-main tokenization + transfer helper (M9-SPK-B minor)

    /// The `nonisolated` off-main helper produces the same refined timings the aligner would compute
    /// on-actor, and returns `[]` for an empty reference (so the caller keeps the coarse times).
    func testRefineTimingsOffMainHelperMatchesAligner() async {
        let a = UUID(), b = UUID()
        let live = [
            SpeakerTimingAligner.LiveSegment(id: a, text: "hello world", start: 0, end: 5),
            SpeakerTimingAligner.LiveSegment(id: b, text: "goodbye now", start: 5, end: 10)
        ]

        let refined = await MeetingDiarizationEnricher.refineTimingsOffMain(
            live: live,
            referenceSegments: [("hello world", 0, 1), ("goodbye now", 2, 3)]
        )

        XCTAssertEqual(refined.map(\.id), [a, b], "order preserved, none dropped")
        XCTAssertEqual(refined[0].start, 0, accuracy: 1e-9)
        XCTAssertEqual(refined[0].end, 1, accuracy: 1e-9)
        XCTAssertEqual(refined[1].start, 2, accuracy: 1e-9)
        XCTAssertEqual(refined[1].end, 3, accuracy: 1e-9)

        let none = await MeetingDiarizationEnricher.refineTimingsOffMain(live: live, referenceSegments: [])
        XCTAssertTrue(none.isEmpty, "an empty reference yields no refinement")
    }

    // MARK: - Cancellation mid-re-pass leaves the meeting untouched

    func testCancelledRepassWritesNothing() async throws {
        let (service, dir) = try makeStore()
        let meeting = try makeCoarseMeeting(service, dir: dir)

        // The reference transcription is cancelled — enrich must throw before any write.
        let transcriber = SpyTranscriber(
            result: referenceResult([("hello world", 0, 1)]),
            error: CancellationError()
        )
        let provider = StubProvider(available: true, segments: [SpeakerSegment(start: 0, end: 3, speaker: "SPEAKER_00")])
        let enricher = makeEnricher(service, inspector: monoInspector(), provider: provider, transcriber: transcriber)

        do {
            _ = try await enricher.enrich(meeting)
            XCTFail("expected the cancelled re-pass to throw")
        } catch is CancellationError {
            // expected
        }

        // Nothing was written: times, labels, and the refined flag are all as before.
        XCTAssertNil(meeting.timestampsRefined)
        let sorted = meeting.segments.sorted { $0.order < $1.order }
        XCTAssertEqual(sorted[0].start, 0, accuracy: 1e-9)
        XCTAssertEqual(sorted[0].end, 5, accuracy: 1e-9)
        XCTAssertEqual(sorted[1].start, 5, accuracy: 1e-9)
        XCTAssertEqual(sorted[1].end, 10, accuracy: 1e-9)
        XCTAssertTrue(sorted.allSatisfy { $0.speakerLabel == nil }, "no speakers labeled on a cancelled pass")
    }

    // MARK: - Times-only writer

    func testUpdateSegmentTimingsWritesTimesOnly() throws {
        let (service, dir) = try makeStore()
        let meeting = service.createMeeting(title: "Writer", source: .adHoc, state: .completed)
        service.appendStableSegments([
            TranscriptionSegment(text: "one", start: 0, end: 5, speakerLabel: "A", speakerConfidence: 0.8),
            TranscriptionSegment(text: "two", start: 5, end: 10, speakerLabel: "B", speakerConfidence: 0.9)
        ], to: meeting)
        _ = dir

        let sorted = meeting.segments.sorted { $0.order < $1.order }
        let (id0, id1) = (sorted[0].id, sorted[1].id)
        let orders = sorted.map(\.order)

        service.updateSegmentTimings([(id: id0, start: 0.2, end: 0.9), (id: id1, start: 1.1, end: 1.8)], for: meeting)

        let after = meeting.segments.sorted { $0.order < $1.order }
        // Times updated…
        XCTAssertEqual(after[0].start, 0.2, accuracy: 1e-9)
        XCTAssertEqual(after[0].end, 0.9, accuracy: 1e-9)
        XCTAssertEqual(after[1].start, 1.1, accuracy: 1e-9)
        XCTAssertEqual(after[1].end, 1.8, accuracy: 1e-9)
        // …everything else untouched.
        XCTAssertEqual(after.map(\.text), ["one", "two"])
        XCTAssertEqual(after.map(\.speakerLabel), ["A", "B"])
        XCTAssertEqual(after.map(\.speakerConfidence), [0.8, 0.9])
        XCTAssertEqual(after.map(\.order), orders)
    }

    func testUpdateSegmentTimingsIgnoresUnknownIDs() throws {
        let (service, _) = try makeStore()
        let meeting = service.createMeeting(title: "Writer2", source: .adHoc, state: .completed)
        service.appendStableSegments([TranscriptionSegment(text: "only", start: 0, end: 5)], to: meeting)
        let known = meeting.segments[0].id

        service.updateSegmentTimings([
            (id: UUID(), start: 99, end: 100),   // unknown → ignored
            (id: known, start: 1, end: 2)
        ], for: meeting)

        XCTAssertEqual(meeting.segments[0].start, 1, accuracy: 1e-9)
        XCTAssertEqual(meeting.segments[0].end, 2, accuracy: 1e-9)
        XCTAssertEqual(meeting.segments.count, 1, "no phantom segment created for the unknown id")
    }
}
