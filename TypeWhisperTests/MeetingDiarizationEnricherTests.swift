import XCTest
@testable import TypeWhisper

@MainActor
final class MeetingDiarizationEnricherTests: XCTestCase {

    // MARK: - Stubs

    /// A fakeable diarization provider (no Python sidecar). `Sendable` because the enricher runs
    /// `diarize` off the main actor.
    private struct StubProvider: DiarizationProvider {
        let available: Bool
        let segments: [SpeakerSegment]
        let error: DiarizationError?

        init(available: Bool, segments: [SpeakerSegment] = [], error: DiarizationError? = nil) {
            self.available = available
            self.segments = segments
            self.error = error
        }

        var isAvailable: Bool { get async { available } }

        func diarize(wavData: Data, numSpeakers: Int?) async throws -> [SpeakerSegment] {
            if let error { throw error }
            return segments
        }
    }

    /// A provider whose `diarize` blocks long enough for the test to cancel the job first; the
    /// cancelled sleep throws, so `applySpeakerLabels` never runs. `Sendable` (runs off-main).
    private struct BlockingProvider: DiarizationProvider {
        var isAvailable: Bool { get async { true } }
        func diarize(wavData: Data, numSpeakers: Int?) async throws -> [SpeakerSegment] {
            try await Task.sleep(nanoseconds: 5_000_000_000)
            return [SpeakerSegment(start: 0, end: 5, speaker: "SPEAKER_00")]
        }
    }

    /// Supplies synthetic per-channel audio, bypassing AVFoundation and real files.
    private struct StubInspector: MeetingAudioInspecting {
        let audio: MeetingAudioData

        func channelCount(at url: URL) throws -> Int { audio.channels.count }
        func load(at url: URL) throws -> MeetingAudioData { audio }
    }

    // MARK: - Helpers

    private func makeMeetingWithAudio(
        in dir: URL,
        service: MeetingService,
        segments: [TranscriptionSegment],
        source: MeetingSource = .adHoc
    ) throws -> Meeting {
        let meeting = service.createMeeting(title: "Standup", source: source, state: .completed)
        service.appendStableSegments(segments, to: meeting)
        // Give the meeting a stored audio file so `audioFileURL` is non-nil (content is irrelevant —
        // the audio inspector is stubbed). `adoptAudioFile` moves the source into meetings-audio/.
        let source = dir.appendingPathComponent("src.wav")
        try Data("audio".utf8).write(to: source)
        service.adoptAudioFile(source, for: meeting)
        return meeting
    }

    /// A mono recording whose duration comfortably covers the test transcripts (so the enricher's
    /// timeline sanity-check — segment extent vs. audio duration — passes). Content is silence; the
    /// mono path only feeds it to the (stubbed) provider.
    private func monoInspector(seconds: Double = 30) -> StubInspector {
        let sampleRate = 16_000
        let frames = Int(seconds * Double(sampleRate))
        return StubInspector(audio: MeetingAudioData(channels: [[Float](repeating: 0, count: frames)], sampleRate: Double(sampleRate)))
    }

    // MARK: - Pure overlap assignment (via assignSpeakers)

    func testOverlapAssignmentMapsDiarizationTurnsOntoSegments() {
        let a = UUID(), b = UUID(), c = UUID()
        let ranges: [(id: UUID, start: Double, end: Double)] = [
            (a, 0, 5),
            (b, 5, 10),
            (c, 10, 15)
        ]
        let diar = [
            SpeakerSegment(start: 0, end: 5, speaker: "SPEAKER_00"),
            SpeakerSegment(start: 5, end: 15, speaker: "SPEAKER_01")
        ]

        let assignments = MeetingDiarizationEnricher.assign(ranges: ranges, from: diar)

        XCTAssertEqual(assignments.count, 3)
        XCTAssertEqual(assignments.first { $0.segmentID == a }?.label, "SPEAKER_00")
        XCTAssertEqual(assignments.first { $0.segmentID == b }?.label, "SPEAKER_01")
        XCTAssertEqual(assignments.first { $0.segmentID == c }?.label, "SPEAKER_01")
    }

