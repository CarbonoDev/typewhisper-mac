import XCTest
@testable import TypeWhisper

/// `GoogleCalendarSyncEngine` over a fake transport, a fake token provider, and an injected
/// clock (§7): window math, pagination follow, per-account error isolation, `.needsReauth` skip,
/// and the snapshot-change notification firing only on actual change. Timers never run — tests
/// drive `syncNow()` directly (`start()` is production-only).
@MainActor
final class GoogleCalendarSyncEngineTests: XCTestCase {
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

    /// Substring-routed canned transport. Each stub matches by URL substring and is consumed in
    /// order within its matching set, so pagination (same path, different pageToken) serves page
    /// one then page two deterministically. Thread-safe via a lock (the transport is Sendable).
    private final class FakeCalendarTransport: GoogleHTTPTransport, @unchecked Sendable {
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

        func setStubs(_ newStubs: [Stub]) {
            lock.lock()
            defer { lock.unlock() }
            stubs = newStubs
        }

        /// Records the request and dequeues the first matching stub under the lock — a synchronous
        /// helper so the async `send` never calls `lock()` from an async context (M1 precedent).
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

    private static func calendarListBody(ids: [String]) -> String {
        let items = ids
            .map { #"{"id": "\#($0)", "summary": "Cal \#($0)"}"# }
            .joined(separator: ", ")
        return #"{"items": [\#(items)]}"#
    }

    private static func event(_ id: String, start: String, end: String) -> String {
        #"{"id": "\#(id)", "status": "confirmed", "summary": "Event \#(id)", "start": {"dateTime": "\#(start)"}, "end": {"dateTime": "\#(end)"}}"#
    }

    private static func eventsBody(events: [String], nextPageToken: String? = nil) -> String {
        let next = nextPageToken.map { #", "nextPageToken": "\#($0)""# } ?? ""
        return #"{"items": [\#(events.joined(separator: ", "))]\#(next)}"#
    }

    // MARK: - Harness

    private var suiteName: String!
    private var defaults: UserDefaults!
    /// Injected wall clock (fixed — window math must be deterministic).
    private let fixedNow = Date(timeIntervalSince1970: 1_700_000_000)
    private var snapshotChangeCount = 0
    private var observer: NSObjectProtocol?

    override func setUp() {
        super.setUp()
        suiteName = "GoogleCalendarSyncEngineTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        snapshotChangeCount = 0
        observer = NotificationCenter.default.addObserver(
            forName: .googleCalendarSnapshotDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.snapshotChangeCount += 1
            }
        }
    }

    override func tearDown() {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    /// One store + engine over the fakes; `accountIDs` become `.connected` accounts with canned
    /// tokens `token-<id>` unless the token provider is pre-seeded otherwise.
    private func makeEngine(
        transport: FakeCalendarTransport,
        tokenProvider: FakeTokenProvider,
        accountIDs: [String]
    ) throws -> (engine: GoogleCalendarSyncEngine, store: GoogleAccountStore) {
        let store = GoogleAccountStore(defaults: defaults, secretStore: InMemorySecretStore())
        for id in accountIDs {
            try store.upsert(
                GoogleAccount(
                    id: id,
                    email: "\(id)@example.com",
                    displayName: nil,
                    grantedScopes: ["openid"],
                    connectedAt: fixedNow,
                    statusRaw: GoogleAccountStatus.connected.rawValue
                ),
                refreshToken: "rt-\(id)"
            )
            if tokenProvider.results[id] == nil {
                tokenProvider.results[id] = .success("token-\(id)")
            }
        }
        let engine = GoogleCalendarSyncEngine(
            store: store,
            tokenProvider: tokenProvider,
            transport: transport,
            now: { self.fixedNow }
        )
        return (engine, store)
    }

    private func queryValue(_ name: String, of request: URLRequest) -> String? {
        request.url
            .flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?
            .queryItems?
            .first(where: { $0.name == name })?
            .value
    }

    // MARK: - Window math

    func testSyncWindowIsLookbackDayMinusOneToNowPlus48Hours() {
        let calendar = Calendar.current
        let window = GoogleCalendarSyncEngine.syncWindow(now: fixedNow, calendar: calendar)
        XCTAssertEqual(window.start, calendar.startOfDay(for: fixedNow).addingTimeInterval(-24 * 60 * 60))
        XCTAssertEqual(window.end, fixedNow.addingTimeInterval(48 * 60 * 60))
    }

    func testEventsRequestCarriesTheSyncWindowAndInstanceExpansion() async throws {
        let transport = FakeCalendarTransport(stubs: [
            .init(urlContains: "calendarList", statusCode: 200, body: Self.calendarListBody(ids: ["cal1"])),
            .init(urlContains: "/calendars/cal1/events", statusCode: 200, body: Self.eventsBody(events: [])),
        ])
        let tokens = FakeTokenProvider()
        let (engine, _) = try makeEngine(transport: transport, tokenProvider: tokens, accountIDs: ["sub-1"])

        await engine.syncNow()

        let eventsRequest = try XCTUnwrap(
            transport.requests.first { $0.url?.absoluteString.contains("/events") == true }
        )
        let window = GoogleCalendarSyncEngine.syncWindow(now: fixedNow)
        XCTAssertEqual(queryValue("timeMin", of: eventsRequest), GoogleCalendarAPI.rfc3339String(window.start))
        XCTAssertEqual(queryValue("timeMax", of: eventsRequest), GoogleCalendarAPI.rfc3339String(window.end))
        XCTAssertEqual(queryValue("singleEvents", of: eventsRequest), "true", "D-G3: occurrence-unique instance IDs")
        XCTAssertEqual(queryValue("showDeleted", of: eventsRequest), "false")
        XCTAssertEqual(
            eventsRequest.value(forHTTPHeaderField: "Authorization"), "Bearer token-sub-1",
            "token comes from the injected seam"
        )
    }

    // MARK: - Pagination

    func testFollowsEventPagination() async throws {
        let transport = FakeCalendarTransport(stubs: [
            .init(urlContains: "calendarList", statusCode: 200, body: Self.calendarListBody(ids: ["cal1"])),
            .init(
                urlContains: "/calendars/cal1/events",
                statusCode: 200,
                body: Self.eventsBody(
                    events: [Self.event("e1", start: "2026-08-10T10:00:00Z", end: "2026-08-10T11:00:00Z")],
                    nextPageToken: "page-2"
                )
            ),
            .init(
                urlContains: "/calendars/cal1/events",
                statusCode: 200,
                body: Self.eventsBody(
                    events: [Self.event("e2", start: "2026-08-10T12:00:00Z", end: "2026-08-10T13:00:00Z")]
                )
            ),
        ])
        let tokens = FakeTokenProvider()
        let (engine, _) = try makeEngine(transport: transport, tokenProvider: tokens, accountIDs: ["sub-1"])

        await engine.syncNow()

        let eventIDs = engine.snapshot.flatMap(\.events).map(\.id)
        XCTAssertEqual(eventIDs, ["google:sub-1:e1", "google:sub-1:e2"], "both pages land in the snapshot")
        let pageTokens = transport.requests
            .filter { $0.url?.absoluteString.contains("/events") == true }
            .map { queryValue("pageToken", of: $0) }
        XCTAssertEqual(pageTokens, [nil, "page-2"], "second request follows nextPageToken")
    }

    // MARK: - Error isolation

    func testTransientFailureKeepsAccountsLastGoodSnapshotAndOtherAccountUpdates() async throws {
        func cleanStubs(bEvent: String) -> [FakeCalendarTransport.Stub] {
            [
                .init(urlContains: "calendarList", statusCode: 200, body: Self.calendarListBody(ids: ["calA"])),
                .init(urlContains: "/calendars/calA/events", statusCode: 200, body: Self.eventsBody(
                    events: [Self.event(bEvent, start: "2026-08-10T10:00:00Z", end: "2026-08-10T11:00:00Z")]
                )),
                .init(urlContains: "calendarList", statusCode: 200, body: Self.calendarListBody(ids: ["calB"])),
                .init(urlContains: "/calendars/calB/events", statusCode: 200, body: Self.eventsBody(
                    events: [Self.event("b1", start: "2026-08-10T14:00:00Z", end: "2026-08-10T15:00:00Z")]
                )),
            ]
        }
        let transport = FakeCalendarTransport(stubs: cleanStubs(bEvent: "a1"))
        let tokens = FakeTokenProvider()
        let (engine, _) = try makeEngine(transport: transport, tokenProvider: tokens, accountIDs: ["subA", "subB"])

        await engine.syncNow()
        XCTAssertNil(engine.lastSyncError)
        XCTAssertEqual(
            engine.snapshot.flatMap(\.events).map(\.id),
            ["google:subA:a1", "google:subB:b1"]
        )

        // Second cycle: A updates (a2 replaces a1); B's calendarList 500s → B keeps b1 (stale,
        // never empty — D-G4) and the failure surfaces.
        transport.setStubs([
            .init(urlContains: "calendarList", statusCode: 200, body: Self.calendarListBody(ids: ["calA"])),
            .init(urlContains: "/calendars/calA/events", statusCode: 200, body: Self.eventsBody(
                events: [Self.event("a2", start: "2026-08-10T16:00:00Z", end: "2026-08-10T17:00:00Z")]
            )),
            .init(urlContains: "calendarList", statusCode: 500, body: "boom"),
        ])
        await engine.syncNow()

        XCTAssertEqual(
            engine.snapshot.flatMap(\.events).map(\.id),
            ["google:subA:a2", "google:subB:b1"],
            "A updated, B served from its last good slice"
        )
        XCTAssertNotNil(engine.lastSyncError)
        XCTAssertTrue(engine.lastSyncError!.contains("subB@example.com"), "error names the failing account")
        XCTAssertEqual(engine.lastSyncAt, fixedNow)
    }

    // MARK: - needsReauth

    func testNeedsReauthFromTokenSeamSkipsAccountAndSurfacesError() async throws {
        let transport = FakeCalendarTransport(stubs: [
            .init(urlContains: "calendarList", statusCode: 200, body: Self.calendarListBody(ids: ["calA"])),
            .init(urlContains: "/calendars/calA/events", statusCode: 200, body: Self.eventsBody(
                events: [Self.event("a1", start: "2026-08-10T10:00:00Z", end: "2026-08-10T11:00:00Z")]
            )),
        ])
        let tokens = FakeTokenProvider()
        tokens.results["subB"] = .failure(GoogleAuthError.needsReauth)
        let (engine, _) = try makeEngine(transport: transport, tokenProvider: tokens, accountIDs: ["subA", "subB"])

        await engine.syncNow()

        XCTAssertEqual(engine.snapshot.flatMap(\.events).map(\.id), ["google:subA:a1"], "A still synced")
        XCTAssertNotNil(engine.lastSyncError, "terminal auth loss is user-facing")
        let calendarRequests = transport.requests.filter {
            $0.value(forHTTPHeaderField: "Authorization")?.contains("token-subB") == true
        }
        XCTAssertTrue(calendarRequests.isEmpty, "no API calls for the account that failed auth")
    }

    func testAccountAlreadyFlaggedNeedsReauthIsSkippedSilently() async throws {
        let transport = FakeCalendarTransport(stubs: [
            .init(urlContains: "calendarList", statusCode: 200, body: Self.calendarListBody(ids: ["calA"])),
            .init(urlContains: "/calendars/calA/events", statusCode: 200, body: Self.eventsBody(events: [])),
        ])
        let tokens = FakeTokenProvider()
        let (engine, store) = try makeEngine(transport: transport, tokenProvider: tokens, accountIDs: ["subA", "subB"])
        store.setStatus(.needsReauth, for: "subB")

        await engine.syncNow()

        XCTAssertFalse(tokens.requestedAccountIDs.contains("subB"), "no token fetch for a flagged account")
        XCTAssertNil(engine.lastSyncError, "the settings badge communicates it; no sync error")
    }

    // MARK: - Snapshot-change notification

    func testNotificationFiresOnlyOnActualSnapshotChange() async throws {
        func stubs(eventID: String) -> [FakeCalendarTransport.Stub] {
            [
                .init(urlContains: "calendarList", statusCode: 200, body: Self.calendarListBody(ids: ["cal1"])),
                .init(urlContains: "/calendars/cal1/events", statusCode: 200, body: Self.eventsBody(
                    events: [Self.event(eventID, start: "2026-08-10T10:00:00Z", end: "2026-08-10T11:00:00Z")]
                )),
            ]
        }
        let transport = FakeCalendarTransport(stubs: stubs(eventID: "e1"))
        let tokens = FakeTokenProvider()
        let (engine, _) = try makeEngine(transport: transport, tokenProvider: tokens, accountIDs: ["sub-1"])

        await engine.syncNow()
        XCTAssertEqual(snapshotChangeCount, 1, "first snapshot is a change")

        transport.setStubs(stubs(eventID: "e1"))
        await engine.syncNow()
        XCTAssertEqual(snapshotChangeCount, 1, "identical content must not re-notify")

        transport.setStubs(stubs(eventID: "e2"))
        await engine.syncNow()
        XCTAssertEqual(snapshotChangeCount, 2, "new content notifies")
    }

    func testRemovedAccountIsPrunedFromSnapshot() async throws {
        let transport = FakeCalendarTransport(stubs: [
            .init(urlContains: "calendarList", statusCode: 200, body: Self.calendarListBody(ids: ["cal1"])),
            .init(urlContains: "/calendars/cal1/events", statusCode: 200, body: Self.eventsBody(
                events: [Self.event("e1", start: "2026-08-10T10:00:00Z", end: "2026-08-10T11:00:00Z")]
            )),
        ])
        let tokens = FakeTokenProvider()
        let (engine, store) = try makeEngine(transport: transport, tokenProvider: tokens, accountIDs: ["sub-1"])

        await engine.syncNow()
        XCTAssertFalse(engine.snapshot.isEmpty)

        store.remove(accountID: "sub-1")
        await engine.syncNow()

        XCTAssertTrue(engine.snapshot.isEmpty, "disconnected account's slice leaves the snapshot")
        XCTAssertEqual(snapshotChangeCount, 2, "pruning is a snapshot change")
    }
}
