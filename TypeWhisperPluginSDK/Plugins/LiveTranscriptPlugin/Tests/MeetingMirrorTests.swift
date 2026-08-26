import Foundation
import TypeWhisperPluginSDK
import TypeWhisperPluginSDKTesting
import XCTest
@testable import LiveTranscriptPlugin

@MainActor
final class MeetingMirrorTests: XCTestCase {
    private func segment(_ meetingID: UUID, _ texts: [String], start: Double = 0) -> MeetingEvent {
        let segs = texts.enumerated().map { index, text in
            MeetingEventSegment(
                text: text,
                startSeconds: start + Double(index),
                endSeconds: start + Double(index) + 1
            )
        }
        return .transcriptSegment(MeetingTranscriptSegmentPayload(meetingID: meetingID, segments: segs))
    }

    func testResetsOnStartedAndAppendsInOrder() {
        let mirror = MeetingTranscriptMirror()
        let idA = UUID()

        // Stale content bound to a previous meeting should be wiped by `.started`.
        mirror.started(meetingID: UUID())
        mirror.started(meetingID: idA)
        XCTAssertEqual(mirror.activeMeetingID, idA)
        XCTAssertEqual(mirror.renderedText, "")

        if case let .transcriptSegment(p) = segment(idA, ["Hello"]) { mirror.appendSegments(p) }
        if case let .transcriptSegment(p) = segment(idA, ["world", "again"], start: 5) { mirror.appendSegments(p) }
        XCTAssertEqual(mirror.renderedText, "Hello world again")
    }

    func testIgnoresSegmentsForDifferentMeeting() {
        let mirror = MeetingTranscriptMirror()
        let idA = UUID()
        mirror.started(meetingID: idA)

        if case let .transcriptSegment(p) = segment(UUID(), ["intruder"]) { mirror.appendSegments(p) }
        XCTAssertEqual(mirror.renderedText, "")
    }

    func testTranscriptReadyReplacesWithFinalText() {
        let mirror = MeetingTranscriptMirror()
        let idA = UUID()
        mirror.started(meetingID: idA)
        if case let .transcriptSegment(p) = segment(idA, ["partial"]) { mirror.appendSegments(p) }

        mirror.transcriptReady(MeetingTranscriptReadyPayload(
            meetingID: idA, fullText: "Line one\nLine two", segmentCount: 2, durationSeconds: 10
        ))
        XCTAssertEqual(mirror.renderedText, "Line one\nLine two")
    }

    func testFinishesOnEndedAndRejectsLaterSegments() {
        let mirror = MeetingTranscriptMirror()
        let idA = UUID()
        mirror.started(meetingID: idA)
        if case let .transcriptSegment(p) = segment(idA, ["before"]) { mirror.appendSegments(p) }

        mirror.ended(meetingID: idA)
        XCTAssertTrue(mirror.isFinished)

        if case let .transcriptSegment(p) = segment(idA, ["after"]) { mirror.appendSegments(p) }
        XCTAssertEqual(mirror.renderedText, "before", "segments after ended must be ignored")
    }

    // MARK: - End-to-end through the plugin's meeting subscription

    func testPluginMirrorsMeetingEventsFromHostCapability() async throws {
        let host = try PluginTestHostServicesFactory.make(defaults: ["autoOpen": false])
        let plugin = LiveTranscriptPlugin()
        plugin.activate(host: host)
        defer { plugin.deactivate() }

        XCTAssertEqual(host.meetingEventSubscriberCount, 1)

        let meetingID = UUID()
        await host.emitMeetingEvent(.started(MeetingStartedPayload(
            meetingID: meetingID, title: "Sync", isCalendarMeeting: false, attendeeCount: 0
        )))
        await host.emitMeetingEvent(.transcriptSegment(MeetingTranscriptSegmentPayload(
            meetingID: meetingID,
            segments: [MeetingEventSegment(text: "hello there", startSeconds: 0, endSeconds: 1)]
        )))

        XCTAssertEqual(plugin.mirroredMeetingTextForTesting, "hello there")

        await host.emitMeetingEvent(.ended(MeetingEndedPayload(
            meetingID: meetingID, durationSeconds: 5, stateRaw: "completed", segmentCount: 1
        )))
        // A late segment after `.ended` must be ignored.
        await host.emitMeetingEvent(.transcriptSegment(MeetingTranscriptSegmentPayload(
            meetingID: meetingID,
            segments: [MeetingEventSegment(text: "late", startSeconds: 9, endSeconds: 10)]
        )))
        XCTAssertEqual(plugin.mirroredMeetingTextForTesting, "hello there")
    }
}

/// Small factory so the test can build a `PluginTestHostServices` (its init `throws`).
private enum PluginTestHostServicesFactory {
    static func make(defaults: [String: Any]) throws -> PluginTestHostServices {
        try PluginTestHostServices(defaults: defaults)
    }
}
