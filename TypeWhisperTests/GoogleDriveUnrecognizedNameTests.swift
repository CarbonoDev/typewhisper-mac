import XCTest
@testable import TypeWhisper

/// A Drive doc name whose date shape `ImportedMeetingTitle` does not recognize is logged once (at
/// `.info`, name private) by the importer, so the next unknown export format is diagnosable.
@MainActor
final class GoogleDriveUnrecognizedNameTests: XCTestCase {
    private final class FakeTokenProvider: GoogleAccessTokenProviding {
        func accessToken(for accountID: String) async throws -> String { "token-\(accountID)" }
    }

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

    private final class UnusedTransport: GoogleHTTPTransport, @unchecked Sendable {
        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            throw URLError(.unsupportedURL)
        }
    }

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GoogleDriveUnrecognizedNameTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeImporter() -> GoogleDriveTranscriptImporter {
        let meetingService = MeetingService(appSupportDirectory: directory)
        return GoogleDriveTranscriptImporter(
            tokenProvider: FakeTokenProvider(),
            transport: UnusedTransport(),
            importService: MeetingImportService(
                meetingService: meetingService, audioFileService: AudioFileService(), transcriber: StubTranscriber()
            ),
            meetingService: meetingService,
            autoLink: nil,
            ledger: GoogleDriveImportLedger(fileURL: directory.appendingPathComponent("google-drive-imports.json"))
        )
    }

    func testRecognizedDriveShapesAreNotFlagged() {
        for name in [
            "Seguimiento BD Daniel - 2026/04/02 09:00 CST",
            "Seguimiento semanal - 2025/10/08 06:56 WITA",
            "Meet – 23 Jul 2026 at 14:06",
            "Weekly sync - 2026_07_07 11_00 UTC - Notes by Gemini",
        ] {
            XCTAssertFalse(GoogleDriveTranscriptImporter.isUnrecognizedNameShape(name), name)
        }
    }

    func testUnknownShapeIsLoggedOncePerName() {
        let importer = makeImporter()
        let unknown = "Sync – 2026.04.02 9h00 – Notes by Gemini"
        XCTAssertTrue(GoogleDriveTranscriptImporter.isUnrecognizedNameShape(unknown))

        XCTAssertTrue(importer.noteUnrecognizedNameShape(unknown))
        XCTAssertFalse(importer.noteUnrecognizedNameShape(unknown), "a re-polled name is not logged again")
        XCTAssertFalse(importer.noteUnrecognizedNameShape("Seguimiento BD Daniel - 2026/04/02 09:00 CST"))
        XCTAssertTrue(importer.noteUnrecognizedNameShape("Another – 02.04.2026 – Notes by Gemini"))
    }
}
