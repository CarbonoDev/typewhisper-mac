import XCTest
@testable import TypeWhisper

/// `GoogleDriveSyncEngine` over a fake transport, fake token provider, fake file processor, a
/// temp-dir ledger, and an injected clock ([Google Phase 2 · M2]): first-cycle watermark seeding,
/// the zero-requests-when-disabled property (QA step 1), the overlap margin, the per-file
/// decision fan-out (unseen / edited / retry / unchanged), the 25-enqueue cap, needsReauth skip +
/// error surfacing, per-account isolation, and the D-D6/F1 crash re-discovery. Timers never run —
/// tests drive `syncNow()` directly (`start()` is production-only).
@MainActor
final class GoogleDriveSyncEngineTests: XCTestCase {
    // MARK: - Fakes

    private final class InMemorySecretStore: GoogleSecretStoring {
        private var secrets: [String: String] = [:]
        func save(_ secret: String, service: String) throws { secrets[service] = secret }
        func load(service: String) -> String? { secrets[service] }
        func delete(service: String) throws { secrets[service] = nil }
        func deleteAll(prefix: String) throws {
            secrets = secrets.filter { !$0.key.hasPrefix(prefix) }
        }
    }

    @MainActor
    private final class FakeTokenProvider: GoogleAccessTokenProviding {
        var results: [String: Result<String, Error>] = [:]
        private(set) var requestedAccountIDs: [String] = []

        func accessToken(for accountID: String) async throws -> String {
            requestedAccountIDs.append(accountID)
            guard let result = results[accountID] else {
                throw GoogleAuthError.refreshFailed("no canned token for \(accountID)")
            }
            return try result.get()
        }
    }

    /// Records processed files without touching the ledger — which is exactly the
    /// "enqueued-but-not-yet-ledgered" state the D-D6 watermark rule protects (the real importer
    /// is the sole ledger writer; a fake that ledgers nothing models a job whose effects never
    /// landed).
    @MainActor
    private final class FakeProcessor: GoogleDriveFileProcessing {
        private(set) var processed: [(fileID: String, sub: String, ownsPendingEntry: Bool)] = []
        var outcome: GoogleDriveTranscriptImporter.Outcome = .touched

        func processFile(
            _ file: GoogleDriveAPI.GDriveFile,
            sub: String,
            ownsPendingEntry: Bool
        ) async -> GoogleDriveTranscriptImporter.Outcome {
            processed.append((file.id, sub, ownsPendingEntry))
            return outcome
        }
    }

    /// Substring-routed canned transport (the Phase 1 shape): each stub matches by URL substring
    /// and is consumed in order within its matching set.
    private final class FakeDriveTransport: GoogleHTTPTransport, @unchecked Sendable {
        struct Stub {
            let urlContains: String
            let statusCode: Int
            let body: String
        }

        private let lock = NSLock()
        private var stubs: [Stub]
        private var _requests: [URLRequest] = []

        init(stubs: [Stub]) {
            self.stubs = stubs
        }

        var requests: [URLRequest] {
            lock.lock()
            defer { lock.unlock() }
            return _requests
        }

