import Foundation
import XCTest
@testable import TypeWhisperPluginSDK

/// Payload Codable round-trips for all five meeting-event payloads, including the
/// missing-optional decode path (addendum AD3). WebhookPlugin JSON-encodes these into POST
/// bodies, so tolerance mirrors `TranscriptionCompletedPayload`.
final class MeetingEventCodableTests: XCTestCase {
    private func roundTrip<T: Codable & Equatable>(_ value: T, _ equal: (T, T) -> Bool) throws {
        let data = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(T.self, from: data)
        XCTAssertTrue(equal(value, decoded))
    }

    func testStartedRoundTrip() throws {
        let original = MeetingStartedPayload(
            meetingID: UUID(),
            title: "Weekly Sync",
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            isCalendarMeeting: true,
            attendeeCount: 4
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(MeetingStartedPayload.self, from: data)
        XCTAssertEqual(decoded.meetingID, original.meetingID)
        XCTAssertEqual(decoded.title, original.title)
        XCTAssertEqual(decoded.startedAt, original.startedAt)
        XCTAssertEqual(decoded.isCalendarMeeting, original.isCalendarMeeting)
        XCTAssertEqual(decoded.attendeeCount, original.attendeeCount)
    }

    func testTranscriptSegmentRoundTripWithAndWithoutSpeaker() throws {
        let original = MeetingTranscriptSegmentPayload(
            meetingID: UUID(),
            segments: [
                MeetingEventSegment(text: "hello", startSeconds: 0, endSeconds: 1, speakerLabel: "SPEAKER_00"),
                MeetingEventSegment(text: "world", startSeconds: 1, endSeconds: 2, speakerLabel: nil),
            ]
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(MeetingTranscriptSegmentPayload.self, from: data)
        XCTAssertEqual(decoded.meetingID, original.meetingID)
        XCTAssertEqual(decoded.segments.count, 2)
        XCTAssertEqual(decoded.segments[0].speakerLabel, "SPEAKER_00")
        XCTAssertNil(decoded.segments[1].speakerLabel)
    }

    func testTranscriptSegmentDecodesMissingSegmentsAsEmpty() throws {
        let id = UUID()
        let json = "{\"meetingID\":\"\(id.uuidString)\"}"
        let decoded = try JSONDecoder().decode(
            MeetingTranscriptSegmentPayload.self,
            from: Data(json.utf8)
        )
        XCTAssertEqual(decoded.meetingID, id)
        XCTAssertTrue(decoded.segments.isEmpty)
    }

    func testEventSegmentDecodesMissingSpeaker() throws {
        let json = "{\"text\":\"hi\",\"startSeconds\":0,\"endSeconds\":1}"
        let decoded = try JSONDecoder().decode(MeetingEventSegment.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.text, "hi")
        XCTAssertNil(decoded.speakerLabel)
    }

    func testTranscriptReadyRoundTrip() throws {
        let original = MeetingTranscriptReadyPayload(
            meetingID: UUID(), fullText: "the whole thing", segmentCount: 12, durationSeconds: 360.5
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(MeetingTranscriptReadyPayload.self, from: data)
        XCTAssertEqual(decoded.meetingID, original.meetingID)
        XCTAssertEqual(decoded.fullText, original.fullText)
        XCTAssertEqual(decoded.segmentCount, original.segmentCount)
        XCTAssertEqual(decoded.durationSeconds, original.durationSeconds)
    }

    func testOutputGeneratedRoundTripAndMissingOptionals() throws {
        let original = MeetingOutputGeneratedPayload(
            meetingID: UUID(),
            kindRaw: "summary",
            templateID: UUID(),
            content: "body",
            provider: "openai",
            model: "gpt-4o"
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(MeetingOutputGeneratedPayload.self, from: data)
        XCTAssertEqual(decoded.templateID, original.templateID)
        XCTAssertEqual(decoded.provider, "openai")
        XCTAssertEqual(decoded.model, "gpt-4o")

        let id = UUID()
        let json = "{\"meetingID\":\"\(id.uuidString)\",\"kindRaw\":\"brief\",\"content\":\"c\"}"
        let sparse = try JSONDecoder().decode(
            MeetingOutputGeneratedPayload.self, from: Data(json.utf8)
        )
        XCTAssertEqual(sparse.meetingID, id)
        XCTAssertEqual(sparse.kindRaw, "brief")
        XCTAssertNil(sparse.templateID)
        XCTAssertNil(sparse.provider)
        XCTAssertNil(sparse.model)
    }

    func testEndedRoundTrip() throws {
        let original = MeetingEndedPayload(
            meetingID: UUID(),
            endedAt: Date(timeIntervalSince1970: 1_700_000_500),
            durationSeconds: 500,
            stateRaw: "completed",
            segmentCount: 7
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(MeetingEndedPayload.self, from: data)
        XCTAssertEqual(decoded.meetingID, original.meetingID)
        XCTAssertEqual(decoded.endedAt, original.endedAt)
        XCTAssertEqual(decoded.durationSeconds, original.durationSeconds)
        XCTAssertEqual(decoded.stateRaw, original.stateRaw)
        XCTAssertEqual(decoded.segmentCount, original.segmentCount)
    }
}