    func testSegmentWithNoOverlapGetsNoAssignment() {
        let a = UUID()
        let assignments = MeetingDiarizationEnricher.assign(
            ranges: [(a, 100, 110)],
            from: [SpeakerSegment(start: 0, end: 5, speaker: "SPEAKER_00")]
        )
        XCTAssertTrue(assignments.isEmpty)
    }

    // MARK: - Provider path

    func testEnrichLabelsSegmentsViaProvider() async throws {
        let dir = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(dir) }
        let service = MeetingService(appSupportDirectory: dir)

        let meeting = try makeMeetingWithAudio(in: dir, service: service, segments: [
            TranscriptionSegment(text: "Hello there.", start: 0, end: 5),
            TranscriptionSegment(text: "General Kenobi.", start: 5, end: 10)
        ])

        let provider = StubProvider(available: true, segments: [
            SpeakerSegment(start: 0, end: 5, speaker: "SPEAKER_00"),
            SpeakerSegment(start: 5, end: 10, speaker: "SPEAKER_01")
        ])
        let enricher = MeetingDiarizationEnricher(
            meetingService: service,
            provider: provider,
            audioInspector: monoInspector(),
            numSpeakersProvider: { nil }
        )

        let outcome = try await enricher.enrich(meeting)

        XCTAssertEqual(outcome, .labeled(speakerCount: 2))
        let sorted = meeting.segments.sorted { $0.order < $1.order }
        XCTAssertEqual(sorted.map(\.speakerLabel), ["SPEAKER_00", "SPEAKER_01"])
        XCTAssertTrue(sorted.allSatisfy { ($0.speakerConfidence ?? 0) > 0 })
    }

    // MARK: - [Track J] Diarization routed through the job queue

    private func waitUntil(_ condition: @escaping () -> Bool) async {
        var iterations = 0
        while !condition() {
            if iterations > 100_000 { XCTFail("condition never met"); return }
            await Task.yield()
            iterations += 1
        }
    }

    /// Routed as a `.diarization` job (the shape `MeetingsViewModel.identifySpeakers` uses): the job is
    /// meeting-scoped (what `isEnriching(for:)` reads), and cancelling it writes no labels —
    /// `applySpeakerLabels` runs only after `diarize` returns.
    func testCancelledDiarizationJobWritesNoLabelsAndIsMeetingScoped() async throws {
        let dir = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(dir) }
        let service = MeetingService(appSupportDirectory: dir)

        let meeting = try makeMeetingWithAudio(in: dir, service: service, segments: [
            TranscriptionSegment(text: "Hello there.", start: 0, end: 5)
        ])
        let other = service.createMeeting(title: "Other", source: .adHoc, state: .completed)
        let enricher = MeetingDiarizationEnricher(
            meetingService: service,
            provider: BlockingProvider(),
            audioInspector: monoInspector(),
            numSpeakersProvider: { nil }
        )
        let queue = JobQueueService()

        let id = queue.enqueue(kind: .diarization, meetingID: meeting.id) { [weak enricher] in
            _ = try await enricher?.enrich(meeting)
        }
        // Meeting-scoped: active for this meeting, not another.
        XCTAssertTrue(queue.hasActiveJob(kind: .diarization, meetingID: meeting.id))
        XCTAssertFalse(queue.hasActiveJob(kind: .diarization, meetingID: other.id))

        await waitUntil { queue.jobs.first { $0.id == id }?.state == .running }
        queue.cancel(id)
        await queue.drain()

        XCTAssertTrue(meeting.segments.allSatisfy { $0.speakerLabel == nil }, "cancelled diarization writes no labels")
        XCTAssertEqual(queue.jobs.first { $0.id == id }?.state, .cancelled)
    }

    func testZeroLabelResultYieldsNoSpeakersDetectedAndDoesNotCrash() async throws {
        let dir = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(dir) }
        let service = MeetingService(appSupportDirectory: dir)

        let meeting = try makeMeetingWithAudio(in: dir, service: service, segments: [
            TranscriptionSegment(text: "Anyone there?", start: 0, end: 5)
        ])

        // Provider is available but returns no speaker turns.
        let enricher = MeetingDiarizationEnricher(
            meetingService: service,
            provider: StubProvider(available: true, segments: []),
            audioInspector: monoInspector(),
            numSpeakersProvider: { nil }
        )

        let outcome = try await enricher.enrich(meeting)

        XCTAssertEqual(outcome, .noSpeakersDetected)
        XCTAssertTrue(meeting.segments.allSatisfy { $0.speakerLabel == nil })
    }

    func testUnavailableProviderIsANoOp() async throws {
        let dir = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(dir) }
        let service = MeetingService(appSupportDirectory: dir)

        let meeting = try makeMeetingWithAudio(in: dir, service: service, segments: [
            TranscriptionSegment(text: "Solo talk.", start: 0, end: 5)
        ])

        let enricher = MeetingDiarizationEnricher(
            meetingService: service,
            provider: StubProvider(available: false),
            audioInspector: monoInspector(),
            numSpeakersProvider: { nil }
        )

        let availability = await enricher.availability(for: meeting)
        XCTAssertEqual(availability, .unavailable)

        let outcome = try await enricher.enrich(meeting)
        XCTAssertEqual(outcome, .unavailable)
        XCTAssertTrue(meeting.segments.allSatisfy { $0.speakerLabel == nil })
    }

    func testProviderFailureThrowsExplicitly() async throws {
        let dir = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(dir) }
        let service = MeetingService(appSupportDirectory: dir)

        let meeting = try makeMeetingWithAudio(in: dir, service: service, segments: [
            TranscriptionSegment(text: "Broken.", start: 0, end: 5)
        ])

        let enricher = MeetingDiarizationEnricher(
            meetingService: service,
            provider: StubProvider(available: true, error: .pythonError("boom")),
            audioInspector: monoInspector(),
            numSpeakersProvider: { nil }
        )

        do {
            _ = try await enricher.enrich(meeting)
            XCTFail("Expected providerFailed to be surfaced explicitly (plan D8)")
        } catch let error as MeetingDiarizationEnricher.EnrichError {
            guard case .providerFailed = error else {
                return XCTFail("Expected .providerFailed, got \(error)")
            }
        }
    }

    // MARK: - Separate-track heuristic

    func testSeparateTrackHeuristicLabelsMeAndOthersAndSeedsMap() async throws {
        let dir = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(dir) }
        let service = MeetingService(appSupportDirectory: dir)

        let meeting = try makeMeetingWithAudio(in: dir, service: service, segments: [
            TranscriptionSegment(text: "I speak first.", start: 0, end: 1),
            TranscriptionSegment(text: "They reply.", start: 1, end: 2)
        ])

        // Two channels: mic (L) loud in [0,1)s, system (R) loud in [1,2)s.
        let sr = 16_000
        var mic = [Float](repeating: 0, count: sr * 2)
        var system = [Float](repeating: 0, count: sr * 2)
        for i in 0..<sr { mic[i] = 0.5 }               // mic loud during segment 0
        for i in sr..<(sr * 2) { system[i] = 0.5 }     // system loud during segment 1
        let inspector = StubInspector(audio: MeetingAudioData(channels: [mic, system], sampleRate: Double(sr)))

        // Provider deliberately unavailable — the heuristic needs no sidecar.
        let enricher = MeetingDiarizationEnricher(
            meetingService: service,
            provider: StubProvider(available: false),
            audioInspector: inspector,
            numSpeakersProvider: { nil }
        )

        // Separate-track recording is offered even without the sidecar.
        let availability = await enricher.availability(for: meeting)
        XCTAssertEqual(availability, .separateTrack)

        let outcome = try await enricher.enrich(meeting)
        XCTAssertEqual(outcome, .labeled(speakerCount: 2))

        let sorted = meeting.segments.sorted { $0.order < $1.order }
        XCTAssertEqual(sorted[0].speakerLabel, MeetingDiarizationEnricher.micSpeakerLabel)
        XCTAssertEqual(sorted[1].speakerLabel, MeetingDiarizationEnricher.systemSpeakerLabel)

        // The map is seeded with localized default names.
        XCTAssertEqual(meeting.speakerMap[MeetingDiarizationEnricher.micSpeakerLabel],
                       String(localized: "meetings.diarization.speaker.me"))
        XCTAssertEqual(meeting.speakerMap[MeetingDiarizationEnricher.systemSpeakerLabel],
                       String(localized: "meetings.diarization.speaker.others"))
    }

    /// A mixed-mode 2-channel recording (both channels carry the *same* mic+system mix, as the
    /// recorder writes for `.mixed` track mode) must NOT be treated as separate tracks: the Me/Others
    /// heuristic would tie every segment to "Me". It falls through to the sidecar path instead, so an
    /// unavailable provider yields a clean `.unavailable` rather than bogus labels.
    func testMixedModeStereoIsNotSeparateTrackAndFallsBackToProvider() async throws {
        let dir = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(dir) }
        let service = MeetingService(appSupportDirectory: dir)

        let meeting = try makeMeetingWithAudio(in: dir, service: service, segments: [
            TranscriptionSegment(text: "First.", start: 0, end: 1),
            TranscriptionSegment(text: "Second.", start: 1, end: 2)
        ])

        // Two *identical* channels (mixed mode duplicates the same mix into L and R).
        let sr = 16_000
        let mix = [Float](repeating: 0.5, count: sr * 2)
        let inspector = StubInspector(audio: MeetingAudioData(channels: [mix, mix], sampleRate: Double(sr)))

        let enricher = MeetingDiarizationEnricher(
            meetingService: service,
            provider: StubProvider(available: false),
            audioInspector: inspector,
            numSpeakersProvider: { nil }
        )

        let outcome = try await enricher.enrich(meeting)
        XCTAssertEqual(outcome, .unavailable)
        // Crucially, no segment was mislabeled "Me".
        XCTAssertTrue(meeting.segments.allSatisfy { $0.speakerLabel == nil })
    }

    /// Mixed mode with sustained *stereo* system content (shared video/music, stereo conferencing
    /// output): the recorder writes L = mic + sysL, R = mic + sysR. Model it as L = m + s, R = m − s
    /// with |s| = 0.2|m| — normalized inter-channel difference energy is only ~0.08, well below the
    /// separate-track threshold. It must take the mono/provider path, never Me/Others; without a
    /// sidecar it resolves to a clean `.unavailable` rather than pinning near-arbitrary labels.
    func testStereoSystemContentInMixedCaptureIsNotSeparateTrack() async throws {
        let dir = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(dir) }
        let service = MeetingService(appSupportDirectory: dir)

        let meeting = try makeMeetingWithAudio(in: dir, service: service, segments: [
            TranscriptionSegment(text: "First.", start: 0, end: 1),
            TranscriptionSegment(text: "Second.", start: 1, end: 2)
        ])

        let sr = 16_000
        let m: Float = 0.5, s: Float = 0.1 // |s| = 0.2|m| → ~7% side amplitude, realistic stereo width
        let left = [Float](repeating: m + s, count: sr * 2)
        let right = [Float](repeating: m - s, count: sr * 2)
        let inspector = StubInspector(audio: MeetingAudioData(channels: [left, right], sampleRate: Double(sr)))

        let enricher = MeetingDiarizationEnricher(
            meetingService: service,
            provider: StubProvider(available: false),
            audioInspector: inspector,
            numSpeakersProvider: { nil }
        )

        let outcome = try await enricher.enrich(meeting)
        XCTAssertEqual(outcome, .unavailable)
        XCTAssertTrue(meeting.segments.allSatisfy { $0.speakerLabel == nil })
    }

    /// A mixed-mode stereo recording still diarizes correctly via the sidecar (downmixed to mono).
    func testMixedModeStereoLabelsViaProviderWhenAvailable() async throws {
        let dir = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(dir) }
        let service = MeetingService(appSupportDirectory: dir)

        let meeting = try makeMeetingWithAudio(in: dir, service: service, segments: [
            TranscriptionSegment(text: "First.", start: 0, end: 1),
            TranscriptionSegment(text: "Second.", start: 1, end: 2)
        ])

        let sr = 16_000
        let mix = [Float](repeating: 0.5, count: sr * 2)
        let inspector = StubInspector(audio: MeetingAudioData(channels: [mix, mix], sampleRate: Double(sr)))

        let enricher = MeetingDiarizationEnricher(
            meetingService: service,
            provider: StubProvider(available: true, segments: [
                SpeakerSegment(start: 0, end: 1, speaker: "SPEAKER_00"),
                SpeakerSegment(start: 1, end: 2, speaker: "SPEAKER_01")
            ]),
            audioInspector: inspector,
            numSpeakersProvider: { nil }
        )

        let outcome = try await enricher.enrich(meeting)
        XCTAssertEqual(outcome, .labeled(speakerCount: 2))
        let sorted = meeting.segments.sorted { $0.order < $1.order }
        XCTAssertEqual(sorted.map(\.speakerLabel), ["SPEAKER_00", "SPEAKER_01"])
    }

    /// Imported stereo audio (M8) is never separate-track even when its channels are decorrelated:
    /// it takes the sidecar path, so availability gates on the provider and it never gets Me/Others.
    func testImportedStereoUsesProviderNotSeparateTrackHeuristic() async throws {
        let dir = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(dir) }
        let service = MeetingService(appSupportDirectory: dir)

        let meeting = try makeMeetingWithAudio(
            in: dir,
            service: service,
            segments: [
                TranscriptionSegment(text: "Left.", start: 0, end: 1),
                TranscriptionSegment(text: "Right.", start: 1, end: 2)
            ],
            source: .importedAudio
        )

        // Genuinely decorrelated channels — yet an imported file must not use the heuristic.
        let sr = 16_000
        var left = [Float](repeating: 0, count: sr * 2)
        var right = [Float](repeating: 0, count: sr * 2)
        for i in 0..<sr { left[i] = 0.5 }
        for i in sr..<(sr * 2) { right[i] = 0.5 }
        let inspector = StubInspector(audio: MeetingAudioData(channels: [left, right], sampleRate: Double(sr)))

        // Provider unavailable → availability is `.provider`-gated, not `.separateTrack`.
        let unavailableEnricher = MeetingDiarizationEnricher(
            meetingService: service,
            provider: StubProvider(available: false),
            audioInspector: inspector,
            numSpeakersProvider: { nil }
        )
        let availability = await unavailableEnricher.availability(for: meeting)
        XCTAssertEqual(availability, .unavailable)
        let unavailableOutcome = try await unavailableEnricher.enrich(meeting)
        XCTAssertEqual(unavailableOutcome, .unavailable)
        XCTAssertTrue(meeting.segments.allSatisfy { $0.speakerLabel == nil })

        // With the sidecar available it labels via SPEAKER_xx, never Me/Others.
        let providerEnricher = MeetingDiarizationEnricher(
            meetingService: service,
            provider: StubProvider(available: true, segments: [
                SpeakerSegment(start: 0, end: 2, speaker: "SPEAKER_00")
            ]),
            audioInspector: inspector,
            numSpeakersProvider: { nil }
        )
        let providerOutcome = try await providerEnricher.enrich(meeting)
        XCTAssertEqual(providerOutcome, .labeled(speakerCount: 1))
        XCTAssertTrue(meeting.segments.allSatisfy { $0.speakerLabel == "SPEAKER_00" })
    }

    /// When the transcript timeline runs far past the stored audio (restarted-session or merged
    /// flows point `audioFileName` at a shorter, differently-based file), enrichment refuses to
    /// label rather than attach wrong speakers.
    func testTimelineMismatchReturnsSafeOutcomeWithoutLabeling() async throws {
        let dir = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(dir) }
        let service = MeetingService(appSupportDirectory: dir)

        let meeting = try makeMeetingWithAudio(in: dir, service: service, segments: [
            // Segment sits ~1000 s into a nominal timeline, but the audio is only ~2 s long.
            TranscriptionSegment(text: "Way past the audio.", start: 1000, end: 1005)
        ])

        let enricher = MeetingDiarizationEnricher(
            meetingService: service,
            provider: StubProvider(available: true, segments: [SpeakerSegment(start: 1000, end: 1005, speaker: "SPEAKER_00")]),
            audioInspector: monoInspector(seconds: 2),
            numSpeakersProvider: { nil }
        )

        let outcome = try await enricher.enrich(meeting)
        XCTAssertEqual(outcome, .timelineMismatch)
        XCTAssertTrue(meeting.segments.allSatisfy { $0.speakerLabel == nil })
    }

    // MARK: - [M1/D1] Availability shares the run's decorrelation evidence

    /// A helper live meeting whose audio duration comfortably covers a short transcript, so the probe
    /// (and any later whole-file check) sees the synthesized channels rather than tripping the timeline
    /// guard.
    private func liveMeetingForAvailability(in dir: URL, service: MeetingService) throws -> Meeting {
        try makeMeetingWithAudio(in: dir, service: service, segments: [
            TranscriptionSegment(text: "One.", start: 0, end: 1),
            TranscriptionSegment(text: "Two.", start: 1, end: 2)
        ], source: .adHoc)
    }

    /// The owner's-screenshot defect: a live 2-channel capture whose channels are *correlated* (mixed
    /// mode — both channels carry the same mic+system mix) must NOT be reported `.separateTrack` from a
    /// bare channel-count probe. The prefix decorrelation probe downgrades it to the sidecar-dependent
    /// path, so with no sidecar it is honestly `.unavailable` (no false channel caption / Redo).
    func testMixedCorrelatedCaptureAvailabilityDowngradesToUnavailableWithoutSidecar() async throws {
        let dir = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(dir) }
        let service = MeetingService(appSupportDirectory: dir)
        let meeting = try liveMeetingForAvailability(in: dir, service: service)

        // Identical, non-silent channels → confidently correlated head.
        let sr = 16_000
        let mix = [Float](repeating: 0.5, count: sr * 2)
        let inspector = StubInspector(audio: MeetingAudioData(channels: [mix, mix], sampleRate: Double(sr)))

        let enricher = MeetingDiarizationEnricher(
            meetingService: service,
            provider: StubProvider(available: false),
            audioInspector: inspector,
            numSpeakersProvider: { nil }
        )

        let availability = await enricher.availability(for: meeting)
        XCTAssertEqual(availability, .unavailable, "a correlated (mixed) capture is not separate-track")
    }

    /// Same correlated capture, but with the sidecar available → the availability is `.provider`, not
    /// `.separateTrack`: the mixed recording can be diarized by pyannote, never by the channel path.
    func testMixedCorrelatedCaptureAvailabilityIsProviderWhenSidecarAvailable() async throws {
        let dir = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(dir) }
        let service = MeetingService(appSupportDirectory: dir)
        let meeting = try liveMeetingForAvailability(in: dir, service: service)

        let sr = 16_000
        let mix = [Float](repeating: 0.5, count: sr * 2)
        let inspector = StubInspector(audio: MeetingAudioData(channels: [mix, mix], sampleRate: Double(sr)))

        let enricher = MeetingDiarizationEnricher(
            meetingService: service,
            provider: StubProvider(available: true),
            audioInspector: inspector,
            numSpeakersProvider: { nil }
        )

        let availability = await enricher.availability(for: meeting)
        XCTAssertEqual(availability, .provider)
    }

    /// A genuinely decorrelated (separate mic/system) head keeps `.separateTrack` even with no
    /// sidecar — the content gate admits real separate tracks, it only rejects correlated ones.
    func testDecorrelatedCaptureAvailabilityStaysSeparateTrack() async throws {
        let dir = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(dir) }
        let service = MeetingService(appSupportDirectory: dir)
        let meeting = try liveMeetingForAvailability(in: dir, service: service)

        // Mic loud in [0,1)s, system loud in [1,2)s → normalized difference energy ~1.0.
        let sr = 16_000
        var mic = [Float](repeating: 0, count: sr * 2)
        var system = [Float](repeating: 0, count: sr * 2)
        for i in 0..<sr { mic[i] = 0.5 }
        for i in sr..<(sr * 2) { system[i] = 0.5 }
        let inspector = StubInspector(audio: MeetingAudioData(channels: [mic, system], sampleRate: Double(sr)))

        let enricher = MeetingDiarizationEnricher(
            meetingService: service,
            provider: StubProvider(available: false),
            audioInspector: inspector,
            numSpeakersProvider: { nil }
        )

        let availability = await enricher.availability(for: meeting)
        XCTAssertEqual(availability, .separateTrack)
    }

    /// A silent 2-channel head is *inconclusive* (a separate-track recording may simply open with
    /// silence), so availability must not downgrade on it — it keeps `.separateTrack` and defers the
    /// authoritative decision to the whole-file check in `enrich`.
    func testSilentPrefixKeepsSeparateTrackAvailability() async throws {
        let dir = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(dir) }
        let service = MeetingService(appSupportDirectory: dir)
        let meeting = try liveMeetingForAvailability(in: dir, service: service)

        // Two silent channels → no energy → confidently-correlated probe returns false (inconclusive).
        let sr = 16_000
        let silence = [Float](repeating: 0, count: sr * 2)
        let inspector = StubInspector(audio: MeetingAudioData(channels: [silence, silence], sampleRate: Double(sr)))

        let enricher = MeetingDiarizationEnricher(
            meetingService: service,
            provider: StubProvider(available: false),
            audioInspector: inspector,
            numSpeakersProvider: { nil }
        )

        let availability = await enricher.availability(for: meeting)
        XCTAssertEqual(availability, .separateTrack)
    }

    // MARK: - Map persistence & rendering

    func testSpeakerMapPersistsAcrossServiceInstancesAndRenders() throws {
        let dir = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(dir) }

        let service = MeetingService(appSupportDirectory: dir)
        let meeting = service.createMeeting(title: "Sync", source: .adHoc, state: .completed)
        service.appendStableSegments(
            [TranscriptionSegment(text: "Decision made.", start: 0, end: 4, speakerLabel: "SPEAKER_00", speakerConfidence: 0.9)],
            to: meeting
        )
        let meetingID = meeting.id

        // Persist a mapping; blank names are dropped.
        service.setSpeakerMap(["SPEAKER_00": "Marco", "SPEAKER_01": "  "], for: meeting)
        XCTAssertEqual(meeting.speakerMap, ["SPEAKER_00": "Marco"])

        // Reload from a fresh service instance on the same directory.
        let reopened = MeetingService(appSupportDirectory: dir)
        let refetched = try XCTUnwrap(reopened.meetings.first { $0.id == meetingID })
        XCTAssertEqual(refetched.speakerMap, ["SPEAKER_00": "Marco"])

        // Rendering resolves the mapped name; an unmapped label falls back to itself.
        let segment = try XCTUnwrap(refetched.segments.first)
        XCTAssertEqual(MeetingTranscriptPanel.speakerName(for: segment, speakerMap: refetched.speakerMap), "Marco")
        XCTAssertEqual(MeetingTranscriptPanel.speakerName(for: segment, speakerMap: [:]), "SPEAKER_00")
    }

    // MARK: - Guards

    func testNoTranscriptShortCircuits() async throws {
        let dir = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(dir) }
        let service = MeetingService(appSupportDirectory: dir)
        let meeting = service.createMeeting(title: "Empty", source: .adHoc, state: .completed)

        let enricher = MeetingDiarizationEnricher(
            meetingService: service,
            provider: StubProvider(available: true, segments: [SpeakerSegment(start: 0, end: 1, speaker: "SPEAKER_00")]),
            audioInspector: monoInspector(),
            numSpeakersProvider: { nil }
        )
        let outcome = try await enricher.enrich(meeting)
        XCTAssertEqual(outcome, .noTranscript)
    }

    func testNoAudioShortCircuits() async throws {
        let dir = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(dir) }
        let service = MeetingService(appSupportDirectory: dir)
        let meeting = service.createMeeting(title: "No audio", source: .adHoc, state: .completed)
        service.appendStableSegments([TranscriptionSegment(text: "Hi.", start: 0, end: 2)], to: meeting)

        let enricher = MeetingDiarizationEnricher(
            meetingService: service,
            provider: StubProvider(available: true, segments: [SpeakerSegment(start: 0, end: 1, speaker: "SPEAKER_00")]),
            audioInspector: monoInspector(),
            numSpeakersProvider: { nil }
        )
        let outcome = try await enricher.enrich(meeting)
        XCTAssertEqual(outcome, .noAudio)
    }
}
