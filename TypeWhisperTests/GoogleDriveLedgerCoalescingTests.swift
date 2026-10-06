import AppKit
import XCTest
@testable import TypeWhisper

/// Perf plan Phase 2 — the Drive import ledger's coalesced writes and the off-main content gate.
///
/// The contract under test: a lost (not yet flushed) ledger write may only ever cost a redundant
/// re-check — never a duplicate import and never a permanently skipped transcript. A "crash" is
/// simulated by dropping the ledger without `flush()` and building a new one from the same file,
/// which is exactly what a relaunch reads.
@MainActor
final class GoogleDriveLedgerCoalescingTests: XCTestCase {
    // MARK: - Fakes

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

    /// Serves queued export bodies in order, one per request.
    private final class QueuedExportTransport: GoogleHTTPTransport, @unchecked Sendable {
        private let lock = NSLock()
        private var bodies: [String]

        init(bodies: [String]) { self.bodies = bodies }

        private func next() -> String? {
            lock.lock()
            defer { lock.unlock() }
            return bodies.isEmpty ? nil : bodies.removeFirst()
        }

        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            guard let body = next() else { throw URLError(.unsupportedURL) }
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
            return (Data(body.utf8), response)
        }
    }

    // MARK: - Fixtures

    private static let transcriptMarkdown = """
    ## **Llamada de Prueba \\- Transcripción**

    ### **00:04:00**

    **Nora Ibáñez:** Frase importada uno sobre el avance.

    **Teo Salas:** Frase importada dos con otra redacción.

    ### **La transcripción finalizó después de 00:08:00**
    """

    /// Gemini's summary shape: headings and bullets, no timing anywhere.
    private static let summaryMarkdown = """
    # **📝 Las notas**

    ### **Resumen**

    Tablero GDA y migración incremental.

    ### **Decisiones**

    * Lanzar la migración el lunes.
    """

    private let datedName = "Weekly sync - 2026_07_07 11_00 UTC - Notas de Gemini"
    private let fixedNow = Date(timeIntervalSince1970: 1_770_000_000)
    private let longDelay: Duration = .seconds(3_600)

    private func makeFile(id: String, modified: Date) throws -> GoogleDriveAPI.GDriveFile {
        let json = #"{"id": "\#(id)", "name": "\#(datedName)", "mimeType": "application/vnd.google-apps.document", "modifiedTime": "\#(GoogleCalendarAPI.rfc3339String(modified))"}"#
        return try JSONDecoder().decode(GoogleDriveAPI.GDriveFile.self, from: Data(json.utf8))
    }

    private func ledgerURL(in dir: URL) -> URL {
        dir.appendingPathComponent("google-drive-imports.json")
    }

    private func makeImporter(
        meetingService: MeetingService,
        ledger: GoogleDriveImportLedger,
        exports: [String]
    ) -> GoogleDriveTranscriptImporter {
        GoogleDriveTranscriptImporter(
            tokenProvider: FakeTokenProvider(),
            transport: QueuedExportTransport(bodies: exports),
            importService: MeetingImportService(
                meetingService: meetingService, audioFileService: AudioFileService(), transcriber: StubTranscriber()
            ),
            meetingService: meetingService,
            autoLink: nil,
            ledger: ledger,
            now: { self.fixedNow }
        )
    }

    // MARK: - Coalescing

    func testMutationsCoalesceIntoOneDelayedWrite() async throws {
        let dir = try TestSupport.makeTemporaryDirectory(prefix: "LedgerCoalesce")
        defer { TestSupport.remove(dir) }
        let ledger = GoogleDriveImportLedger(fileURL: ledgerURL(in: dir), saveDelay: .milliseconds(100))

        for index in 0..<5 {
            ledger.recordImported(
                fileID: "google:sub-1:f\(index)", docModifiedTime: fixedNow,
                meetingID: UUID(), disposition: .created, now: fixedNow
            )
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: ledgerURL(in: dir).path), "no write per mutation")
        XCTAssertTrue(ledger.hasUnsavedChanges)

        try await Task.sleep(for: .milliseconds(500))

        XCTAssertFalse(ledger.hasUnsavedChanges)
        let reloaded = GoogleDriveImportLedger(fileURL: ledgerURL(in: dir))
        XCTAssertEqual(reloaded.entries.count, 5, "one delayed write carried every mutation")
    }

    func testFlushAndTerminationWriteImmediately() throws {
        let dir = try TestSupport.makeTemporaryDirectory(prefix: "LedgerCoalesce")
        defer { TestSupport.remove(dir) }
        let ledger = GoogleDriveImportLedger(fileURL: ledgerURL(in: dir), saveDelay: longDelay)

        ledger.recordImported(fileID: "google:sub-1:a", docModifiedTime: fixedNow, meetingID: UUID(), disposition: .created, now: fixedNow)
        ledger.flush()
        XCTAssertNotNil(GoogleDriveImportLedger(fileURL: ledgerURL(in: dir)).entry(for: "google:sub-1:a"))

        ledger.recordImported(fileID: "google:sub-1:b", docModifiedTime: fixedNow, meetingID: UUID(), disposition: .created, now: fixedNow)
        NotificationCenter.default.post(name: NSApplication.willTerminateNotification, object: nil)
        XCTAssertNotNil(
            GoogleDriveImportLedger(fileURL: ledgerURL(in: dir)).entry(for: "google:sub-1:b"),
            "app termination flushes pending writes"
        )
    }

    /// The two writes whose loss would not self-heal bypass the debounce.
    func testFirstWatermarkSeedAndForgetCycleStateWriteThrough() throws {
        let dir = try TestSupport.makeTemporaryDirectory(prefix: "LedgerCoalesce")
        defer { TestSupport.remove(dir) }
        let ledger = GoogleDriveImportLedger(fileURL: ledgerURL(in: dir), saveDelay: longDelay)
        let seed = fixedNow
        let advanced = fixedNow.addingTimeInterval(900)

        ledger.setWatermark(seed, forSub: "sub-1")
        XCTAssertEqual(
            try XCTUnwrap(GoogleDriveImportLedger(fileURL: ledgerURL(in: dir)).watermark(forSub: "sub-1"))
                .timeIntervalSince1970, seed.timeIntervalSince1970, accuracy: 1,
            "a first seed is on disk at once"
        )

        ledger.setWatermark(advanced, forSub: "sub-1")
        XCTAssertEqual(
            try XCTUnwrap(GoogleDriveImportLedger(fileURL: ledgerURL(in: dir)).watermark(forSub: "sub-1"))
                .timeIntervalSince1970, seed.timeIntervalSince1970, accuracy: 1,
            "an advance is coalesced (losing it only re-checks files)"
        )

        ledger.forgetCycleState(forSub: "sub-1")
        XCTAssertNil(GoogleDriveImportLedger(fileURL: ledgerURL(in: dir)).watermark(forSub: "sub-1"))
    }

    // MARK: - Crash between debounce and flush

    /// A crash loses the unflushed tail, and the file holds an earlier **consistent** state: a
    /// watermark advanced after an import never reaches disk without that import's entry.
    func testCrashLeavesAnEarlierConsistentSnapshot() throws {
        let dir = try TestSupport.makeTemporaryDirectory(prefix: "LedgerCoalesce")
        defer { TestSupport.remove(dir) }
        let seed = fixedNow.addingTimeInterval(-3_600)
        do {
            let ledger = GoogleDriveImportLedger(fileURL: ledgerURL(in: dir), saveDelay: longDelay)
            ledger.setWatermark(seed, forSub: "sub-1") // first seed: on disk
            ledger.recordImported(fileID: "google:sub-1:f1", docModifiedTime: fixedNow, meetingID: UUID(), disposition: .created, now: fixedNow)
            ledger.setWatermark(fixedNow, forSub: "sub-1")
            // Crash: dropped without a flush.
        }

        let relaunched = GoogleDriveImportLedger(fileURL: ledgerURL(in: dir))
        XCTAssertNil(relaunched.entry(for: "google:sub-1:f1"))
        XCTAssertEqual(
            try XCTUnwrap(relaunched.watermark(forSub: "sub-1")).timeIntervalSince1970,
            seed.timeIntervalSince1970, accuracy: 1,
            "the watermark is still below the lost import, so discovery re-surfaces the file"
        )
    }

    /// End to end: an import lands in the meeting store, the ledger write is lost to a crash, and
    /// the relaunch's replay of the same doc merges into the meeting it already created — no
    /// duplicate meeting, no duplicated rows — and is then ledgered.
    func testLostLedgerWriteReplaysAsANoOpMergeNotADuplicate() async throws {
        let dir = try TestSupport.makeTemporaryDirectory(prefix: "LedgerCoalesce")
        defer { TestSupport.remove(dir) }
        let meetingService = MeetingService(appSupportDirectory: dir)
        let file = try makeFile(id: "f1", modified: fixedNow)

        let firstLedger = GoogleDriveImportLedger(fileURL: ledgerURL(in: dir), saveDelay: longDelay)
        let first = await makeImporter(meetingService: meetingService, ledger: firstLedger, exports: [Self.transcriptMarkdown])
            .processFile(file, sub: "sub-1", ownsPendingEntry: false)
        guard case .created(let meetingID) = first else { return XCTFail("expected created, got \(first)") }
        XCTAssertTrue(firstLedger.hasUnsavedChanges, "the entry is still only in memory")
        let segmentCount = meetingService.meetings[0].segments.count

        // Crash before the debounce fired: the relaunch reads the file, which lacks the entry.
        let relaunched = GoogleDriveImportLedger(fileURL: ledgerURL(in: dir), saveDelay: longDelay)
        XCTAssertEqual(relaunched.action(for: file, sub: "sub-1", now: fixedNow), .importNew, "re-checked, not lost")

        let replay = await makeImporter(meetingService: meetingService, ledger: relaunched, exports: [Self.transcriptMarkdown])
            .processFile(file, sub: "sub-1", ownsPendingEntry: false)

        guard case .merged(let replayedID, _) = replay else { return XCTFail("expected merge, got \(replay)") }
        XCTAssertEqual(replayedID, meetingID)
        XCTAssertEqual(meetingService.meetings.count, 1, "no duplicate meeting")
        XCTAssertEqual(meetingService.meetings[0].segments.count, segmentCount, "no duplicated rows")
        XCTAssertEqual(relaunched.action(for: file, sub: "sub-1", now: fixedNow), .skip, "ledgered now")
    }

    /// A summary doc is skipped without any ledger write, so no crash can turn it into a permanent
    /// skip: once Gemini appends the transcript (a later edit), the same doc imports.
    func testSkippedSummaryDocStaysReexaminableAcrossACrash() async throws {
        let dir = try TestSupport.makeTemporaryDirectory(prefix: "LedgerCoalesce")
        defer { TestSupport.remove(dir) }
        let meetingService = MeetingService(appSupportDirectory: dir)

        let ledger = GoogleDriveImportLedger(fileURL: ledgerURL(in: dir), saveDelay: longDelay)
        let summaryPass = await makeImporter(meetingService: meetingService, ledger: ledger, exports: [Self.summaryMarkdown])
            .processFile(try makeFile(id: "f1", modified: fixedNow), sub: "sub-1", ownsPendingEntry: false)
        XCTAssertEqual(summaryPass, .skipped)
        XCTAssertNil(ledger.entry(for: "google:sub-1:f1"))
        XCTAssertNil(ledger.failures["google:sub-1:f1"])
        XCTAssertTrue(meetingService.meetings.isEmpty)

        // Crash, relaunch, and the doc is edited with the transcript appended.
        let relaunched = GoogleDriveImportLedger(fileURL: ledgerURL(in: dir), saveDelay: longDelay)
        let edited = try makeFile(id: "f1", modified: fixedNow.addingTimeInterval(600))
        XCTAssertEqual(relaunched.action(for: edited, sub: "sub-1", now: fixedNow), .importNew)
        let transcriptPass = await makeImporter(
            meetingService: meetingService, ledger: relaunched,
            exports: [Self.summaryMarkdown + "\n\n" + Self.transcriptMarkdown]
        ).processFile(edited, sub: "sub-1", ownsPendingEntry: false)

        guard case .created = transcriptPass else { return XCTFail("expected created, got \(transcriptPass)") }
    }

    func testBackfillEndFlushesTheLedger() async throws {
        let dir = try TestSupport.makeTemporaryDirectory(prefix: "LedgerCoalesce")
        defer { TestSupport.remove(dir) }
        let meetingService = MeetingService(appSupportDirectory: dir)
        let ledger = GoogleDriveImportLedger(fileURL: ledgerURL(in: dir), saveDelay: longDelay)
        let importer = makeImporter(meetingService: meetingService, ledger: ledger, exports: [Self.transcriptMarkdown])

        let summary = await importer.runBackfill(
            files: [try makeFile(id: "f1", modified: fixedNow)], sub: "sub-1", pause: { _ in }
        )

        XCTAssertEqual(summary.imported, 1)
        XCTAssertFalse(ledger.hasUnsavedChanges)
        XCTAssertNotNil(GoogleDriveImportLedger(fileURL: ledgerURL(in: dir)).entry(for: "google:sub-1:f1"))
    }

    // MARK: - Off-main content gate

    /// The off-main gate decides exactly as the former inline check did.
    func testSummaryGateMatchesTheInlineRule() async {
        func inlineRule(_ text: String, _ isMarkdown: Bool) -> Bool {
            let parsed = TranscriptFileParser.parse(text)
            return isMarkdown && !parsed.isEmpty && !MeetingImportService.carriesRecoverableTiming(parsed)
        }
        let texts = [Self.summaryMarkdown, Self.transcriptMarkdown, Self.summaryMarkdown + "\n\n" + Self.transcriptMarkdown, ""]
        for text in texts {
            for isMarkdown in [true, false] {
                let offMain = await GoogleDriveTranscriptImporter.isSummaryOnlyExport(text, isMarkdownExport: isMarkdown)
                XCTAssertEqual(offMain, inlineRule(text, isMarkdown), "diverged for markdown=\(isMarkdown): \(text.prefix(30))")
            }
        }
        let summaryGated = await GoogleDriveTranscriptImporter.isSummaryOnlyExport(Self.summaryMarkdown, isMarkdownExport: true)
        XCTAssertTrue(summaryGated, "fixture sanity: the summary is gated")
    }
}