        private func recordAndMatch(_ request: URLRequest) -> Stub? {
            lock.lock()
            defer { lock.unlock() }
            _requests.append(request)
            let url = request.url?.absoluteString ?? ""
            guard let index = stubs.firstIndex(where: { url.contains($0.urlContains) }) else {
                return nil
            }
            return stubs.remove(at: index)
        }

        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            guard let stub = recordAndMatch(request) else {
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

    // MARK: - Fixture bodies

    private static func fileJSON(id: String, name: String, modified: Date) -> String {
        #"{"id": "\#(id)", "name": "\#(name)", "mimeType": "application/vnd.google-apps.document", "createdTime": "\#(GoogleCalendarAPI.rfc3339String(modified))", "modifiedTime": "\#(GoogleCalendarAPI.rfc3339String(modified))"}"#
    }

    private static func filesBody(_ files: [String], next: String? = nil) -> String {
        let token = next.map { #", "nextPageToken": "\#($0)""# } ?? ""
        return #"{"files": [\#(files.joined(separator: ", "))]\#(token)}"#
    }

    /// The `files.list` URL discriminator (`?q=…` vs export's `/files/<id>/export`).
    private static let listMarker = "/drive/v3/files?"

    // MARK: - Harness

    private var suiteName: String!
    private var defaults: UserDefaults!
    private let fixedNow = Date(timeIntervalSince1970: 1_770_000_000)

    override func setUp() {
        super.setUp()
        suiteName = "GoogleDriveSyncEngineTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private struct Harness {
        let engine: GoogleDriveSyncEngine
        let store: GoogleAccountStore
        let ledger: GoogleDriveImportLedger
        let queue: JobQueueService
        let processor: FakeProcessor
        let tokens: FakeTokenProvider
    }

    /// One store + ledger + engine over the fakes. `accountIDs` become `.connected` accounts with
    /// canned tokens `token-<id>`; `enabled` accounts get the Drive toggle turned on.
    private func makeHarness(
        transport: FakeDriveTransport,
        ledgerDirectory: URL,
        accountIDs: [String],
        enabled: [String]
    ) throws -> Harness {
        let store = GoogleAccountStore(defaults: defaults, secretStore: InMemorySecretStore())
        let tokens = FakeTokenProvider()
        for id in accountIDs {
            try store.upsert(
                GoogleAccount(
                    id: id,
                    email: "\(id)@example.com",
                    displayName: nil,
                    grantedScopes: ["openid", GoogleDriveAPI.readonlyScope],
                    connectedAt: fixedNow,
                    statusRaw: GoogleAccountStatus.connected.rawValue
                ),
                refreshToken: "rt-\(id)"
            )
            if tokens.results[id] == nil {
                tokens.results[id] = .success("token-\(id)")
            }
        }
        for id in enabled {
            store.setDriveImportEnabled(true, for: id)
        }
        let ledger = GoogleDriveImportLedger(
            fileURL: ledgerDirectory.appendingPathComponent("google-drive-imports.json")
        )
        let queue = JobQueueService()
        let processor = FakeProcessor()
        let engine = GoogleDriveSyncEngine(
            store: store,
            tokenProvider: tokens,
            transport: transport,
            ledger: ledger,
            jobQueue: queue,
            processor: processor,
            now: { self.fixedNow }
        )
        return Harness(engine: engine, store: store, ledger: ledger, queue: queue, processor: processor, tokens: tokens)
    }

    private func queryValue(_ name: String, of request: URLRequest) -> String? {
        request.url
            .flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?
            .queryItems?
            .first(where: { $0.name == name })?
            .value
    }

    // MARK: - First cycle / toggle gating

    /// D-D6: the first-ever cycle for an account seeds the watermark to now and imports NOTHING —
    /// not even a `files.list` is issued (history is backfill's job, user-controlled).
    func testFirstCycleSeedsWatermarkAndImportsNothing() async throws {
        let dir = try TestSupport.makeTemporaryDirectory(prefix: "DriveEngine")
        defer { TestSupport.remove(dir) }
        let transport = FakeDriveTransport(stubs: [])
        let h = try makeHarness(transport: transport, ledgerDirectory: dir, accountIDs: ["sub-1"], enabled: ["sub-1"])

        await h.engine.syncNow()

        XCTAssertEqual(h.ledger.watermark(forSub: "sub-1"), fixedNow)
        XCTAssertTrue(transport.requests.isEmpty, "seeding must not issue a files.list")
        XCTAssertTrue(h.queue.jobs.isEmpty)
        XCTAssertEqual(h.engine.lastSyncAt, fixedNow)
        XCTAssertNil(h.engine.lastSyncError)
    }

    /// QA step 1 / zero-behavior-change: with every Drive toggle off (the default), the engine
    /// issues ZERO Drive requests — no token fetch, no list, no jobs, no sync timestamp.
    func testAllTogglesOffIssuesZeroDriveRequests() async throws {
        let dir = try TestSupport.makeTemporaryDirectory(prefix: "DriveEngine")
        defer { TestSupport.remove(dir) }
        let transport = FakeDriveTransport(stubs: [])
        let h = try makeHarness(transport: transport, ledgerDirectory: dir, accountIDs: ["sub-1", "sub-2"], enabled: [])

        await h.engine.syncNow()

        XCTAssertTrue(h.tokens.requestedAccountIDs.isEmpty)
        XCTAssertTrue(transport.requests.isEmpty)
        XCTAssertTrue(h.queue.jobs.isEmpty)
        XCTAssertNil(h.engine.lastSyncAt, "no Drive-enabled account means nothing was attempted")
    }

    func testOnlyConnectedAndEnabledAccountsArePolled() async throws {
        let dir = try TestSupport.makeTemporaryDirectory(prefix: "DriveEngine")
        defer { TestSupport.remove(dir) }
        let transport = FakeDriveTransport(stubs: [])
        let h = try makeHarness(
            transport: transport,
            ledgerDirectory: dir,
            accountIDs: ["sub-enabled", "sub-disabled", "sub-reauth"],
            enabled: ["sub-enabled", "sub-reauth"]
        )
        h.store.setStatus(.needsReauth, for: "sub-reauth")

        await h.engine.syncNow()

        XCTAssertEqual(h.tokens.requestedAccountIDs, ["sub-enabled"],
                       "disabled and needs-reauth accounts are never polled")
    }

    // MARK: - Discovery (watermark bound, decision fan-out, cap)

    func testFilesListCarriesTheOverlapMarginBound() async throws {
        let dir = try TestSupport.makeTemporaryDirectory(prefix: "DriveEngine")
        defer { TestSupport.remove(dir) }
        let transport = FakeDriveTransport(stubs: [
            .init(urlContains: Self.listMarker, statusCode: 200, body: Self.filesBody([])),
        ])
        let h = try makeHarness(transport: transport, ledgerDirectory: dir, accountIDs: ["sub-1"], enabled: ["sub-1"])
        let watermark = fixedNow.addingTimeInterval(-3_600)
        h.ledger.setWatermark(watermark, forSub: "sub-1")

        await h.engine.syncNow()

        let request = try XCTUnwrap(transport.requests.first)
        let q = try XCTUnwrap(queryValue("q", of: request))
        let expectedBound = GoogleCalendarAPI.rfc3339String(
            watermark.addingTimeInterval(-GoogleDriveSyncEngine.overlapMargin)
        )
        XCTAssertTrue(q.contains("modifiedTime > '\(expectedBound)'"), "got: \(q)")
        // A clean pass with nothing pending advances the watermark to the cycle start.
        XCTAssertEqual(h.ledger.watermark(forSub: "sub-1"), fixedNow)
    }

    /// Unseen file → one `.driveImport` job on the io lane, pending guard marked, clean-title
    /// progress label, processor invoked with the file + sub, and the watermark held below the
    /// still-unledgered file's modifiedTime (D-D6).
    func testUnseenFileIsEnqueuedProcessedAndHoldsWatermark() async throws {
        let dir = try TestSupport.makeTemporaryDirectory(prefix: "DriveEngine")
        defer { TestSupport.remove(dir) }
        let modified = fixedNow.addingTimeInterval(-600)
        let transport = FakeDriveTransport(stubs: [
            .init(urlContains: Self.listMarker, statusCode: 200, body: Self.filesBody([
                Self.fileJSON(id: "f1", name: "Weekly sync - Notas de Gemini", modified: modified)
            ])),
        ])
        let h = try makeHarness(transport: transport, ledgerDirectory: dir, accountIDs: ["sub-1"], enabled: ["sub-1"])
        h.ledger.setWatermark(fixedNow.addingTimeInterval(-3_600), forSub: "sub-1")

        await h.engine.syncNow()
        await h.queue.drain()

        let job = try XCTUnwrap(h.queue.jobs.first)
        XCTAssertEqual(job.kind, .driveImport)
        XCTAssertEqual(job.lane, .io)
        XCTAssertNil(job.meetingID)
        XCTAssertEqual(job.progressLabel, "Weekly sync", "the clean title, not the raw export name")
        XCTAssertEqual(h.processor.processed.map(\.fileID), ["f1"])
        XCTAssertEqual(h.processor.processed.map(\.sub), ["sub-1"])
        // F4: an auto-import job owns its file's pending entry, so the importer's execution-time
        // re-check never self-blocks on the guard the engine just marked.
        XCTAssertEqual(h.processor.processed.map(\.ownsPendingEntry), [true])
        // The fake processor never ledgered, so the file is still pending and the watermark is
        // held at its modifiedTime − 1 s — the crash-safe bound.
        XCTAssertTrue(h.ledger.pendingFileIDs.contains("google:sub-1:f1"))
        XCTAssertEqual(h.ledger.watermark(forSub: "sub-1"), modified.addingTimeInterval(-1))
    }

    func testDecisionFanOutEnqueuesEditedAndRetryButSkipsUnchanged() async throws {
        let dir = try TestSupport.makeTemporaryDirectory(prefix: "DriveEngine")
        defer { TestSupport.remove(dir) }
        let old = fixedNow.addingTimeInterval(-7_200)
        let edited = fixedNow.addingTimeInterval(-600)
        let transport = FakeDriveTransport(stubs: [
            .init(urlContains: Self.listMarker, statusCode: 200, body: Self.filesBody([
                Self.fileJSON(id: "edited", name: "Edited doc - Notas de Gemini", modified: edited),
                Self.fileJSON(id: "unchanged", name: "Unchanged doc - Notas de Gemini", modified: old),
                Self.fileJSON(id: "failing", name: "Failing doc - Notas de Gemini", modified: old),
            ])),
        ])
        let h = try makeHarness(transport: transport, ledgerDirectory: dir, accountIDs: ["sub-1"], enabled: ["sub-1"])
        h.ledger.setWatermark(fixedNow.addingTimeInterval(-10_000), forSub: "sub-1")
        // "edited": ledgered long ago, doc modified since → remerge. "unchanged": ledgered at its
        // current modifiedTime → skip. "failing": one prior failed attempt → retry.
        h.ledger.recordImported(
            fileID: "google:sub-1:edited", docModifiedTime: old, meetingID: UUID(),
            disposition: .merged, now: old
        )
        h.ledger.recordImported(
            fileID: "google:sub-1:unchanged", docModifiedTime: old, meetingID: UUID(),
            disposition: .created, now: old
        )
        h.ledger.recordFailure(fileID: "google:sub-1:failing", now: old)

        await h.engine.syncNow()
        await h.queue.drain()

        XCTAssertEqual(Set(h.processor.processed.map(\.fileID)), ["edited", "failing"],
                       "unchanged ledgered files are never re-enqueued")
        XCTAssertEqual(h.queue.jobs.filter { $0.kind == .driveImport }.count, 2)
    }

    func testEnqueueCapBoundsOneCycle() async throws {
        let dir = try TestSupport.makeTemporaryDirectory(prefix: "DriveEngine")
        defer { TestSupport.remove(dir) }
        let modified = fixedNow.addingTimeInterval(-600)
        let manyFiles = (0..<30).map {
            Self.fileJSON(id: "f\($0)", name: "Doc \($0) - Notas de Gemini", modified: modified)
        }
        let transport = FakeDriveTransport(stubs: [
            .init(urlContains: Self.listMarker, statusCode: 200, body: Self.filesBody(manyFiles)),
        ])
        let h = try makeHarness(transport: transport, ledgerDirectory: dir, accountIDs: ["sub-1"], enabled: ["sub-1"])
        h.ledger.setWatermark(fixedNow.addingTimeInterval(-3_600), forSub: "sub-1")

        await h.engine.syncNow()
        await h.queue.drain()

        // Count executions, not retained queue rows — the queue prunes settled history to 20, so
        // the job list undercounts an instantly-completing 25-job burst.
        XCTAssertEqual(
            h.processor.processed.count,
            GoogleDriveSyncEngine.maxEnqueuesPerCycle,
            "burst bound (D-D6): the remainder lands next cycle via the held watermark"
        )
        XCTAssertEqual(h.ledger.pendingFileIDs.count, GoogleDriveSyncEngine.maxEnqueuesPerCycle,
                       "exactly the enqueued 25 entered the pending guard")
    }

    // MARK: - Failure semantics

    func testNeedsReauthSkipsAccountAndSurfacesReconnectError() async throws {
        let dir = try TestSupport.makeTemporaryDirectory(prefix: "DriveEngine")
        defer { TestSupport.remove(dir) }
        let transport = FakeDriveTransport(stubs: [])
        let h = try makeHarness(transport: transport, ledgerDirectory: dir, accountIDs: ["sub-1"], enabled: ["sub-1"])
        h.ledger.setWatermark(fixedNow.addingTimeInterval(-3_600), forSub: "sub-1")
        h.tokens.results["sub-1"] = .failure(GoogleAuthError.needsReauth)

        await h.engine.syncNow()

        let message = try XCTUnwrap(h.engine.lastSyncError)
        XCTAssertTrue(message.contains("sub-1@example.com"))
        XCTAssertTrue(message.contains("reconnected"), "the D-D8 remedy must be named: \(message)")
        XCTAssertTrue(transport.requests.isEmpty)
        // The watermark is untouched by a failed pass.
        XCTAssertEqual(h.ledger.watermark(forSub: "sub-1"), fixedNow.addingTimeInterval(-3_600))
    }

    func testTransientListFailureIsIsolatedPerAccount() async throws {
        let dir = try TestSupport.makeTemporaryDirectory(prefix: "DriveEngine")
        defer { TestSupport.remove(dir) }
        let modified = fixedNow.addingTimeInterval(-600)
        // sub-a's list 500s; sub-b's succeeds with one file. Stubs are consumed in order and both
        // requests match the list marker, so the 500 must be first (accounts iterate in connect
        // order).
        let transport = FakeDriveTransport(stubs: [
            .init(urlContains: Self.listMarker, statusCode: 500, body: "{}"),
            .init(urlContains: Self.listMarker, statusCode: 200, body: Self.filesBody([
                Self.fileJSON(id: "fb", name: "Doc B - Notas de Gemini", modified: modified)
            ])),
        ])
        let h = try makeHarness(
            transport: transport, ledgerDirectory: dir,
            accountIDs: ["sub-a", "sub-b"], enabled: ["sub-a", "sub-b"]
        )
        h.ledger.setWatermark(fixedNow.addingTimeInterval(-3_600), forSub: "sub-a")
        h.ledger.setWatermark(fixedNow.addingTimeInterval(-3_600), forSub: "sub-b")

        await h.engine.syncNow()
        await h.queue.drain()

        XCTAssertNotNil(h.engine.lastSyncError)
        XCTAssertTrue(h.engine.lastSyncError!.contains("sub-a@example.com"))
        XCTAssertEqual(h.processor.processed.map(\.fileID), ["fb"], "sub-b still imported")
        // Failed account's watermark untouched; successful account's advanced… but held below the
        // still-pending file (the global conservative bound, D-D6).
        XCTAssertEqual(h.ledger.watermark(forSub: "sub-a"), fixedNow.addingTimeInterval(-3_600))
        XCTAssertEqual(h.ledger.watermark(forSub: "sub-b"), modified.addingTimeInterval(-1))
    }

    // MARK: - Crash re-discovery (D-D6/F1)

    /// Enqueue a file, complete nothing (the fake processor never ledgers), then rebuild the
    /// engine against the same ledger FILE — a relaunch: fresh in-memory pending set — and assert
    /// the file is re-discovered and re-enqueued because the watermark held below its
    /// `modifiedTime`.
    func testCrashLostJobIsRediscoveredNextLaunch() async throws {
        let dir = try TestSupport.makeTemporaryDirectory(prefix: "DriveEngine")
        defer { TestSupport.remove(dir) }
        let modified = fixedNow.addingTimeInterval(-600)
        let fileJSON = Self.fileJSON(id: "f1", name: "Lost doc - Notas de Gemini", modified: modified)

        // Launch 1: discover + enqueue; the job's effects never land (crash before ledgering).
        let transport1 = FakeDriveTransport(stubs: [
            .init(urlContains: Self.listMarker, statusCode: 200, body: Self.filesBody([fileJSON])),
        ])
        let h1 = try makeHarness(transport: transport1, ledgerDirectory: dir, accountIDs: ["sub-1"], enabled: ["sub-1"])
        h1.ledger.setWatermark(fixedNow.addingTimeInterval(-3_600), forSub: "sub-1")
        await h1.engine.syncNow()
        await h1.queue.drain()
        XCTAssertEqual(h1.ledger.watermark(forSub: "sub-1"), modified.addingTimeInterval(-1))

        // Launch 2: same ledger file, fresh pending set, fresh queue/engine.
        let transport2 = FakeDriveTransport(stubs: [
            .init(urlContains: Self.listMarker, statusCode: 200, body: Self.filesBody([fileJSON])),
        ])
        let h2 = try makeHarness(transport: transport2, ledgerDirectory: dir, accountIDs: ["sub-1"], enabled: ["sub-1"])
        XCTAssertTrue(h2.ledger.pendingFileIDs.isEmpty, "pending is in-memory only")
        await h2.engine.syncNow()
        await h2.queue.drain()

        // The held watermark (minus overlap) re-surfaced the file, and with no ledger entry the
        // decision is importNew again.
        let listRequest = try XCTUnwrap(transport2.requests.first)
        let q = try XCTUnwrap(queryValue("q", of: listRequest))
        let bound = GoogleCalendarAPI.rfc3339String(
            modified.addingTimeInterval(-1 - GoogleDriveSyncEngine.overlapMargin)
        )
        XCTAssertTrue(q.contains("modifiedTime > '\(bound)'"), "got: \(q)")
        XCTAssertEqual(h2.processor.processed.map(\.fileID), ["f1"], "the lost file was re-enqueued")
    }
}
