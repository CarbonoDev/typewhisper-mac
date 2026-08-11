import XCTest
@testable import TypeWhisper

/// `GoogleDriveTranscriptImporter` end to end over fakes ([Google Phase 2 · M2]): fixture
/// markdown through merge vs create vs near-miss, the text/plain fallback, failure recording
/// (export errors and `.emptyTranscript`), re-merge + vanished-target touch, the calendar
/// auto-link, the D-D5/F2 write-order self-heal, and the D-D4/F6 two-sub atomicity property.
/// Real `MeetingService`/`MeetingImportService` over a temp-dir store; fake transport/tokens; no
/// network, no real Application Support.
@MainActor
final class GoogleDriveTranscriptImporterTests: XCTestCase {
    // MARK: - Fakes

    @MainActor
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

    @MainActor
    private final class FakeAutoLink: MeetingAutoLinking {
        var candidate: (event: CalendarEventDTO, score: Double)?
        private(set) var queried: [(title: String, date: Date)] = []

        func bestAutoLinkCandidate(
            title: String,
            date: Date,
            window: TimeInterval,
            minimumConfidence: Double
        ) -> (event: CalendarEventDTO, score: Double)? {
            queried.append((title, date))
            return candidate
        }
    }

    /// Substring-routed canned transport; an optional per-request delay lets the F6 test hold
    /// both exports in flight before either import's synchronous stretch runs.
    private final class FakeDriveTransport: GoogleHTTPTransport, @unchecked Sendable {
        struct Stub {
            let urlContains: String
            let statusCode: Int
            let body: String
        }

        private let lock = NSLock()
        private var stubs: [Stub]
        private let delayNanoseconds: UInt64

        init(stubs: [Stub], delayNanoseconds: UInt64 = 0) {
            self.stubs = stubs
            self.delayNanoseconds = delayNanoseconds
        }

