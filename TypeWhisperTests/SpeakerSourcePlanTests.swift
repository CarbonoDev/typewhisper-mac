import XCTest
@testable import TypeWhisper

/// Speaker-recognition amendment (M9-SPK-A) — the precedence ladder is a pure function, so the
/// cloud > channel > pyannote > none ordering, the participant-count derivation, and the self/other
/// naming are all unit-testable without audio (D-A2/D-A4/D-A5/D-A8).
@MainActor
final class SpeakerSourcePlanTests: XCTestCase {

    private func availability(
        labeled: Bool = false,
        prefer: Bool = true,
        count: Int? = nil,
        track: MeetingDiarizationEnricher.Availability
    ) -> SpeakerSourceAvailability {
        SpeakerSourceAvailability(
            segmentsAlreadyLabeled: labeled,
            preferProviderLabels: prefer,
            effectiveParticipantCount: count,
            trackAvailability: track
        )
    }

    // MARK: - Precedence ladder (D-A2)

    func testCloudWinsWhenLabeledAndPreferred() {
        // Even a 2-person separate-track recording yields to already-present provider labels.
        let source = SpeakerSourcePlan.resolve(availability(labeled: true, prefer: true, count: 2, track: .separateTrack))
        XCTAssertEqual(source, .cloud)
    }

    func testPreferOffSkipsCloudRung() {
        // With the preference off, labels are not adopted — the 2-person channel path applies instead.
        let source = SpeakerSourcePlan.resolve(availability(labeled: true, prefer: false, count: 2, track: .separateTrack))
        XCTAssertEqual(source, .channel)
    }

    func testTwoPersonSeparateTrackTakesChannel() {
        let source = SpeakerSourcePlan.resolve(availability(count: 2, track: .separateTrack))
        XCTAssertEqual(source, .channel)
    }

    func testThreePersonSeparateTrackFallsToPyannoteWithCountHint() {
        let source = SpeakerSourcePlan.resolve(availability(count: 3, track: .separateTrack))
        XCTAssertEqual(source, .pyannote(numSpeakers: 3))
    }

    func testProviderTrackTakesPyannoteWithCountHint() {
        let source = SpeakerSourcePlan.resolve(availability(count: 2, track: .provider))
        XCTAssertEqual(source, .pyannote(numSpeakers: 2))
    }

    func testUnknownCountPyannoteHintIsNil() {
        let source = SpeakerSourcePlan.resolve(availability(count: nil, track: .provider))
        XCTAssertEqual(source, .pyannote(numSpeakers: nil))
    }

    func testUnavailableTrackIsNone() {
        let source = SpeakerSourcePlan.resolve(availability(count: 2, track: .unavailable))
        XCTAssertEqual(source, SpeakerSource.none)
    }

    func testUnlabeledProviderMeetingIsPyannoteNotCloud() {
        let source = SpeakerSourcePlan.resolve(availability(labeled: false, prefer: true, count: nil, track: .provider))
        XCTAssertEqual(source, .pyannote(numSpeakers: nil))
    }

    // MARK: - Label vocabulary: only cloud labels feed the cloud rung (finding)

    func testChannelAndPyannoteLabelsAreNotProviderOriginated() {
        // Local vocabularies — must NOT count as cloud labels.
        XCTAssertFalse(SpeakerSourcePlan.isProviderOriginatedLabel(MeetingDiarizationEnricher.micSpeakerLabel))
        XCTAssertFalse(SpeakerSourcePlan.isProviderOriginatedLabel(MeetingDiarizationEnricher.systemSpeakerLabel))
        XCTAssertFalse(SpeakerSourcePlan.isProviderOriginatedLabel("SPEAKER_00"))
        XCTAssertFalse(SpeakerSourcePlan.isProviderOriginatedLabel("  SPEAKER_01  "))
        // Empty / nil → not a label at all.
        XCTAssertFalse(SpeakerSourcePlan.isProviderOriginatedLabel(nil))
        XCTAssertFalse(SpeakerSourcePlan.isProviderOriginatedLabel(""))
        XCTAssertFalse(SpeakerSourcePlan.isProviderOriginatedLabel("   "))
    }

