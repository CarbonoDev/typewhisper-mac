import XCTest
@testable import TypeWhisper

/// Speaker-recognition amendment (M9-SPK-A) — the automatic two-person channel fast path and cloud
/// adoption, driven through the enricher's *automatic finalization entry* (`autoAssignSpeakers` /
/// `autoLabelTwoPersonChannel`) rather than the manual Identify button. Hermetic: synthetic
/// per-channel audio via a stub inspector, no sidecar, no AVFoundation.
@MainActor
final class MeetingTwoPersonSpeakerTests: XCTestCase {

    /// Supplies synthetic per-channel audio, bypassing AVFoundation and real files.
    private struct StubInspector: MeetingAudioInspecting {
        let audio: MeetingAudioData
        func channelCount(at url: URL) throws -> Int { audio.channels.count }
        func load(at url: URL) throws -> MeetingAudioData { audio }
    }

    private struct StubProvider: DiarizationProvider {
        let available: Bool
        var isAvailable: Bool { get async { available } }
        func diarize(wavData: Data, numSpeakers: Int?) async throws -> [SpeakerSegment] { [] }
    }

    private func makeStore() throws -> (MeetingService, URL) {
        let dir = try TestSupport.makeTemporaryDirectory(prefix: "TwoPerson")
        addTeardownBlock { TestSupport.remove(dir) }
        return (MeetingService(appSupportDirectory: dir), dir)
    }

    private func giveAudio(_ meeting: Meeting, service: MeetingService, dir: URL) throws {
        let source = dir.appendingPathComponent("src-\(UUID().uuidString).wav")
        try Data("audio".utf8).write(to: source)
        service.adoptAudioFile(source, for: meeting)
    }

    /// Two channels: mic (L) loud in [0,1)s, system (R) loud in [1,2)s — genuinely decorrelated.
    private func separateStereo(seconds: Int = 2) -> StubInspector {
        let sr = 16_000
        var mic = [Float](repeating: 0, count: sr * seconds)
        var system = [Float](repeating: 0, count: sr * seconds)
        for i in 0..<sr { mic[i] = 0.5 }
        for i in sr..<(sr * seconds) { system[i] = 0.5 }
        return StubInspector(audio: MeetingAudioData(channels: [mic, system], sampleRate: Double(sr)))
    }

    private func enricher(_ service: MeetingService, inspector: StubInspector, providerAvailable: Bool = false) -> MeetingDiarizationEnricher {
        MeetingDiarizationEnricher(
            meetingService: service,
            provider: StubProvider(available: providerAvailable),
            audioInspector: inspector,
            numSpeakersProvider: { nil }
        )
    }

    // MARK: - Channel labeling on synthetic stereo, via the automatic entry (D-A4/D-A8)

    func testAutoAssignLabelsTwoPersonCallByChannelAndNamesOtherFromAttendee() async throws {
        let (service, dir) = try makeStore()
        let meeting = service.createMeeting(
            title: "1:1", source: .adHoc, state: .completed,
            attendees: [Attendee(name: "Marco", email: "m@x", isSelf: true), Attendee(name: "Alex", email: "a@x")]
        )
        service.appendStableSegments([
            TranscriptionSegment(text: "I speak first.", start: 0, end: 1),
            TranscriptionSegment(text: "They reply.", start: 1, end: 2)
        ], to: meeting)
        try giveAudio(meeting, service: service, dir: dir)

        let source = await enricher(service, inspector: separateStereo()).autoAssignSpeakers(for: meeting, preferProviderLabels: true)
        XCTAssertEqual(source, .channel)

        let sorted = meeting.segments.sorted { $0.order < $1.order }
        XCTAssertEqual(sorted[0].speakerLabel, MeetingDiarizationEnricher.micSpeakerLabel)
        XCTAssertEqual(sorted[1].speakerLabel, MeetingDiarizationEnricher.systemSpeakerLabel)
        // Me is localized; the other party is named from the single non-self attendee (D-A8).
        XCTAssertEqual(meeting.speakerMap[MeetingDiarizationEnricher.micSpeakerLabel],
                       String(localized: "meetings.diarization.speaker.me"))
        XCTAssertEqual(meeting.speakerMap[MeetingDiarizationEnricher.systemSpeakerLabel], "Alex")
    }

    /// The ad-hoc (attendee-less) fast path: eligibility comes from the two-person toggle, and with no
    /// identifiable attendee the other side falls back to the localized "Them".
    func testAdHocTwoPersonToggleEnablesChannelPathWithThemFallback() async throws {
        let (service, dir) = try makeStore()
        let meeting = service.createMeeting(title: "Ad hoc", source: .adHoc, state: .completed)
        service.appendStableSegments([
            TranscriptionSegment(text: "Mine.", start: 0, end: 1),
            TranscriptionSegment(text: "Theirs.", start: 1, end: 2)
        ], to: meeting)
        try giveAudio(meeting, service: service, dir: dir)

        // Without the toggle, the count is unknown → the auto path no-ops (no channel labeling).
        let before = await enricher(service, inspector: separateStereo()).autoAssignSpeakers(for: meeting, preferProviderLabels: true)
        XCTAssertEqual(before, SpeakerSource.none)
        XCTAssertTrue(meeting.segments.allSatisfy { $0.speakerLabel == nil })

        service.setTwoPersonCall(true, for: meeting)
        let after = await enricher(service, inspector: separateStereo()).autoAssignSpeakers(for: meeting, preferProviderLabels: true)
        XCTAssertEqual(after, .channel)
        XCTAssertEqual(meeting.speakerMap[MeetingDiarizationEnricher.systemSpeakerLabel],
                       String(localized: "meetings.diarization.speaker.others"))
    }

