import XCTest
@testable import TypeWhisper

/// [M5/D10] One-shot speaker-capable cloud re-transcription for the Identify split menu. Hermetic: a
/// stub transcriber (records the engine override and returns labeled segments), synthetic mono audio via
/// a stub inspector, no sidecar/plugin graph. Covers: the rerun re-transcribes through the chosen engine
/// and its provider labels are adopted via the existing `preferProviderLabels` path (resolving `.cloud`),
/// a label-less result is surfaced honestly (nothing clobbered), the transcription-lane invariant, and
/// the pure "menu collapses without a capable engine" classifier.
@MainActor
final class MeetingSpeakerCloudRerunTests: XCTestCase {

    // MARK: - Stubs

    /// Synthetic mono audio so `loadMonoSamples` yields a non-empty buffer for the re-transcription.
    private struct MonoInspector: MeetingAudioInspecting {
        let audio: MeetingAudioData
        func channelCount(at url: URL) throws -> Int { audio.channels.count }
        func load(at url: URL) throws -> MeetingAudioData { audio }
    }

    /// Records the engine override it was asked to run and returns a canned result. Implements the
    /// engine-override method directly so the override is observable.
    private final class SpyCloudTranscriber: MeetingAudioTranscribing {
        private(set) var engineOverrideIds: [String?] = []
        var result: TranscriptionResult
        init(result: TranscriptionResult) { self.result = result }

        func transcribeImportedAudio(samples: [Float], languageSelection: LanguageSelection) async throws -> TranscriptionResult {
            result
        }
        func transcribeMeetingAudio(
            samples: [Float],
            languageSelection: LanguageSelection,
            engineOverrideId: String?,
            cloudModelOverride: String?
        ) async throws -> TranscriptionResult {
            engineOverrideIds.append(engineOverrideId)
            return result
        }
    }

    private struct StubProvider: DiarizationProvider {
        var isAvailable: Bool { get async { false } }
        func diarize(wavData: Data, numSpeakers: Int?) async throws -> [SpeakerSegment] { [] }
    }

    // MARK: - Helpers

    private func makeStore() throws -> (MeetingService, URL) {
        let dir = try TestSupport.makeTemporaryDirectory(prefix: "CloudRerun")
        addTeardownBlock { TestSupport.remove(dir) }
        return (MeetingService(appSupportDirectory: dir), dir)
    }

    private func monoInspector(seconds: Int = 10) -> MonoInspector {
        let sr = 16_000
        let mono = [Float](repeating: 0.1, count: sr * seconds)
        return MonoInspector(audio: MeetingAudioData(channels: [mono], sampleRate: Double(sr)))
    }

    private func result(_ segments: [(String, Double, Double, String?)]) -> TranscriptionResult {
        TranscriptionResult(
            text: segments.map(\.0).joined(separator: " "),
            detectedLanguage: nil,
            duration: 0,
            processingTime: 0,
            engineUsed: "assemblyai",
            segments: segments.map { TranscriptionSegment(text: $0.0, start: $0.1, end: $0.2, speakerLabel: $0.3) }
        )
    }

    private func makeMeeting(_ service: MeetingService, dir: URL) throws -> Meeting {
        let meeting = service.createMeeting(title: "Call", source: .adHoc, state: .completed)
        service.appendStableSegments([
            TranscriptionSegment(text: "hello", start: 0, end: 5),
            TranscriptionSegment(text: "hi there", start: 5, end: 10)
        ], to: meeting)
        let src = dir.appendingPathComponent("src-\(UUID().uuidString).wav")
        try Data("audio".utf8).write(to: src)
        service.adoptAudioFile(src, for: meeting)
        return meeting
    }

    private func makeEnricher(
        _ service: MeetingService,
        transcriber: MeetingAudioTranscribing?
    ) -> MeetingDiarizationEnricher {
        MeetingDiarizationEnricher(
            meetingService: service,
            provider: StubProvider(),
            audioInspector: monoInspector(),
            numSpeakersProvider: { nil },
            transcriber: transcriber
        )
    }

    // MARK: - Cloud rerun adopts provider labels

