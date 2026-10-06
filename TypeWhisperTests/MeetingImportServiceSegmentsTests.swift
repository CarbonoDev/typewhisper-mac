import XCTest
@testable import TypeWhisper

/// The segment-taking import entry points (perf plan: parse a Drive transcript once). Each must
/// write exactly what its text-taking twin writes for the same content — the Drive importer now
/// parses off the main actor and hands segments over, while the file-import UI keeps the text API.
@MainActor
final class MeetingImportServiceSegmentsTests: XCTestCase {
    private final class StubTranscriber: MeetingAudioTranscribing {
        func transcribeImportedAudio(
            samples: [Float],
            languageSelection: LanguageSelection
        ) async throws -> TranscriptionResult {
            TranscriptionResult(
                text: "", detectedLanguage: "en", duration: 0, processingTime: 0,
                engineUsed: "stub", segments: []
            )
        }
    }

    private static let timedTranscript = """
    ### **00:01:10**

    **Ana:** Hola, ¿cómo estás?

    ### **00:01:14**

    **Beto:** Bien, gracias.
    """

    private func makeServices() throws -> (MeetingService, MeetingImportService) {
        let dir = try TestSupport.makeTemporaryDirectory(prefix: "ImportSegments")
        addTeardownBlock { TestSupport.remove(dir) }
        let meetingService = MeetingService(appSupportDirectory: dir)
        let importService = MeetingImportService(
            meetingService: meetingService, audioFileService: AudioFileService(), transcriber: StubTranscriber()
        )
        return (meetingService, importService)
    }

    private func rows(_ meeting: Meeting) -> [String] {
        meeting.segments.sorted { $0.order < $1.order }.map { "\($0.start)-\($0.end) \($0.source) \($0.text)" }
    }

    func testImportSegmentsWritesWhatImportTextWrites() throws {
        let (_, importService) = try makeServices()
        let start = Date(timeIntervalSince1970: 1_780_000_000)

        let fromText = try importService.importTranscriptText(Self.timedTranscript, title: "Sync", startDate: start)
        let fromSegments = try importService.importTranscriptSegments(
            TranscriptFileParser.parse(Self.timedTranscript), title: "Sync", startDate: start
        )

        XCTAssertEqual(rows(fromSegments), rows(fromText))
        XCTAssertFalse(rows(fromText).isEmpty)
        XCTAssertEqual(fromSegments.title, fromText.title)
        XCTAssertEqual(fromSegments.startDate, fromText.startDate)
        XCTAssertEqual(fromSegments.source, fromText.source)
    }

    func testEmptySegmentsThrowEmptyTranscriptLikeTheTextPaths() throws {
        let (meetingService, importService) = try makeServices()
        let meeting = meetingService.createMeeting(title: "Target", state: .completed)

        XCTAssertThrowsError(try importService.importTranscriptSegments([])) {
            XCTAssertEqual($0 as? MeetingImportService.ImportError, .emptyTranscript)
        }
        XCTAssertThrowsError(try importService.mergeTranscriptSegments([], into: meeting))
        XCTAssertThrowsError(try importService.mergeOrSupersedeTranscriptSegments([], into: meeting))
        XCTAssertTrue(meeting.segments.isEmpty)
    }

    /// The supersede rule over segments: a timed transcript replaces a summary-shaped import...
    func testMergeOrSupersedeSegmentsReplacesAnUntimedSummaryImport() throws {
        let (meetingService, importService) = try makeServices()
        let meeting = try importService.importTranscriptText("Resumen\n\nDecisiones tomadas.", title: "Repair")
        XCTAssertTrue(meeting.segments.allSatisfy { $0.start == 0 && $0.end == 0 }, "fixture: untimed import")
        let summaryRows = meeting.segments.count

        let dropped = try importService.mergeOrSupersedeTranscriptSegments(
            TranscriptFileParser.parse(Self.timedTranscript), into: meeting
        )

        XCTAssertEqual(dropped, summaryRows)
        XCTAssertEqual(meeting.segments.map(\.text).sorted(), ["Bien, gracias.", "Hola, ¿cómo estás?"])
        XCTAssertEqual(meetingService.meetings.count, 1)
    }

    /// ...and otherwise merges exactly as the text path does.
    func testMergeOrSupersedeSegmentsMergesLikeTheTextPath() throws {
        let (meetingService, importService) = try makeServices()
        let viaText = meetingService.createMeeting(title: "A", state: .completed)
        let viaSegments = meetingService.createMeeting(title: "B", state: .completed)
        for meeting in [viaText, viaSegments] {
            meetingService.appendStableSegments(
                [TranscriptionSegment(text: "live line", start: 300, end: 302)], source: .liveCapture, to: meeting
            )
        }

        let droppedText = try importService.mergeOrSupersedeTranscriptText(Self.timedTranscript, into: viaText)
        let droppedSegments = try importService.mergeOrSupersedeTranscriptSegments(
            TranscriptFileParser.parse(Self.timedTranscript), into: viaSegments
        )

        XCTAssertEqual(droppedSegments, droppedText)
        XCTAssertEqual(rows(viaSegments), rows(viaText))
        XCTAssertEqual(viaSegments.segments.count, 3, "live row kept, two imported rows merged")
    }
}
