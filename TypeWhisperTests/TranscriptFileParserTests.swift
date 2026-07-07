import XCTest
@testable import TypeWhisper

final class TranscriptFileParserTests: XCTestCase {

    // MARK: - Google Meet format (Speaker Name  HH:MM:SS + utterance)

    func testGoogleMeetFormatProducesOrderedSpeakerLabeledMonotonicSegments() {
        let raw = """
        Alice Johnson  00:00:05
        Hi everyone, thanks for joining today.

        Bob Smith  00:00:12
        Happy to be here. Let's get started.

        Alice Johnson  00:00:20
        First item is the roadmap.
        """

        let segments = TranscriptFileParser.parse(raw)

        XCTAssertEqual(segments.count, 3)
        XCTAssertEqual(segments.map(\.speakerLabel), ["Alice Johnson", "Bob Smith", "Alice Johnson"])
        XCTAssertEqual(segments.map(\.start), [5, 12, 20])
        XCTAssertEqual(segments[0].text, "Hi everyone, thanks for joining today.")
        XCTAssertEqual(segments[1].text, "Happy to be here. Let's get started.")
        // Start times are strictly monotonic and end times backfill from the next start.
        XCTAssertEqual(segments[0].end, 12)
        XCTAssertEqual(segments[1].end, 20)
        for index in 1..<segments.count {
            XCTAssertGreaterThanOrEqual(segments[index].start, segments[index - 1].start)
        }
    }

    func testMultiLineUtteranceUnderMeetHeaderIsJoined() {
        let raw = """
        Alice  00:00:05
        This is the first line.
        And this continues the same turn.

        Bob  00:00:30
        A reply.
        """

        let segments = TranscriptFileParser.parse(raw)
        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments[0].text, "This is the first line. And this continues the same turn.")
        XCTAssertEqual(segments[0].speakerLabel, "Alice")
    }

    // MARK: - Speaker: text lines

    func testSpeakerColonLinesAreParsed() {
        let raw = """
        Alice: Hello there.
        Bob: General Kenobi.
        """

        let segments = TranscriptFileParser.parse(raw)
        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments.map(\.speakerLabel), ["Alice", "Bob"])
        XCTAssertEqual(segments.map(\.text), ["Hello there.", "General Kenobi."])
        // No timestamps in this format → all zero.
        XCTAssertEqual(segments.map(\.start), [0, 0])
    }

    // MARK: - Timestamped lines

    func testLeadingTimestampLinesAreParsed() {
        let raw = """
        [00:00] Opening remarks.
        00:01:15 Discussion of the budget.
        1:02 Wrap up.
        """

        let segments = TranscriptFileParser.parse(raw)
        XCTAssertEqual(segments.count, 3)
        XCTAssertEqual(segments.map(\.start), [0, 75, 62])
        XCTAssertEqual(segments[0].text, "Opening remarks.")
        XCTAssertEqual(segments[1].text, "Discussion of the budget.")
    }

    func testTimestampWithSpeakerPrefixExtractsBoth() {
        let raw = "[00:10] Alice: The metrics look good."
        let segments = TranscriptFileParser.parse(raw)
        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments[0].start, 10)
        XCTAssertEqual(segments[0].speakerLabel, "Alice")
        XCTAssertEqual(segments[0].text, "The metrics look good.")
    }

    // MARK: - Malformed lines skipped

    func testMalformedTimestampFallsBackRatherThanCrashing() {
        // 99:99 is not a valid timestamp; the line is treated as plain text, not dropped entirely.
        let raw = """
        Alice  00:00:05
        A valid line.

        99:99:99 not a real time but still words
        """
        let segments = TranscriptFileParser.parse(raw)
        XCTAssertFalse(segments.isEmpty)
        XCTAssertTrue(segments.contains { $0.text.contains("A valid line.") })
        XCTAssertTrue(segments.contains { $0.text.contains("not a real time but still words") })
    }

    func testEmptyInputProducesNoSegments() {
        XCTAssertTrue(TranscriptFileParser.parse("").isEmpty)
        XCTAssertTrue(TranscriptFileParser.parse("   \n\n  \n").isEmpty)
    }

    // MARK: - Plain text (no structure, no times)

    func testPlainTextParagraphsBecomeSegmentsWithoutTimesOrSpeakers() {
        let raw = """
        This is a plain note about the meeting with no structure at all.
        It spans two lines in the same paragraph.

        A second paragraph after a blank line stands on its own.
        """

        let segments = TranscriptFileParser.parse(raw)
        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(
            segments[0].text,
            "This is a plain note about the meeting with no structure at all. It spans two lines in the same paragraph."
        )
        XCTAssertEqual(segments[1].text, "A second paragraph after a blank line stands on its own.")
        XCTAssertTrue(segments.allSatisfy { $0.speakerLabel == nil })
        XCTAssertTrue(segments.allSatisfy { $0.start == 0 && $0.end == 0 })
    }

    func testSinglePlainParagraphBecomesOneSegment() {
        let raw = "Just one line of plain text."
        let segments = TranscriptFileParser.parse(raw)
        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments[0].text, "Just one line of plain text.")
        XCTAssertNil(segments[0].speakerLabel)
    }

    // MARK: - Timestamp helper

    func testParseTimestamp() {
        XCTAssertEqual(TranscriptFileParser.parseTimestamp("00:00:05"), 5)
        XCTAssertEqual(TranscriptFileParser.parseTimestamp("1:02"), 62)
        XCTAssertEqual(TranscriptFileParser.parseTimestamp("2:03:04"), 2 * 3600 + 3 * 60 + 4)
        XCTAssertNil(TranscriptFileParser.parseTimestamp("00:99"))
        XCTAssertNil(TranscriptFileParser.parseTimestamp("not-a-time"))
        XCTAssertNil(TranscriptFileParser.parseTimestamp("12"))
    }
}