        private func match(_ request: URLRequest) -> Stub? {
            lock.lock()
            defer { lock.unlock() }
            let url = request.url?.absoluteString ?? ""
            guard let index = stubs.firstIndex(where: { url.contains($0.urlContains) }) else {
                return nil
            }
            return stubs.remove(at: index)
        }

        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            if delayNanoseconds > 0 {
                try await Task.sleep(nanoseconds: delayNanoseconds)
            }
            guard let stub = match(request) else {
                throw URLError(.unsupportedURL)
            }
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: stub.statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: nil
            )!
            return (Data(stub.body.utf8), response)
        }
    }

    // MARK: - Fixtures

    /// The verified Gemini markdown shape (D-D3): title heading, `### **HH:MM:SS**` sections,
    /// `**Speaker:** utterance` turns, closing "finalizó" line — covering 00:04:00–00:08:00.
    private static let geminiMarkdown = """
    ## **Llamada de Prueba \\- Transcripción**

    ### **00:04:00**

    **Nora Ibáñez:** Frase importada uno sobre el avance.

    **Teo Salas:** Frase importada dos con otra redacción.

    ### **La transcripción finalizó después de 00:08:00**

    *Esta transcripción editable se generó por computadora y puede contener errores.*
    """

    /// 2026-07-07 11:00:00 UTC — embedded in `datedName`.
    private let embeddedDate: Date = {
        var components = DateComponents()
        components.year = 2026; components.month = 7; components.day = 7
        components.hour = 11; components.minute = 0
        components.timeZone = TimeZone(identifier: "UTC")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: components)!
    }()

    private let datedName = "Weekly sync - 2026_07_07 11_00 UTC - Notas de Gemini"
    private let fixedNow = Date(timeIntervalSince1970: 1_770_000_000)

    private func makeFile(id: String, name: String, modified: Date? = nil, created: Date? = nil) throws -> GoogleDriveAPI.GDriveFile {
        let modifiedField = (modified ?? fixedNow)
        let createdField = created.map { #""createdTime": "\#(GoogleCalendarAPI.rfc3339String($0))", "# } ?? ""
        let json = #"{"id": "\#(id)", "name": "\#(name)", "mimeType": "application/vnd.google-apps.document", \#(createdField)"modifiedTime": "\#(GoogleCalendarAPI.rfc3339String(modifiedField))"}"#
        return try JSONDecoder().decode(GoogleDriveAPI.GDriveFile.self, from: Data(json.utf8))
    }

    // MARK: - Harness

    private struct Harness {
        let importer: GoogleDriveTranscriptImporter
        let meetingService: MeetingService
        let importService: MeetingImportService
        let ledger: GoogleDriveImportLedger
        let autoLink: FakeAutoLink
    }

    private func makeHarness(
        in directory: URL,
        transport: FakeDriveTransport,
        meetingService: MeetingService? = nil,
        ledgerFileName: String = "google-drive-imports.json"
    ) -> Harness {
        let service = meetingService ?? MeetingService(appSupportDirectory: directory)
        let importService = MeetingImportService(
            meetingService: service,
            audioFileService: AudioFileService(),
            transcriber: StubTranscriber()
        )
        let ledger = GoogleDriveImportLedger(fileURL: directory.appendingPathComponent(ledgerFileName))
        let autoLink = FakeAutoLink()
        let importer = GoogleDriveTranscriptImporter(
            tokenProvider: FakeTokenProvider(),
            transport: transport,
            importService: importService,
            meetingService: service,
            autoLink: autoLink,
            ledger: ledger,
            now: { self.fixedNow }
        )
        return Harness(
            importer: importer, meetingService: service, importService: importService,
            ledger: ledger, autoLink: autoLink
        )
    }

    private func exportStub(_ body: String, statusCode: Int = 200, fileID: String = "f1") -> FakeDriveTransport.Stub {
        .init(urlContains: "/files/\(fileID)/export", statusCode: statusCode, body: body)
    }

    // MARK: - Create / merge / near-miss (D-D4)

    func testNoMatchCreatesMeetingDatedFromFilename() async throws {
        let dir = try TestSupport.makeTemporaryDirectory(prefix: "DriveImporter")
        defer { TestSupport.remove(dir) }
        let h = makeHarness(in: dir, transport: FakeDriveTransport(stubs: [exportStub(Self.geminiMarkdown)]))
        let file = try makeFile(id: "f1", name: datedName)
        h.ledger.markPending(fileID: "google:sub-1:f1", modifiedTime: fixedNow)

        let outcome = await h.importer.processFile(file, sub: "sub-1")

        guard case .created(let meetingID) = outcome else {
            return XCTFail("expected created, got \(outcome)")
        }
        let meeting = try XCTUnwrap(h.meetingService.meetings.first { $0.id == meetingID })
        XCTAssertEqual(meeting.title, "Weekly sync")
        XCTAssertEqual(meeting.startDate, embeddedDate)
        XCTAssertEqual(meeting.source, .importedTranscript)
        XCTAssertEqual(meeting.segments.count, 2)
        // Ledger record (written AFTER the meeting, D-D5): disposition + pending cleared.
        let entry = try XCTUnwrap(h.ledger.entry(for: "google:sub-1:f1"))
        XCTAssertEqual(entry.disposition, "created")
        XCTAssertEqual(entry.meetingID, meetingID)
        XCTAssertTrue(h.ledger.pendingFileIDs.isEmpty)
    }

    /// The flagship collision (D-D4 disposition 1): a live-captioned meeting whose Gemini doc
    /// lands later — merged, not duplicated, with overlapped live rows replaced.
    func testConfidentMatchMergesAndDropsOverlappedLiveRows() async throws {
        let dir = try TestSupport.makeTemporaryDirectory(prefix: "DriveImporter")
        defer { TestSupport.remove(dir) }
        let h = makeHarness(in: dir, transport: FakeDriveTransport(stubs: [exportStub(Self.geminiMarkdown)]))
        let meeting = h.meetingService.createMeeting(
            title: "Weekly sync", source: .adHoc, state: .completed, startDate: embeddedDate
        )
        h.meetingService.appendStableSegments(
            [
                TranscriptionSegment(text: "Caption antes del rango.", start: 0, end: 30),
                TranscriptionSegment(text: "Caption dentro del rango.", start: 300, end: 330)
            ],
            source: .liveCaptions,
            to: meeting
        )

        let outcome = await h.importer.processFile(try makeFile(id: "f1", name: datedName), sub: "sub-1")

        guard case .merged(let meetingID, let dropped) = outcome else {
            return XCTFail("expected merged, got \(outcome)")
        }
        XCTAssertEqual(meetingID, meeting.id)
        XCTAssertEqual(dropped, 1, "the in-span caption yields to the timed import")
        XCTAssertEqual(h.meetingService.meetings.count, 1, "merged, never duplicated")
        let texts = meeting.segments.sorted { $0.order < $1.order }.map(\.text)
        XCTAssertTrue(texts.contains("Caption antes del rango."))
        XCTAssertFalse(texts.contains("Caption dentro del rango."))
        XCTAssertTrue(texts.contains("Frase importada uno sobre el avance."))
        XCTAssertEqual(h.ledger.entry(for: "google:sub-1:f1")?.disposition, "merged")
    }

    func testNearMissCreatesASecondMeeting() async throws {
        let dir = try TestSupport.makeTemporaryDirectory(prefix: "DriveImporter")
        defer { TestSupport.remove(dir) }
        let h = makeHarness(in: dir, transport: FakeDriveTransport(stubs: [exportStub(Self.geminiMarkdown)]))
        h.meetingService.createMeeting(
            title: "Quarterly planning offsite", source: .adHoc, state: .completed, startDate: embeddedDate
        )

        let outcome = await h.importer.processFile(try makeFile(id: "f1", name: datedName), sub: "sub-1")

        guard case .created = outcome else {
            return XCTFail("expected created, got \(outcome)")
        }
        XCTAssertEqual(h.meetingService.meetings.count, 2,
                       "below threshold never auto-merges — a duplicate is visible and foldable")
    }

    // MARK: - Export fallback + failures (D-D3 / D-D5)

    func testPlainTextFallbackWhenMarkdownExportRejected() async throws {
        let dir = try TestSupport.makeTemporaryDirectory(prefix: "DriveImporter")
        defer { TestSupport.remove(dir) }
        let transport = FakeDriveTransport(stubs: [
            exportStub("mime not supported", statusCode: 400),
            exportStub("Nora: Contenido degradado uno.\nTeo: Contenido degradado dos."),
        ])
        let h = makeHarness(in: dir, transport: transport)

        let outcome = await h.importer.processFile(try makeFile(id: "f1", name: datedName), sub: "sub-1")

        guard case .created(let meetingID) = outcome else {
            return XCTFail("expected created via fallback, got \(outcome)")
        }
        let meeting = try XCTUnwrap(h.meetingService.meetings.first { $0.id == meetingID })
        XCTAssertEqual(meeting.segments.count, 2, "degraded but landed")
    }

    func testExportFailureRecordsCappedFailure() async throws {
        let dir = try TestSupport.makeTemporaryDirectory(prefix: "DriveImporter")
        defer { TestSupport.remove(dir) }
        let transport = FakeDriveTransport(stubs: [exportStub("quota", statusCode: 500)])
        let h = makeHarness(in: dir, transport: transport)
        h.ledger.markPending(fileID: "google:sub-1:f1", modifiedTime: fixedNow)

        let outcome = await h.importer.processFile(try makeFile(id: "f1", name: datedName), sub: "sub-1")

        guard case .failed = outcome else {
            return XCTFail("expected failed, got \(outcome)")
        }
        XCTAssertEqual(h.ledger.failures["google:sub-1:f1"]?.attempts, 1)
        XCTAssertTrue(h.ledger.pendingFileIDs.isEmpty, "a failure leaves the pending set")
        XCTAssertTrue(h.meetingService.meetings.isEmpty)
    }

    func testEmptyTranscriptRecordsFailure() async throws {
        let dir = try TestSupport.makeTemporaryDirectory(prefix: "DriveImporter")
        defer { TestSupport.remove(dir) }
        let h = makeHarness(in: dir, transport: FakeDriveTransport(stubs: [exportStub("   \n\n  ")]))

        let outcome = await h.importer.processFile(try makeFile(id: "f1", name: datedName), sub: "sub-1")

        guard case .failed = outcome else {
            return XCTFail("expected failed, got \(outcome)")
        }
        XCTAssertEqual(h.ledger.failures["google:sub-1:f1"]?.attempts, 1)
    }

    // MARK: - Re-merge (D-D5)

    func testEditedDocRemergesIntoRecordedMeetingWithoutDuplicates() async throws {
        let dir = try TestSupport.makeTemporaryDirectory(prefix: "DriveImporter")
        defer { TestSupport.remove(dir) }
        let h = makeHarness(in: dir, transport: FakeDriveTransport(stubs: [
            exportStub(Self.geminiMarkdown),
            exportStub(Self.geminiMarkdown),
        ]))
        let file = try makeFile(id: "f1", name: datedName)

        // First import creates; the "edited" replay re-exports identical content.
        let first = await h.importer.processFile(file, sub: "sub-1")
        guard case .created(let meetingID) = first else {
            return XCTFail("expected created, got \(first)")
        }
        let segmentCount = h.meetingService.meetings[0].segments.count

        let editedTime = fixedNow.addingTimeInterval(600)
        let edited = try makeFile(id: "f1", name: datedName, modified: editedTime)
        let second = await h.importer.processFile(edited, sub: "sub-1")

        XCTAssertEqual(second, .remerged(meetingID: meetingID))
        XCTAssertEqual(h.meetingService.meetings.count, 1)
        XCTAssertEqual(h.meetingService.meetings[0].segments.count, segmentCount,
                       "TranscriptMerger dedupes the identical rows — idempotent by construction")
        XCTAssertEqual(h.ledger.entry(for: "google:sub-1:f1")?.docModifiedTime, editedTime)
    }

    func testVanishedRemergeTargetTouchesAndMarksDeleted() async throws {
        let dir = try TestSupport.makeTemporaryDirectory(prefix: "DriveImporter")
        defer { TestSupport.remove(dir) }
        let h = makeHarness(in: dir, transport: FakeDriveTransport(stubs: [exportStub(Self.geminiMarkdown)]))
        let editedTime = fixedNow.addingTimeInterval(600)
        // A ledgered import whose meeting has since been deleted by the user.
        h.ledger.recordImported(
            fileID: "google:sub-1:f1", docModifiedTime: fixedNow,
            meetingID: UUID(), disposition: .created, now: fixedNow
        )

        let outcome = await h.importer.processFile(
            try makeFile(id: "f1", name: datedName, modified: editedTime), sub: "sub-1"
        )

        XCTAssertEqual(outcome, .touched)
        XCTAssertTrue(h.meetingService.meetings.isEmpty, "a deleted meeting stays deleted")
        let entry = try XCTUnwrap(h.ledger.entry(for: "google:sub-1:f1"))
        XCTAssertNil(entry.meetingID)
        XCTAssertEqual(entry.docModifiedTime, editedTime, "the edit is acknowledged, never re-churned")
    }

    // MARK: - Auto-link (D-D4 disposition 2)

    func testCreateAttemptsCalendarAutoLinkWithInWindowEvent() async throws {
        let dir = try TestSupport.makeTemporaryDirectory(prefix: "DriveImporter")
        defer { TestSupport.remove(dir) }
        let h = makeHarness(in: dir, transport: FakeDriveTransport(stubs: [exportStub(Self.geminiMarkdown)]))
        let event = CalendarEventDTO(
            id: "google:sub-1:evt-1",
            title: "Weekly sync",
            startDate: embeddedDate,
            endDate: embeddedDate.addingTimeInterval(3_600),
            attendees: [Attendee(name: "Nora Ibáñez", email: "nora@example.com")]
        )
        h.autoLink.candidate = (event, 1.0)

        let outcome = await h.importer.processFile(try makeFile(id: "f1", name: datedName), sub: "sub-1")

        guard case .created(let meetingID) = outcome else {
            return XCTFail("expected created, got \(outcome)")
        }
        XCTAssertEqual(h.autoLink.queried.first?.title, "Weekly sync")
        XCTAssertEqual(h.autoLink.queried.first?.date, embeddedDate)
        let meeting = try XCTUnwrap(h.meetingService.meetings.first { $0.id == meetingID })
        XCTAssertEqual(meeting.calendarEventID, "google:sub-1:evt-1", "event identity adopted")
        XCTAssertEqual(meeting.attendees.map(\.email), ["nora@example.com"], "attendees adopted")
    }

    // MARK: - Write-order self-heal (D-D5/F2)

    /// Meeting written, ledger write dropped (simulated as a fresh, empty ledger — the state a
    /// crash between the two writes leaves behind), replay: the matcher scores the just-created
    /// meeting at ~1.0, merges, and `TranscriptMerger` dedupes to a no-op — one meeting, zero
    /// duplicated rows.
    func testWriteOrderSelfHealReplayMergesWithoutDuplicates() async throws {
        let dir = try TestSupport.makeTemporaryDirectory(prefix: "DriveImporter")
        defer { TestSupport.remove(dir) }
        let transport = FakeDriveTransport(stubs: [
            exportStub(Self.geminiMarkdown),
            exportStub(Self.geminiMarkdown),
        ])
        let h1 = makeHarness(in: dir, transport: transport)
        let file = try makeFile(id: "f1", name: datedName)

        let first = await h1.importer.processFile(file, sub: "sub-1")
        guard case .created(let meetingID) = first else {
            return XCTFail("expected created, got \(first)")
        }
        let segmentCount = h1.meetingService.meetings[0].segments.count

        // "Crashed before the ledger write": a second importer over the SAME meeting store but an
        // empty ledger — exactly what relaunch + re-discovery sees.
        let h2 = makeHarness(
            in: dir, transport: transport,
            meetingService: h1.meetingService, ledgerFileName: "replay-ledger.json"
        )
        let replay = await h2.importer.processFile(file, sub: "sub-1")

        guard case .merged(let replayedID, _) = replay else {
            return XCTFail("expected the replay to merge, got \(replay)")
        }
        XCTAssertEqual(replayedID, meetingID)
        XCTAssertEqual(h1.meetingService.meetings.count, 1, "no duplicate meeting")
        XCTAssertEqual(h1.meetingService.meetings[0].segments.count, segmentCount, "no duplicated rows")
    }

    // MARK: - Atomicity (D-D4/F6)

    /// The same doc under two subs, processed interleaved (both exports in flight before either
    /// write): exactly one meeting results — the second import's snapshot necessarily contains
    /// the first one's meeting, scores ~1.0, and merges.
    func testSameDocUnderTwoSubsInterleavedYieldsOneMeeting() async throws {
        let dir = try TestSupport.makeTemporaryDirectory(prefix: "DriveImporter")
        defer { TestSupport.remove(dir) }
        // Both exports held ~50 ms so the two processFile calls interleave across the await.
        let transport = FakeDriveTransport(
            stubs: [
                .init(urlContains: "/files/doc-a/export", statusCode: 200, body: Self.geminiMarkdown),
                .init(urlContains: "/files/doc-b/export", statusCode: 200, body: Self.geminiMarkdown),
            ],
            delayNanoseconds: 50_000_000
        )
        let h = makeHarness(in: dir, transport: transport)
        let fileA = try makeFile(id: "doc-a", name: datedName)
        let fileB = try makeFile(id: "doc-b", name: datedName)

        async let outcomeA = h.importer.processFile(fileA, sub: "sub-1")
        async let outcomeB = h.importer.processFile(fileB, sub: "sub-2")
        let outcomes = await [outcomeA, outcomeB]

        XCTAssertEqual(h.meetingService.meetings.count, 1,
                       "the D-D4 synchronous snapshot→write stretch makes the duplicate race impossible")
        let createdCount = outcomes.filter { if case .created = $0 { return true } else { return false } }.count
        let mergedCount = outcomes.filter { if case .merged = $0 { return true } else { return false } }.count
        XCTAssertEqual(createdCount, 1)
        XCTAssertEqual(mergedCount, 1)
        // Identical rows deduped by the merger — the meeting holds one copy of the transcript.
        XCTAssertEqual(h.meetingService.meetings[0].segments.count, 2)
    }
}