    func testCloudProviderLabelsAreProviderOriginated() {
        // Cloud vocabulary (e.g. AssemblyAI "Speaker A"/"Speaker B"; adopted "A"/"B").
        XCTAssertTrue(SpeakerSourcePlan.isProviderOriginatedLabel("Speaker A"))
        XCTAssertTrue(SpeakerSourcePlan.isProviderOriginatedLabel("A"))
        XCTAssertTrue(SpeakerSourcePlan.isProviderOriginatedLabel("Alex"))
    }

    /// A meeting the app already labeled by the two-person **channel** path must resolve `.channel`
    /// (channel caption + Undo/Redo), not `.cloud`. This mirrors how `plannedSpeakerSource` derives
    /// `segmentsAlreadyLabeled` from the label vocabulary.
    func testChannelLabeledMeetingDoesNotResolveCloud() {
        let channelLabeled = [MeetingDiarizationEnricher.micSpeakerLabel, MeetingDiarizationEnricher.systemSpeakerLabel]
            .contains { SpeakerSourcePlan.isProviderOriginatedLabel($0) }
        let source = SpeakerSourcePlan.resolve(availability(
            labeled: channelLabeled, prefer: true, count: 2, track: .separateTrack
        ))
        XCTAssertEqual(source, .channel)
    }

    /// A meeting already labeled by local **pyannote** must keep resolving `.pyannote` (Identify stays
    /// available for a re-run), not flip to `.cloud`.
    func testPyannoteLabeledMeetingDoesNotResolveCloud() {
        let pyannoteLabeled = ["SPEAKER_00", "SPEAKER_01"]
            .contains { SpeakerSourcePlan.isProviderOriginatedLabel($0) }
        let source = SpeakerSourcePlan.resolve(availability(
            labeled: pyannoteLabeled, prefer: true, count: 3, track: .separateTrack
        ))
        XCTAssertEqual(source, .pyannote(numSpeakers: 3))
    }

    // MARK: - Effective participant count (D-A4)

    private func makeStore() throws -> MeetingService {
        let dir = try TestSupport.makeTemporaryDirectory(prefix: "SpeakerPlan")
        addTeardownBlock { TestSupport.remove(dir) }
        return MeetingService(appSupportDirectory: dir)
    }

    func testAttendeeCountWins() throws {
        let service = try makeStore()
        let meeting = service.createMeeting(
            title: "Sync", attendees: [Attendee(name: "A"), Attendee(name: "B"), Attendee(name: "C")]
        )
        XCTAssertEqual(SpeakerSourcePlan.effectiveParticipantCount(for: meeting), 3)
    }

    func testTwoPersonToggleUsedWhenNoAttendees() throws {
        let service = try makeStore()
        let meeting = service.createMeeting(title: "Ad hoc")
        XCTAssertNil(SpeakerSourcePlan.effectiveParticipantCount(for: meeting))
        service.setTwoPersonCall(true, for: meeting)
        XCTAssertEqual(SpeakerSourcePlan.effectiveParticipantCount(for: meeting), 2)
        service.setTwoPersonCall(false, for: meeting)
        XCTAssertNil(SpeakerSourcePlan.effectiveParticipantCount(for: meeting))
    }

    func testToggleIgnoredWhenAttendeesPresent() throws {
        let service = try makeStore()
        let meeting = service.createMeeting(title: "Sync", attendees: [Attendee(name: "A"), Attendee(name: "B"), Attendee(name: "C")])
        service.setTwoPersonCall(true, for: meeting)
        // Attendees are authoritative — the toggle does not override a real count.
        XCTAssertEqual(SpeakerSourcePlan.effectiveParticipantCount(for: meeting), 3)
    }

    // MARK: - Self / other naming (D-A8)

    func testOtherPartyNameFromSingleNonSelfAttendee() throws {
        let service = try makeStore()
        let meeting = service.createMeeting(
            title: "1:1",
            attendees: [Attendee(name: "Marco", email: "m@x", isSelf: true), Attendee(name: "Alex", email: "a@x")]
        )
        XCTAssertEqual(SpeakerSourcePlan.otherPartyName(for: meeting), "Alex")
    }

    func testOtherPartyNameNilWhenSelfIndeterminate() throws {
        let service = try makeStore()
        // Neither attendee is marked self → not exactly one non-self → indeterminate.
        let meeting = service.createMeeting(
            title: "1:1", attendees: [Attendee(name: "Marco"), Attendee(name: "Alex")]
        )
        XCTAssertNil(SpeakerSourcePlan.otherPartyName(for: meeting))
    }
}
