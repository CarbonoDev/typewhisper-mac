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

    // MARK: - Gemini Notes export (synthetic fixture)

    /// A synthetic "Notas de Gemini" document in the real export's shape: date line, escaped-dash
    /// bold title heading, `### **HH:MM:SS**` section headers, `**Name:** utterance` turns, a
    /// closing "finalizó después de" line, and the trailing italic disclaimer.
    private let geminiFixture = """
    jul 22, 2026

    ## **Retro Proyecto Fénix \\- Transcripción**

    ### **00:00:10**

    **Lucía Herrera:** Hola a todos, gracias por conectarse a la retro de hoy.

    **Pablo Ríos:** Hola,

    **Lucía Herrera:** empecemos.

    ### **00:01:10**

    **Pablo Ríos:** El despliegue quedó listo ayer y revisamos los registros sin encontrar errores nuevos.

    **Marta Vidal:** Quedan 13\\. pendientes en la lista, todos de prioridad baja \\- nada urgente.

    ### **La transcripción finalizó después de 00:02:10**

    *Esta transcripción editable se generó por computadora y puede contener errores. Los usuarios también pueden cambiar el texto después de que se cree.*
    """

    func testGeminiNotesExportParsesSpeakersAndInterpolatedTimes() {
        let segments = TranscriptFileParser.parse(geminiFixture)

        XCTAssertEqual(segments.count, 5)
        XCTAssertEqual(
            segments.map(\.speakerLabel),
            ["Lucía Herrera", "Pablo Ríos", "Lucía Herrera", "Pablo Ríos", "Marta Vidal"]
        )
        XCTAssertEqual(segments[0].text, "Hola a todos, gracias por conectarse a la retro de hoy.")
        XCTAssertEqual(segments[1].text, "Hola,")

        // Each section's first turn starts exactly at the section header time.
        XCTAssertEqual(segments[0].start, 10)
        XCTAssertEqual(segments[3].start, 70)
        // Later turns interpolate strictly inside their section (length-weighted).
        XCTAssertGreaterThan(segments[1].start, 10)
        XCTAssertGreaterThan(segments[2].start, segments[1].start)
        XCTAssertLessThan(segments[2].start, 70)
        XCTAssertGreaterThan(segments[4].start, 70)
        XCTAssertLessThan(segments[4].start, 130)
        // The closing line's total duration bounds the last turn.
        XCTAssertEqual(segments[4].end, 130)
        // Starts are monotonic and ends backfill from the following start.
        for index in 1..<segments.count {
            XCTAssertGreaterThanOrEqual(segments[index].start, segments[index - 1].start)
            XCTAssertEqual(segments[index - 1].end, segments[index].start)
        }
    }

    func testGeminiNotesExcludesHeadingsDateAndDisclaimer() {
        let segments = TranscriptFileParser.parse(geminiFixture)
        for segment in segments {
            XCTAssertFalse(segment.text.contains("Transcripción"), "title heading must not become a segment")
            XCTAssertFalse(segment.text.contains("Retro Proyecto Fénix"), "escaped-dash title must not become a segment")
            XCTAssertFalse(segment.text.contains("jul 22"), "date line must not become a segment")
            XCTAssertFalse(segment.text.contains("editable"), "disclaimer must not become a segment")
            XCTAssertFalse(segment.text.contains("finalizó"), "closing line must not become a segment")
            XCTAssertNotNil(segment.speakerLabel)
        }
    }

    func testGeminiNotesUnescapesMarkdownInUtterances() {
        let segments = TranscriptFileParser.parse(geminiFixture)
        // `13\.` and `\-` in the source are unescaped inside the Gemini rung only.
        XCTAssertEqual(
            segments[4].text,
            "Quedan 13. pendientes en la lista, todos de prioridad baja - nada urgente."
        )
    }

    func testGeminiNotesWithoutClosingLineCarriesSectionStartForLastSection() {
        let raw = """
        ## **Sync Semanal \\- Transcript**

        ### **00:00:30**

        **Ana Solís:** Primer punto de la agenda.

        **Iván Cano:** De acuerdo, seguimos.
        """
        let segments = TranscriptFileParser.parse(raw)
        XCTAssertEqual(segments.count, 2)
        // No forward boundary: both turns carry the section start (no invented interpolation).
        XCTAssertEqual(segments.map(\.start), [30, 30])
        XCTAssertEqual(segments.map(\.speakerLabel), ["Ana Solís", "Iván Cano"])
    }

    func testGeminiDetectionDoesNotHijackPlainMarkdownNotes() {
        // Bold text and headings alone — no bold speaker turns — must fall through to the
        // plain-text rung, untouched by the Gemini markdown stripping.
        let raw = """
        ## **Notes**

        Some **bold** remark in a plain note.
        """
        let segments = TranscriptFileParser.parse(raw)
        XCTAssertEqual(segments.count, 2)
        XCTAssertTrue(segments.contains { $0.text.contains("**bold**") })
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
