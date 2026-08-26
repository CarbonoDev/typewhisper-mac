import XCTest
@testable import TypeWhisper

final class MeetingModelTests: XCTestCase {
    // MARK: - Enum raw roundtrips

    func testMeetingEnumRawRoundtrips() {
        for state in MeetingState.allCases {
            XCTAssertEqual(MeetingState(rawValue: state.rawValue), state)
        }
        for source in MeetingSource.allCases {
            XCTAssertEqual(MeetingSource(rawValue: source.rawValue), source)
        }
        for kind in MeetingOutputKind.allCases {
            XCTAssertEqual(MeetingOutputKind(rawValue: kind.rawValue), kind)
        }
        for source in MeetingSegmentSource.allCases {
            XCTAssertEqual(MeetingSegmentSource(rawValue: source.rawValue), source)
        }
    }

    func testMeetingEnumAccessorsRoundtripThroughRawStorage() {
        let meeting = Meeting(title: "Sync")
        meeting.state = .completed
        meeting.source = .calendar
        XCTAssertEqual(meeting.stateRaw, "completed")
        XCTAssertEqual(meeting.sourceRaw, "calendar")
        XCTAssertEqual(meeting.state, .completed)
        XCTAssertEqual(meeting.source, .calendar)

        let segment = MeetingSegment(order: 0, start: 0, end: 1, text: "hi")
        segment.source = .importedTranscript
        XCTAssertEqual(segment.sourceRaw, "importedTranscript")
        XCTAssertEqual(segment.source, .importedTranscript)

        let output = MeetingOutput(kind: .summary, content: "x")
        output.kind = .brief
        XCTAssertEqual(output.kindRaw, "brief")
        XCTAssertEqual(output.kind, .brief)
    }

    func testUnknownRawValuesFallBackToDefaults() {
        let meeting = Meeting(title: "Sync")
        meeting.stateRaw = "not-a-real-state"
        meeting.sourceRaw = "not-a-real-source"
        XCTAssertEqual(meeting.state, .scheduled)
        XCTAssertEqual(meeting.source, .adHoc)
    }

    // MARK: - Mapper roundtrip

    func testSegmentMapperRoundtrip() {
        let original = TranscriptionSegment(
            text: "Hello world",
            start: 1.5,
            end: 3.25,
            speakerLabel: "SPEAKER_00",
            speakerConfidence: 0.87
        )

        let model = MeetingSegmentMapper.makeSegment(
            from: original,
            order: 4,
            source: .importedAudio,
            isStable: false
        )
        XCTAssertEqual(model.order, 4)
        XCTAssertEqual(model.source, .importedAudio)
        XCTAssertFalse(model.isStable)

        let restored = MeetingSegmentMapper.transcriptionSegment(from: model)
        XCTAssertEqual(restored.text, original.text)
        XCTAssertEqual(restored.start, original.start)
        XCTAssertEqual(restored.end, original.end)
        XCTAssertEqual(restored.speakerLabel, original.speakerLabel)
        XCTAssertEqual(restored.speakerConfidence, original.speakerConfidence)
    }

    func testSegmentMapperRoundtripWithNilSpeaker() {
        let original = TranscriptionSegment(text: "no speaker", start: 0, end: 2)
        let model = MeetingSegmentMapper.makeSegment(from: original, order: 0, source: .liveCapture)
        let restored = MeetingSegmentMapper.transcriptionSegment(from: model)
        XCTAssertNil(restored.speakerLabel)
        XCTAssertNil(restored.speakerConfidence)
        XCTAssertEqual(restored.text, "no speaker")
    }

    // MARK: - JSON columns

    func testAttendeesJSONRoundtrip() {
        let meeting = Meeting(title: "Sync")
        XCTAssertTrue(meeting.attendees.isEmpty)

        let attendees = [
            Attendee(name: "Marco", email: "marco@example.com"),
            Attendee(name: "Guest", email: nil)
        ]
        meeting.attendees = attendees
        XCTAssertNotNil(meeting.attendeesJSON)
        XCTAssertEqual(meeting.attendees, attendees)
    }

    func testSpeakerMapJSONRoundtrip() {
        let meeting = Meeting(title: "Sync")
        XCTAssertTrue(meeting.speakerMap.isEmpty)

        meeting.speakerMap = ["SPEAKER_00": "Marco", "SPEAKER_01": "Alex"]
        XCTAssertNotNil(meeting.speakerMapJSON)
        XCTAssertEqual(meeting.speakerMap, ["SPEAKER_00": "Marco", "SPEAKER_01": "Alex"])
    }

    func testObsidianTagsJSONRoundtrip() {
        let meeting = Meeting(title: "Sync")
        XCTAssertTrue(meeting.obsidianTags.isEmpty)

        meeting.obsidianTags = ["meeting", "acme"]
        XCTAssertEqual(meeting.obsidianTags, ["meeting", "acme"])
    }
}