    // MARK: - Cloud adoption (D-A3)

    func testAutoAssignAdoptsProviderLabelsAndSkipsChannel() async throws {
        let (service, dir) = try makeStore()
        let meeting = service.createMeeting(
            title: "Cloud", source: .adHoc, state: .completed,
            attendees: [Attendee(name: "Marco"), Attendee(name: "Alex")]
        )
        // Segments already carry provider labels (as a final pass / import would persist — G4).
        service.appendStableSegments([
            TranscriptionSegment(text: "One.", start: 0, end: 1, speakerLabel: "A", speakerConfidence: 0.9),
            TranscriptionSegment(text: "Two.", start: 1, end: 2, speakerLabel: "B", speakerConfidence: 0.9)
        ], to: meeting)
        try giveAudio(meeting, service: service, dir: dir)

        let source = await enricher(service, inspector: separateStereo()).autoAssignSpeakers(for: meeting, preferProviderLabels: true)
        XCTAssertEqual(source, .cloud)
        // The channel path did NOT run — provider labels are preserved verbatim, not overwritten.
        let labels = meeting.segments.sorted { $0.order < $1.order }.map(\.speakerLabel)
        XCTAssertEqual(labels, ["A", "B"])
    }

    func testPreferOffLetsChannelOverrideProviderLabels() async throws {
        let (service, dir) = try makeStore()
        let meeting = service.createMeeting(
            title: "Cloud off", source: .adHoc, state: .completed,
            attendees: [Attendee(name: "Marco", isSelf: true), Attendee(name: "Alex")]
        )
        service.appendStableSegments([
            TranscriptionSegment(text: "One.", start: 0, end: 1, speakerLabel: "A"),
            TranscriptionSegment(text: "Two.", start: 1, end: 2, speakerLabel: "B")
        ], to: meeting)
        try giveAudio(meeting, service: service, dir: dir)

        let source = await enricher(service, inspector: separateStereo()).autoAssignSpeakers(for: meeting, preferProviderLabels: false)
        XCTAssertEqual(source, .channel)
        let labels = meeting.segments.sorted { $0.order < $1.order }.map(\.speakerLabel)
        XCTAssertEqual(labels, [MeetingDiarizationEnricher.micSpeakerLabel, MeetingDiarizationEnricher.systemSpeakerLabel])
    }

    // MARK: - Exclusions: mixed-mode & timeline mismatch (D-A4)

    func testMixedModeCorrelatedChannelsNoOp() async throws {
        let (service, dir) = try makeStore()
        let meeting = service.createMeeting(
            title: "Mixed", source: .adHoc, state: .completed,
            attendees: [Attendee(name: "Marco"), Attendee(name: "Alex")]
        )
        service.appendStableSegments([
            TranscriptionSegment(text: "First.", start: 0, end: 1),
            TranscriptionSegment(text: "Second.", start: 1, end: 2)
        ], to: meeting)
        try giveAudio(meeting, service: service, dir: dir)

        // Two identical channels (mixed mode) → not separate-track → auto path writes nothing.
        let sr = 16_000
        let mix = [Float](repeating: 0.5, count: sr * 2)
        let inspector = StubInspector(audio: MeetingAudioData(channels: [mix, mix], sampleRate: Double(sr)))

        let outcome = await enricher(service, inspector: inspector).autoLabelTwoPersonChannel(meeting, otherPartyName: "Alex")
        XCTAssertEqual(outcome, .unavailable)
        XCTAssertTrue(meeting.segments.allSatisfy { $0.speakerLabel == nil }, "no misfire on mixed-mode audio")
    }

    func testTimelineMismatchNoOp() async throws {
        let (service, dir) = try makeStore()
        let meeting = service.createMeeting(
            title: "Restarted", source: .adHoc, state: .completed,
            attendees: [Attendee(name: "Marco"), Attendee(name: "Alex")]
        )
        // Segment sits ~1000 s in, but the audio is only 2 s — a restart-stitched timeline.
        service.appendStableSegments([
            TranscriptionSegment(text: "Way past the audio.", start: 1000, end: 1002)
        ], to: meeting)
        try giveAudio(meeting, service: service, dir: dir)

        let outcome = await enricher(service, inspector: separateStereo()).autoLabelTwoPersonChannel(meeting, otherPartyName: "Alex")
        XCTAssertEqual(outcome, .timelineMismatch)
        XCTAssertTrue(meeting.segments.allSatisfy { $0.speakerLabel == nil }, "restart-stitched audio is excluded")
    }

    /// Imported audio is never separate-track even with decorrelated channels — the auto channel path
    /// refuses it (only live captures carry genuine mic/system tracks).
    func testImportedAudioIsNotEligibleForChannelPath() async throws {
        let (service, dir) = try makeStore()
        let meeting = service.createMeeting(
            title: "Imported", source: .importedAudio, state: .completed,
            attendees: [Attendee(name: "Marco"), Attendee(name: "Alex")]
        )
        service.appendStableSegments([
            TranscriptionSegment(text: "Left.", start: 0, end: 1),
            TranscriptionSegment(text: "Right.", start: 1, end: 2)
        ], to: meeting)
        try giveAudio(meeting, service: service, dir: dir)

        let outcome = await enricher(service, inspector: separateStereo()).autoLabelTwoPersonChannel(meeting)
        XCTAssertEqual(outcome, .unavailable)
        XCTAssertTrue(meeting.segments.allSatisfy { $0.speakerLabel == nil })
    }
}
