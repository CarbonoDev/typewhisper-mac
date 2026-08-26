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

        let outcome = await h.importer.processFile(file, sub: "sub-1", ownsPendingEntry: true)

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

        let outcome = await h.importer.processFile(try makeFile(id: "f1", name: datedName), sub: "sub-1", ownsPendingEntry: true)

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

    // MARK: - Live-meeting guard (D-D4 review fix, 2026-08-12)

    /// The data-loss case: Gemini publishes (and keeps editing) the notes doc while the call is
    /// still being captured. `mergeImport` deletes and re-inserts the target's segments, so a
    /// merge here would wipe live rows mid-recording and repeat on every 15-minute poll. Nothing
    /// may be exported, written, or ledgered — and no duplicate meeting may be created either.
    func testLiveMeetingIsNeverMergedIntoAndTheFileIsDeferred() async throws {
        let dir = try TestSupport.makeTemporaryDirectory(prefix: "DriveImporter")
        defer { TestSupport.remove(dir) }
        // No export stub at all: reaching the transport would itself be the failure.
        let h = makeHarness(in: dir, transport: FakeDriveTransport(stubs: []))
        let live = h.meetingService.createMeeting(
            title: "Weekly sync", source: .adHoc, state: .live, startDate: embeddedDate
        )
        h.meetingService.appendStableSegments(
            [
                TranscriptionSegment(text: "Caption en vivo uno.", start: 0, end: 30),
                TranscriptionSegment(text: "Caption en vivo dos.", start: 300, end: 330),
            ],
            source: .liveCaptions,
            to: live
        )
        let liveTexts = live.segments.map(\.text).sorted()
        h.ledger.markPending(fileID: "google:sub-1:f1", modifiedTime: fixedNow)

        let outcome = await h.importer.processFile(
            try makeFile(id: "f1", name: datedName), sub: "sub-1", ownsPendingEntry: true
        )

        XCTAssertEqual(outcome, .deferred)
        XCTAssertEqual(h.meetingService.meetings.count, 1, "no duplicate meeting was created either")
        XCTAssertEqual(live.segments.map(\.text).sorted(), liveTexts, "not one live row was dropped")
        XCTAssertNil(h.ledger.entry(for: "google:sub-1:f1"), "a deferred file stays unseen")
        XCTAssertNil(h.ledger.failures["google:sub-1:f1"], "deferring is not a failure")
        XCTAssertTrue(h.ledger.pendingFileIDs.isEmpty, "the guard is released so the next cycle re-enqueues")
    }

    /// …and once the meeting completes, the very same file imports normally — the deferral only
    /// postpones the merge, it never loses the transcript.
    func testDeferredFileMergesOnceTheMeetingCompletes() async throws {
        let dir = try TestSupport.makeTemporaryDirectory(prefix: "DriveImporter")
        defer { TestSupport.remove(dir) }
        let h = makeHarness(in: dir, transport: FakeDriveTransport(stubs: [exportStub(Self.geminiMarkdown)]))
        let meeting = h.meetingService.createMeeting(
            title: "Weekly sync", source: .adHoc, state: .live, startDate: embeddedDate
        )
        let file = try makeFile(id: "f1", name: datedName)

        let deferred = await h.importer.processFile(file, sub: "sub-1", ownsPendingEntry: false)
        XCTAssertEqual(deferred, .deferred)

        meeting.state = .completed
        let outcome = await h.importer.processFile(file, sub: "sub-1", ownsPendingEntry: false)

        guard case .merged(let meetingID, _) = outcome else {
            return XCTFail("expected merged, got \(outcome)")
        }
        XCTAssertEqual(meetingID, meeting.id)
        XCTAssertEqual(h.meetingService.meetings.count, 1)
    }

    /// A re-merge is deferred too: the recorded target being live is exactly the same hazard.
    func testRemergeIntoALiveTargetIsDeferred() async throws {
        let dir = try TestSupport.makeTemporaryDirectory(prefix: "DriveImporter")
        defer { TestSupport.remove(dir) }
        let h = makeHarness(in: dir, transport: FakeDriveTransport(stubs: []))
        let meeting = h.meetingService.createMeeting(
            title: "Weekly sync", source: .adHoc, state: .live, startDate: embeddedDate
        )
        h.ledger.recordImported(
            fileID: "google:sub-1:f1", docModifiedTime: fixedNow.addingTimeInterval(-600),
            meetingID: meeting.id, disposition: .merged, now: fixedNow.addingTimeInterval(-600)
        )

        let outcome = await h.importer.processFile(
            try makeFile(id: "f1", name: datedName), sub: "sub-1", ownsPendingEntry: false
        )

        XCTAssertEqual(outcome, .deferred)
        XCTAssertEqual(
            h.ledger.entry(for: "google:sub-1:f1")?.docModifiedTime,
            fixedNow.addingTimeInterval(-600),
            "the edit was not acknowledged, so the next cycle still sees it"
        )
    }

    func testNearMissCreatesASecondMeeting() async throws {
        let dir = try TestSupport.makeTemporaryDirectory(prefix: "DriveImporter")
        defer { TestSupport.remove(dir) }
        let h = makeHarness(in: dir, transport: FakeDriveTransport(stubs: [exportStub(Self.geminiMarkdown)]))
        h.meetingService.createMeeting(
            title: "Quarterly planning offsite", source: .adHoc, state: .completed, startDate: embeddedDate
        )

        let outcome = await h.importer.processFile(try makeFile(id: "f1", name: datedName), sub: "sub-1", ownsPendingEntry: true)

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

        let outcome = await h.importer.processFile(try makeFile(id: "f1", name: datedName), sub: "sub-1", ownsPendingEntry: true)

        guard case .created(let meetingID) = outcome else {
            return XCTFail("expected created via fallback, got \(outcome)")
        }
        let meeting = try XCTUnwrap(h.meetingService.meetings.first { $0.id == meetingID })
        XCTAssertEqual(meeting.segments.count, 2, "degraded but landed")
    }

    /// A 5xx is **transient** (review fix): it spends the large transient budget, never the small
    /// permanent one, so three unlucky cycles can no longer abandon a transcript for good.
    func testTransientExportFailureSpendsOnlyTheTransientBudget() async throws {
        let dir = try TestSupport.makeTemporaryDirectory(prefix: "DriveImporter")
        defer { TestSupport.remove(dir) }
        let transport = FakeDriveTransport(stubs: [exportStub("quota", statusCode: 500)])
        let h = makeHarness(in: dir, transport: transport)
        h.ledger.markPending(fileID: "google:sub-1:f1", modifiedTime: fixedNow)

        let outcome = await h.importer.processFile(try makeFile(id: "f1", name: datedName), sub: "sub-1", ownsPendingEntry: true)

        guard case .failed = outcome else {
            return XCTFail("expected failed, got \(outcome)")
        }
        let record = try XCTUnwrap(h.ledger.failures["google:sub-1:f1"])
        XCTAssertEqual(record.attempts, 0, "a 5xx must not burn the permanent retry cap")
        XCTAssertEqual(record.transientAttempts, 1)
        XCTAssertFalse(record.isExhausted)
        // The record carries the doc's modifiedTime so the engine's watermark holds behind it.
        XCTAssertEqual(record.docModifiedTime, fixedNow)
        XCTAssertTrue(h.ledger.pendingFileIDs.isEmpty, "a failure leaves the pending set")
        XCTAssertTrue(h.meetingService.meetings.isEmpty)
    }

    /// Three transient failures then a success — the scenario the 3-attempt cap used to abandon
    /// permanently (45 minutes of Drive flakiness). The file stays retryable throughout, stays
    /// under the watermark bound, and the eventual success clears the record.
    func testThreeTransientFailuresThenSuccessStillImports() async throws {
        let dir = try TestSupport.makeTemporaryDirectory(prefix: "DriveImporter")
        defer { TestSupport.remove(dir) }
        let transport = FakeDriveTransport(stubs: [
            exportStub("rate limited", statusCode: 429),
            exportStub("bad gateway", statusCode: 502),
            exportStub("server error", statusCode: 500),
            exportStub(Self.geminiMarkdown),
        ])
        let h = makeHarness(in: dir, transport: transport)
        let file = try makeFile(id: "f1", name: datedName)

        for attempt in 1...3 {
            let outcome = await h.importer.processFile(file, sub: "sub-1", ownsPendingEntry: false)
            guard case .failed = outcome else {
                return XCTFail("attempt \(attempt): expected failed, got \(outcome)")
            }
            XCTAssertEqual(
                h.ledger.action(for: file, sub: "sub-1", now: fixedNow), .retry,
                "attempt \(attempt): a transient failure must leave the file retryable"
            )
            XCTAssertEqual(h.ledger.earliestUnresolvedModifiedTime, fixedNow,
                           "attempt \(attempt): the watermark stays held behind the unresolved file")
        }

        let final = await h.importer.processFile(file, sub: "sub-1", ownsPendingEntry: false)
        guard case .created = final else {
            return XCTFail("expected created, got \(final)")
        }
        XCTAssertNil(h.ledger.failures["google:sub-1:f1"], "success clears the failure record")
        XCTAssertNil(h.ledger.earliestUnresolvedModifiedTime, "nothing unresolved holds the bound")
    }

    /// A 4xx that is not a rate limit is permanent: it still spends the small budget, so a doc
    /// Drive will never export does not retry forever.
    func testPermanentExportFailureSpendsThePermanentBudget() async throws {
        let dir = try TestSupport.makeTemporaryDirectory(prefix: "DriveImporter")
        defer { TestSupport.remove(dir) }
        // 400/403 are the markdown-fallback trigger, so both export attempts must fail; 404 is
        // the plain permanent case.
        let transport = FakeDriveTransport(stubs: [exportStub("gone", statusCode: 404)])
        let h = makeHarness(in: dir, transport: transport)

        _ = await h.importer.processFile(try makeFile(id: "f1", name: datedName), sub: "sub-1", ownsPendingEntry: false)

        let record = try XCTUnwrap(h.ledger.failures["google:sub-1:f1"])
        XCTAssertEqual(record.attempts, 1)
        XCTAssertEqual(record.transientAttempts, 0)
    }

    func testEmptyTranscriptRecordsFailure() async throws {
        let dir = try TestSupport.makeTemporaryDirectory(prefix: "DriveImporter")
        defer { TestSupport.remove(dir) }
        let h = makeHarness(in: dir, transport: FakeDriveTransport(stubs: [exportStub("   \n\n  ")]))

        let outcome = await h.importer.processFile(try makeFile(id: "f1", name: datedName), sub: "sub-1", ownsPendingEntry: true)

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
        let first = await h.importer.processFile(file, sub: "sub-1", ownsPendingEntry: true)
        guard case .created(let meetingID) = first else {
            return XCTFail("expected created, got \(first)")
        }
        let segmentCount = h.meetingService.meetings[0].segments.count

        let editedTime = fixedNow.addingTimeInterval(600)
        let edited = try makeFile(id: "f1", name: datedName, modified: editedTime)
        let second = await h.importer.processFile(edited, sub: "sub-1", ownsPendingEntry: true)

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
            try makeFile(id: "f1", name: datedName, modified: editedTime), sub: "sub-1",
            ownsPendingEntry: true
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

        let outcome = await h.importer.processFile(try makeFile(id: "f1", name: datedName), sub: "sub-1", ownsPendingEntry: true)

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

        let first = await h1.importer.processFile(file, sub: "sub-1", ownsPendingEntry: true)
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
        let replay = await h2.importer.processFile(file, sub: "sub-1", ownsPendingEntry: true)

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

        async let outcomeA = h.importer.processFile(fileA, sub: "sub-1", ownsPendingEntry: true)
        async let outcomeB = h.importer.processFile(fileB, sub: "sub-2", ownsPendingEntry: true)
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

    // MARK: - F4 execution-time re-check ([Google Phase 2 · M4], D-D7)

    /// An unchanged, already-ledgered file is skipped BEFORE any export request — the fake
    /// transport has zero stubs, so any network attempt would surface as `.failed`.
    func testUnchangedLedgeredFileSkipsWithoutAnyExportRequest() async throws {
        let dir = try TestSupport.makeTemporaryDirectory(prefix: "DriveImporter")
        defer { TestSupport.remove(dir) }
        let h = makeHarness(in: dir, transport: FakeDriveTransport(stubs: []))
        h.ledger.recordImported(
            fileID: "google:sub-1:f1", docModifiedTime: fixedNow,
            meetingID: UUID(), disposition: .created, now: fixedNow
        )
        // A stale auto job's own pending entry is cleared on the skip (watermark hygiene).
        h.ledger.markPending(fileID: "google:sub-1:f1", modifiedTime: fixedNow)

        let outcome = await h.importer.processFile(
            try makeFile(id: "f1", name: datedName, modified: fixedNow), sub: "sub-1",
            ownsPendingEntry: true
        )

        XCTAssertEqual(outcome, .skipped)
        XCTAssertTrue(h.meetingService.meetings.isEmpty)
        XCTAssertTrue(h.ledger.pendingFileIDs.isEmpty, "an owned pending entry is cleared on skip")
    }

    /// The pending self-exemption: an auto job (owner) imports through its own guard entry; a
    /// non-owner (the backfill batch) reading the same pending state is skipped without a request.
    func testPendingEntrySelfExemptionOnlyForTheOwningJob() async throws {
        let dir = try TestSupport.makeTemporaryDirectory(prefix: "DriveImporter")
        defer { TestSupport.remove(dir) }

        // Non-owner first: pending marked (an in-flight auto import), zero stubs → must skip.
        let hBlocked = makeHarness(in: dir, transport: FakeDriveTransport(stubs: []))
        hBlocked.ledger.markPending(fileID: "google:sub-1:f1", modifiedTime: fixedNow)
        let blocked = await hBlocked.importer.processFile(
            try makeFile(id: "f1", name: datedName), sub: "sub-1", ownsPendingEntry: false
        )
        XCTAssertEqual(blocked, .skipped, "a file in flight elsewhere is never re-exported")
        XCTAssertTrue(hBlocked.ledger.pendingFileIDs.contains("google:sub-1:f1"),
                      "a non-owner never clears someone else's guard entry")

        // Owner: same pending state, real stub → imports normally.
        let hOwner = makeHarness(
            in: dir, transport: FakeDriveTransport(stubs: [exportStub(Self.geminiMarkdown)]),
            ledgerFileName: "owner-ledger.json"
        )
        hOwner.ledger.markPending(fileID: "google:sub-1:f1", modifiedTime: fixedNow)
        let owned = await hOwner.importer.processFile(
            try makeFile(id: "f1", name: datedName), sub: "sub-1", ownsPendingEntry: true
        )
        guard case .created = owned else {
            return XCTFail("the owning job must pass through its own pending entry, got \(owned)")
        }
        XCTAssertTrue(hOwner.ledger.pendingFileIDs.isEmpty, "cleared by the success record")
    }

    // MARK: - Backfill batch ([Google Phase 2 · M4], D-D7)

    /// Serial walk with the injected inter-file pause, progress callbacks, and a summary tally
    /// across created / merged / skipped outcomes.
    func testRunBackfillWalksSeriallyWithPauseProgressAndTally() async throws {
        let dir = try TestSupport.makeTemporaryDirectory(prefix: "DriveImporter")
        defer { TestSupport.remove(dir) }
        let h = makeHarness(in: dir, transport: FakeDriveTransport(stubs: [
            .init(urlContains: "/files/doc-a/export", statusCode: 200, body: Self.geminiMarkdown),
            .init(urlContains: "/files/doc-b/export", statusCode: 200, body: Self.geminiMarkdown),
        ]))
        // doc-c is already ledgered → skipped without a stub.
        h.ledger.recordImported(
            fileID: "google:sub-1:doc-c", docModifiedTime: fixedNow,
            meetingID: UUID(), disposition: .created, now: fixedNow
        )
        let files = [
            try makeFile(id: "doc-a", name: datedName),
            try makeFile(id: "doc-b", name: datedName),
            try makeFile(id: "doc-c", name: "Other call - Notas de Gemini", modified: fixedNow),
        ]
        var pauses: [UInt64] = []
        var progress: [[Int]] = []

        let summary = await h.importer.runBackfill(
            files: files,
            sub: "sub-1",
            pause: { pauses.append($0) },
            onProgress: { current, total in progress.append([current, total]) }
        )

        // doc-a creates; doc-b (same doc content/title/date) merges into it; doc-c skips.
        XCTAssertEqual(summary, .init(imported: 1, merged: 1, skipped: 1, failed: 0, cancelled: false))
        XCTAssertEqual(pauses, [
            GoogleDriveTranscriptImporter.backfillInterFilePause,
            GoogleDriveTranscriptImporter.backfillInterFilePause,
        ], "one rate-limit pause between files, none before the first")
        XCTAssertEqual(progress, [[1, 3], [2, 3], [3, 3]])
        XCTAssertEqual(h.meetingService.meetings.count, 1)
    }

    /// Cancel stops between files: the in-flight file completes and stays ledgered; the rest are
    /// never exported (zero remaining stubs would otherwise fail them).
    func testRunBackfillCancellationBetweenFilesKeepsCompletedImports() async throws {
        let dir = try TestSupport.makeTemporaryDirectory(prefix: "DriveImporter")
        defer { TestSupport.remove(dir) }
        let h = makeHarness(in: dir, transport: FakeDriveTransport(stubs: [
            .init(urlContains: "/files/doc-a/export", statusCode: 200, body: Self.geminiMarkdown),
        ]))
        let files = [
            try makeFile(id: "doc-a", name: datedName),
            try makeFile(id: "doc-b", name: datedName),
        ]

        // The pause between files cancels the batch task — deterministic "cancel mid-run".
        let box = CancelBox()
        let importer = h.importer
        let task = Task { @MainActor in
            await importer.runBackfill(
                files: files,
                sub: "sub-1",
                pause: { _ in box.task?.cancel() }
            )
        }
        box.task = task
        let summary = await task.value

        XCTAssertTrue(summary.cancelled)
        XCTAssertEqual(summary.imported, 1, "the completed file stays imported")
        XCTAssertNotNil(h.ledger.entry(for: "google:sub-1:doc-a"))
        XCTAssertNil(h.ledger.entry(for: "google:sub-1:doc-b"), "never reached")
        XCTAssertEqual(h.meetingService.meetings.count, 1)
    }

    private final class CancelBox: @unchecked Sendable {
        var task: Task<GoogleDriveTranscriptImporter.BackfillSummary, Never>?
    }

    /// D-D7/F4: a file ledgered mid-batch by a concurrent auto-import (simulated in the
    /// inter-file pause) is skipped at execution time and counted as skipped in the summary.
    func testRunBackfillSkipsFileLedgeredMidBatchByAutoImport() async throws {
        let dir = try TestSupport.makeTemporaryDirectory(prefix: "DriveImporter")
        defer { TestSupport.remove(dir) }
        let h = makeHarness(in: dir, transport: FakeDriveTransport(stubs: [
            .init(urlContains: "/files/doc-a/export", statusCode: 200, body: Self.geminiMarkdown),
        ]))
        let files = [
            try makeFile(id: "doc-a", name: datedName),
            try makeFile(id: "doc-b", name: datedName, modified: fixedNow),
        ]
        let ledger = h.ledger
        let now = fixedNow

        let summary = await h.importer.runBackfill(
            files: files,
            sub: "sub-1",
            pause: { _ in
                // Auto-import lands doc-b while the batch is between files.
                ledger.recordImported(
                    fileID: "google:sub-1:doc-b", docModifiedTime: now,
                    meetingID: UUID(), disposition: .merged, now: now
                )
            }
        )

        XCTAssertEqual(summary.imported, 1)
        XCTAssertEqual(summary.skipped, 1, "the stale preview row is skipped, never double-imported")
        XCTAssertEqual(summary.failed, 0)
    }
}
