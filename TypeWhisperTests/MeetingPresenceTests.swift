import XCTest
@testable import TypeWhisper

/// Pure tests for the meeting-presence logic behind `GET /v1/meetings/now` and
/// `GET /v1/meetings/sessions` (spec: docs/specs/2026-09-30-meeting-presence-api-proposal.md):
/// which meeting counts as "now", when a caption session stops counting, and what the speaking
/// signal does with microphone and system-audio levels.
final class MeetingPresenceTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    private func facts(
        id: UUID = UUID(),
        state: MeetingState = .live,
        source: MeetingSource = .adHoc,
        start: Date? = Date(timeIntervalSince1970: 1_790_000_000),
        end: Date? = nil,
        calendarLinked: Bool = false,
        recurring: Bool = false,
        attendees: Int = 0,
        twoPerson: Bool = false,
        url: String? = nil,
        captions: Bool = false,
        audio: Bool = false,
        lastCaptionAt: Date? = nil,
        speakingSeconds: Int? = nil
    ) -> MeetingPresenceFacts {
        MeetingPresenceFacts(
            id: id,
            state: state,
            source: source,
            startDate: start,
            endDate: end,
            isCalendarLinked: calendarLinked,
            isRecurring: recurring,
            attendeeCount: attendees,
            twoPersonCall: twoPerson,
            conferencingURL: url,
            isCaptionSession: captions,
            hasAudio: audio,
            lastCaptionAt: lastCaptionAt,
            speakingSeconds: speakingSeconds
        )
    }

    private func now(
        _ meetings: [MeetingPresenceFacts],
        live: MeetingPresenceLiveState = MeetingPresenceLiveState(),
        calendarEventNow: Bool = false,
        active: Set<UUID> = [],
        reported: [UUID: Int] = [:]
    ) -> MeetingPresenceNow {
        MeetingPresenceProjector.now(
            meetings: meetings,
            live: live,
            calendarEventNow: calendarEventNow,
            isCaptionSessionActive: { active.contains($0) },
            reportedParticipants: { reported[$0] }
        )
    }

    // MARK: - Now

    func testNoMeetingReportsOnlyTheCalendarHint() {
        let idle = now([], calendarEventNow: true)
        XCTAssertFalse(idle.in_meeting)
        XCTAssertNil(idle.meeting_id)
        XCTAssertTrue(idle.calendar_event_now)
    }

    func testLocalCaptureIsInMeetingAndCarriesTheSpeakingSignal() {
        let id = UUID()
        let result = now(
            [facts(id: id, calendarLinked: true, recurring: true, attendees: 4, url: "https://us02web.zoom.us/j/1")],
            live: MeetingPresenceLiveState(capturingMeetingID: id, speaking: true, secondsSinceSpoke: 0)
        )
        XCTAssertTrue(result.in_meeting)
        XCTAssertEqual(result.meeting_id, id.uuidString)
        XCTAssertEqual(result.detected_by, "capture")
        XCTAssertEqual(result.platform, "zoom")
        XCTAssertEqual(result.participants, 4)
        XCTAssertEqual(result.scheduled, true)
        XCTAssertEqual(result.recurring, true)
        XCTAssertEqual(result.speaking, true)
        XCTAssertEqual(result.seconds_since_spoke, 0)
    }

    func testActiveCaptionSessionIsInMeetingWithoutASpeakingSignal() {
        let id = UUID()
        let result = now(
            [facts(id: id, attendees: 6, captions: true)],
            live: MeetingPresenceLiveState(capturingMeetingID: nil, speaking: true, secondsSinceSpoke: 1),
            active: [id],
            reported: [id: 3]
        )
        XCTAssertTrue(result.in_meeting)
        XCTAssertEqual(result.detected_by, "captions")
        XCTAssertEqual(result.platform, "meet")
        // The bridge's head count of who is actually there beats the invited roster.
        XCTAssertEqual(result.participants, 3)
        XCTAssertEqual(result.scheduled, false)
        XCTAssertNil(result.recurring)
        XCTAssertNil(result.speaking)
        XCTAssertNil(result.seconds_since_spoke)
    }

    func testCaptionSessionStillMarkedLiveButSilentIsNotInMeeting() {
        let result = now([facts(captions: true)], active: [])
        XCTAssertFalse(result.in_meeting)
    }

    func testLiveMeetingThatIsNeitherCapturingNorACaptionSessionIsNotInMeeting() {
        // An interrupted local capture can be left `.live`; with no capture running it is not "now".
        XCTAssertFalse(now([facts(audio: true)]).in_meeting)
    }

    func testLocalCaptureWinsOverAConcurrentCaptionSession() {
        let capturing = UUID()
        let captions = UUID()
        let result = now(
            [facts(id: captions, captions: true), facts(id: capturing)],
            live: MeetingPresenceLiveState(capturingMeetingID: capturing, speaking: false, secondsSinceSpoke: nil),
            active: [captions]
        )
        XCTAssertEqual(result.meeting_id, capturing.uuidString)
        XCTAssertEqual(result.detected_by, "capture")
    }

    func testNowJSONOmitsUnknownFieldsAndUsesUTCTimestamps() throws {
        let id = UUID()
        let response = HTTPResponse.json(now([facts(id: id, captions: true)], active: [id]))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: response.body) as? [String: Any])
        XCTAssertEqual(object["schema"] as? Int, 1)
        XCTAssertEqual(object["in_meeting"] as? Bool, true)
        XCTAssertEqual(object["started_at"] as? String, "2026-09-21T14:13:20Z")
        XCTAssertNil(object["speaking"])
        XCTAssertNil(object["participants"])
        XCTAssertNil(object["title"])
    }

    // MARK: - Platform and participants

    func testPlatformComesFromTheJoinLinkHost() {
        let cases: [(String?, String?)] = [
            ("https://meet.google.com/abc-defg-hij", "meet"),
            ("https://company.webex.com/meet/x", "webex"),
            ("https://teams.microsoft.com/l/meetup-join/1", "teams"),
            ("https://notzoom.us/j/1", nil),
            ("https://example.com/call", nil),
            (nil, nil)
        ]
        for (url, expected) in cases {
            XCTAssertEqual(
                MeetingPresenceProjector.platform(conferencingURL: url, isCaptionSession: false),
                expected,
                url ?? "nil"
            )
        }
    }

    func testParticipantsFallBackFromReportedToRosterToTwoPersonFlag() {
        XCTAssertEqual(MeetingPresenceProjector.participants(facts(attendees: 5), reported: 2), 2)
        XCTAssertEqual(MeetingPresenceProjector.participants(facts(attendees: 5), reported: nil), 5)
        XCTAssertEqual(MeetingPresenceProjector.participants(facts(twoPerson: true), reported: nil), 2)
        XCTAssertNil(MeetingPresenceProjector.participants(facts(), reported: nil))
    }

    // MARK: - Sessions

    private func sessions(
        _ meetings: [MeetingPresenceFacts],
        since: Date,
        until: Date? = nil,
        capturing: UUID? = nil,
        active: Set<UUID> = [],
        limit: Int = 200
    ) -> [MeetingPresenceSession] {
        MeetingPresenceProjector.sessions(
            meetings: meetings,
            since: since,
            until: until,
            capturingMeetingID: capturing,
            isCaptionSessionActive: { active.contains($0) },
            limit: limit
        )
    }

    func testSessionsKeepOnlyMeetingsTheUserWasIn() {
        let recorded = facts(state: .completed, end: t0.addingTimeInterval(1800), audio: true, speakingSeconds: 310)
        let captioned = facts(state: .completed, start: t0.addingTimeInterval(3600), end: t0.addingTimeInterval(5400), captions: true)
        let neverStarted = facts(state: .scheduled, source: .calendar, calendarLinked: true)
        let importedFile = facts(state: .completed, source: .importedAudio, end: t0.addingTimeInterval(60), audio: true)
        let importedTranscript = facts(state: .completed, source: .importedTranscript, end: t0.addingTimeInterval(60))
        // A calendar meeting that only ever received a merged Drive transcript: no audio, no bridge.
        let mergedOnly = facts(state: .completed, source: .calendar, end: t0.addingTimeInterval(60), calendarLinked: true)

        let rows = sessions(
            [captioned, neverStarted, importedFile, recorded, importedTranscript, mergedOnly],
            since: t0.addingTimeInterval(-60)
        )
        XCTAssertEqual(rows.map(\.meeting_id), [recorded.id.uuidString, captioned.id.uuidString])
        XCTAssertEqual(rows.map(\.detected_by), ["capture", "captions"])
        XCTAssertEqual(rows.first?.speaking_seconds, 310)
        XCTAssertEqual(rows.first?.ended_at, t0.addingTimeInterval(1800))
    }

    func testSessionsWindowByOverlapNotByStart() {
        let longRunning = facts(state: .completed, end: t0.addingTimeInterval(7200), audio: true)
        let before = facts(state: .completed, start: t0.addingTimeInterval(-7200), end: t0.addingTimeInterval(-3600), audio: true)
        let after = facts(state: .completed, start: t0.addingTimeInterval(90_000), end: t0.addingTimeInterval(91_000), audio: true)

        let rows = sessions(
            [longRunning, before, after],
            since: t0.addingTimeInterval(3600),
            until: t0.addingTimeInterval(80_000)
        )
        XCTAssertEqual(rows.map(\.meeting_id), [longRunning.id.uuidString])
    }

    func testSessionInProgressHasNoEndAndAStaleLiveOneEndsAtItsLastCaption() {
        let running = facts(start: t0.addingTimeInterval(600), captions: true)
        let lastCaption = t0.addingTimeInterval(240)
        let stale = facts(captions: true, lastCaptionAt: lastCaption)

        let rows = sessions([running, stale], since: t0.addingTimeInterval(-60), active: [running.id])
        XCTAssertEqual(rows.map(\.meeting_id), [stale.id.uuidString, running.id.uuidString])
        XCTAssertEqual(rows[0].ended_at, lastCaption)
        XCTAssertNil(rows[1].ended_at)
    }

    func testSessionJSONEncodesAnExplicitNullEndWhileInProgress() throws {
        let id = UUID()
        let row = try XCTUnwrap(sessions([facts(id: id)], since: t0, capturing: id).first)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: HTTPResponse.json(row).body) as? [String: Any]
        )
        XCTAssertTrue(object["ended_at"] is NSNull)
        XCTAssertNil(object["speaking_seconds"])
        XCTAssertNil(object["platform"])
    }

    func testSessionsRespectTheLimit() {
        let meetings = (0..<5).map { index in
            facts(state: .completed, start: t0.addingTimeInterval(Double(index) * 100), end: t0.addingTimeInterval(Double(index) * 100 + 50), audio: true)
        }
        XCTAssertEqual(sessions(meetings, since: t0, limit: 2).map(\.started_at), [t0, t0.addingTimeInterval(100)])
    }

    // MARK: - Calendar hint

    func testCalendarEventNowNeedsATimedEventWithAJoinLinkSpanningNow() {
        let inside = (start: t0.addingTimeInterval(-60), end: t0.addingTimeInterval(60))
        func hint(isAllDay: Bool = false, hasJoinLink: Bool = true, start: Date? = nil, end: Date? = nil) -> Bool {
            MeetingPresenceProjector.calendarEventNow(
                events: [(start: start ?? inside.start, end: end ?? inside.end, isAllDay: isAllDay, hasJoinLink: hasJoinLink)],
                now: t0
            )
        }
        XCTAssertTrue(hint())
        XCTAssertFalse(hint(isAllDay: true))
        XCTAssertFalse(hint(hasJoinLink: false))
        XCTAssertFalse(hint(start: t0.addingTimeInterval(60), end: t0.addingTimeInterval(120)))
        XCTAssertFalse(hint(start: t0.addingTimeInterval(-120), end: t0))
    }

    // MARK: - Speaking seconds

    func testSpeakingSecondsSumsTheMicChannelOfATwoPersonCall() {
        let seconds = MeetingPresenceProjector.speakingSeconds(
            segments: [
                (start: 0, end: 10, speakerLabel: "SPEAKER_ME"),
                (start: 10, end: 40, speakerLabel: "SPEAKER_OTHERS"),
                (start: 40, end: 45.4, speakerLabel: "SPEAKER_ME")
            ],
            speakerMap: [:],
            selfNames: [],
            selfLabel: "SPEAKER_ME"
        )
        XCTAssertEqual(seconds, 15)
    }

    func testSpeakingSecondsResolvesTheSelfAttendeeThroughTheSpeakerMapAndCaptionNames() {
        let seconds = MeetingPresenceProjector.speakingSeconds(
            segments: [
                (start: 0, end: 4, speakerLabel: "SPEAKER_01"),
                (start: 4, end: 9, speakerLabel: "SPEAKER_02"),
                (start: 9, end: 12, speakerLabel: " ana lópez ")
            ],
            speakerMap: ["SPEAKER_01": "Ana López", "SPEAKER_02": "Ben"],
            selfNames: ["Ana López"],
            selfLabel: "SPEAKER_ME"
        )
        XCTAssertEqual(seconds, 7)
    }

    func testSpeakingSecondsIsZeroWhenTheIdentifiedUserNeverSpoke() {
        let seconds = MeetingPresenceProjector.speakingSeconds(
            segments: [(start: 0, end: 30, speakerLabel: "Ben")],
            speakerMap: [:],
            selfNames: ["Ana"],
            selfLabel: "SPEAKER_ME"
        )
        XCTAssertEqual(seconds, 0)
    }

    func testSpeakingSecondsIsUnknownWithoutLabelsOrWithoutAWayToNameTheUser() {
        XCTAssertNil(MeetingPresenceProjector.speakingSeconds(
            segments: [(start: 0, end: 30, speakerLabel: nil)],
            speakerMap: [:],
            selfNames: ["Ana"],
            selfLabel: "SPEAKER_ME"
        ))
        XCTAssertNil(MeetingPresenceProjector.speakingSeconds(
            segments: [(start: 0, end: 30, speakerLabel: "SPEAKER_00")],
            speakerMap: [:],
            selfNames: [],
            selfLabel: "SPEAKER_ME"
        ))
    }

    // MARK: - Speaking tracker

    func testTrackerCountsALoudMicAsSpeakingThroughTheHangover() {
        var tracker = SpeakingActivityTracker()
        XCTAssertFalse(tracker.isSpeaking(at: t0))
        XCTAssertNil(tracker.secondsSinceSpoke(at: t0))

        tracker.ingest(micLevel: 0.3, systemLevel: 0, at: t0)
        XCTAssertTrue(tracker.isSpeaking(at: t0.addingTimeInterval(SpeakingActivityTracker.hangover)))
        XCTAssertFalse(tracker.isSpeaking(at: t0.addingTimeInterval(SpeakingActivityTracker.hangover + 1)))
        XCTAssertEqual(tracker.secondsSinceSpoke(at: t0.addingTimeInterval(42.9)), 42)
    }

    func testTrackerIgnoresRoomNoiseAndSpeakerBleed() {
        var tracker = SpeakingActivityTracker()
        tracker.ingest(micLevel: 0.02, systemLevel: 0, at: t0)
        // The mic hears the other side through the speakers: audible, but well under the system level.
        tracker.ingest(micLevel: 0.2, systemLevel: 0.8, at: t0)
        XCTAssertNil(tracker.lastSpokeAt)

        // Talking over someone: the mic holds its own against the system audio.
        tracker.ingest(micLevel: 0.5, systemLevel: 0.8, at: t0)
        XCTAssertEqual(tracker.lastSpokeAt, t0)
    }

    func testTrackerResetForgetsThePreviousMeeting() {
        var tracker = SpeakingActivityTracker()
        tracker.ingest(micLevel: 0.3, systemLevel: 0, at: t0)
        tracker.reset()
        XCTAssertNil(tracker.secondsSinceSpoke(at: t0))
    }

    // MARK: - Caption-session liveness

    func testCaptionSessionGoesStaleFiveMinutesAfterItsLastSignOfLife() {
        var registry = LiveSessionActivityRegistry()
        let id = UUID()
        XCTAssertFalse(registry.isActive(id, at: t0))

        registry.touch(id, at: t0, participants: 3)
        XCTAssertTrue(registry.isActive(id, at: t0.addingTimeInterval(5 * 60)))
        XCTAssertFalse(registry.isActive(id, at: t0.addingTimeInterval(5 * 60 + 1)))
        XCTAssertNil(registry.participants(for: id, at: t0.addingTimeInterval(5 * 60 + 1)))
    }

    func testHeartbeatKeepsAQuietSessionAliveAndACountlessOneKeepsTheLastCount() {
        var registry = LiveSessionActivityRegistry()
        let id = UUID()
        registry.touch(id, at: t0, participants: 3)
        registry.touch(id, at: t0.addingTimeInterval(4 * 60))

        let later = t0.addingTimeInterval(8 * 60)
        XCTAssertTrue(registry.isActive(id, at: later))
        XCTAssertEqual(registry.participants(for: id, at: later), 3)
    }

    func testAnOutOfOrderTouchNeverRewindsTheClockAndRemoveEndsTheSession() {
        var registry = LiveSessionActivityRegistry()
        let id = UUID()
        registry.touch(id, at: t0.addingTimeInterval(60))
        registry.touch(id, at: t0)
        XCTAssertTrue(registry.isActive(id, at: t0.addingTimeInterval(60 + 5 * 60)))

        registry.remove(id)
        XCTAssertFalse(registry.isActive(id, at: t0.addingTimeInterval(61)))
    }
}