    func testCloudRerunAdoptsProviderLabelsAndResolvesCloud() async throws {
        let (service, dir) = try makeStore()
        let meeting = try makeMeeting(service, dir: dir)
        let transcriber = SpyCloudTranscriber(result: result([
            ("hello", 0, 5, "Speaker A"),
            ("hi there", 5, 10, "Speaker B")
        ]))
        let enricher = makeEnricher(service, transcriber: transcriber)

        let outcome = await enricher.rerunCloudSpeakers(meeting, engineId: "assemblyai", model: "best")

        XCTAssertEqual(outcome, .labeled(speakerCount: 2))
        // The chosen speaker-capable engine actually ran.
        XCTAssertEqual(transcriber.engineOverrideIds, ["assemblyai"])
        // The transcript now carries the provider labels…
        let labels = Set(meeting.segments.compactMap { $0.speakerLabel })
        XCTAssertEqual(labels, ["Speaker A", "Speaker B"])
        // …recognized as provider-originated, so the finalization adoption path adopts them (resolves
        // `.cloud`) through the existing `preferProviderLabels` seam — no local pass.
        XCTAssertTrue(enricher.hasProviderSpeakerLabels(meeting))
        let adopted = await enricher.autoAssignSpeakers(for: meeting, preferProviderLabels: true)
        XCTAssertEqual(adopted, .cloud)
    }

    func testCloudRerunWithoutLabelsReportsNoSpeakersAndKeepsTranscript() async throws {
        let (service, dir) = try makeStore()
        let meeting = try makeMeeting(service, dir: dir)
        let originalTexts = meeting.segments.sorted { $0.order < $1.order }.map(\.text)
        // The engine returned a transcript but no speaker labels (its speaker option was off).
        let transcriber = SpyCloudTranscriber(result: result([
            ("re-transcribed a", 0, 5, nil),
            ("re-transcribed b", 5, 10, nil)
        ]))
        let enricher = makeEnricher(service, transcriber: transcriber)

        let outcome = await enricher.rerunCloudSpeakers(meeting, engineId: "assemblyai", model: nil)

        XCTAssertEqual(outcome, .noSpeakersDetected)
        // The existing transcript is untouched — no clobber for a label-less result.
        XCTAssertEqual(meeting.segments.sorted { $0.order < $1.order }.map(\.text), originalTexts)
        XCTAssertFalse(enricher.hasProviderSpeakerLabels(meeting))
    }

    func testCloudRerunWithoutTranscriberIsUnavailable() async throws {
        let (service, dir) = try makeStore()
        let meeting = try makeMeeting(service, dir: dir)
        let enricher = makeEnricher(service, transcriber: nil)

        let outcome = await enricher.rerunCloudSpeakers(meeting, engineId: "assemblyai", model: nil)
        XCTAssertEqual(outcome, .unavailable)
    }

    // MARK: - Transcription-lane invariant

    /// The VM enqueues the cloud rerun with the `.diarization` kind; that kind runs on the cap-1
    /// `transcription` lane, so the rerun serializes with a meeting's other audio work (plan J2).
    func testCloudRerunKindRunsOnTranscriptionLane() {
        XCTAssertEqual(MeetingJobKind.diarization.lane, .transcription)
    }

    // MARK: - Menu-collapse classifier (speaker-capable cloud engines)

    private func descriptor(_ id: String, structured: Bool, configured: Bool) -> MeetingsViewModel.SpeakerEngineDescriptor {
        MeetingsViewModel.SpeakerEngineDescriptor(id: id, name: id.capitalized, isStructured: structured, isConfigured: configured)
    }

    func testNoCapableEngineCollapsesToEmpty() {
        // No engines at all, and engines that either can't return speaker labels or aren't configured →
        // the menu collapses to plain local Identify (empty option list).
        XCTAssertTrue(MeetingsViewModel.speakerCapableCloudEngineOptions(from: []).isEmpty)
        let notCapable = [
            descriptor("whisperkit", structured: false, configured: true),
            descriptor("assemblyai", structured: true, configured: false)
        ]
        XCTAssertTrue(MeetingsViewModel.speakerCapableCloudEngineOptions(from: notCapable).isEmpty)
    }

    func testStructuredConfiguredEnginesAreOffered() {
        let descriptors = [
            descriptor("whisperkit", structured: false, configured: true),
            descriptor("assemblyai", structured: true, configured: true),
            descriptor("otherstructured", structured: true, configured: true)
        ]
        let options = MeetingsViewModel.speakerCapableCloudEngineOptions(from: descriptors)
        XCTAssertEqual(options.map(\.id), ["assemblyai", "otherstructured"])
        XCTAssertEqual(options.first?.name, "Assemblyai")
    }
}
