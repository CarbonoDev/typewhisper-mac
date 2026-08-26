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
        /// Applied to the *first* request only: holds cycle 1 open long enough for a test to act
        /// mid-cycle (the connect-during-cycle test), leaving follow-up cycles fast.
        private let firstRequestDelayNanoseconds: UInt64
        private var delayedOnce = false

        init(stubs: [Stub], firstRequestDelayNanoseconds: UInt64 = 0) {
            self.stubs = stubs
            self.firstRequestDelayNanoseconds = firstRequestDelayNanoseconds
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
        /// Returns whether the first-request hold should apply to this request.
        private func recordAndMatch(_ request: URLRequest) -> (stub: Stub?, delay: UInt64) {
            lock.lock()
            defer { lock.unlock() }
            _requests.append(request)
            let delay = delayedOnce ? 0 : firstRequestDelayNanoseconds
            delayedOnce = true
            let url = request.url?.absoluteString ?? ""
            guard let index = stubs.firstIndex(where: { url.contains($0.urlContains) }) else {
                return (nil, delay)
            }
            return (stubs.remove(at: index), delay)
        }

        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            let (matched, delay) = recordAndMatch(request)
            if delay > 0 {
                try await Task.sleep(nanoseconds: delay)
            }
            guard let stub = matched else {
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
    /// Counts `.googleCalendarSnapshotDidChange` posts.
    ///
    /// Held in a separate reference box rather than as a stored property so the observer closure —
    /// which `NotificationCenter` declares `@Sendable` — captures the box instead of `self`: a
    /// `@MainActor` `XCTestCase` is not `Sendable`, so capturing it there is a concurrency warning.
    private final class SnapshotChangeCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        var count: Int { lock.withLock { value } }
        func increment() { lock.withLock { value += 1 } }
        func reset() { lock.withLock { value = 0 } }
    }

    private let snapshotChanges = SnapshotChangeCounter()
    private var snapshotChangeCount: Int { snapshotChanges.count }
    private var observer: NSObjectProtocol?

    override func setUp() async throws {
        try await super.setUp()
        suiteName = "GoogleCalendarSyncEngineTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        snapshotChanges.reset()
        observer = NotificationCenter.default.addObserver(
            forName: .googleCalendarSnapshotDidChange,
            object: nil,
            queue: .main
        ) { [snapshotChanges] _ in
            snapshotChanges.increment()
        }
    }

    override func tearDown() async throws {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
        defaults.removePersistentDomain(forName: suiteName)
        try await super.tearDown()
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

    // MARK: - Coalescing (M3 review finding 1)

    func testAccountConnectedDuringCycleIsFetchedByAnImmediateFollowUpCycle() async throws {
        // Cycle 1 read `store.accounts` before subB existed; the coalescing `syncNow` must make
        // the driver loop one more full cycle so subB's events land without waiting for the next
        // 5-min tick (QA step 6: "events within ~1 min of connect").
        let a1 = Self.event("a1", start: "2026-08-10T10:00:00Z", end: "2026-08-10T11:00:00Z")
        let b1 = Self.event("b1", start: "2026-08-10T14:00:00Z", end: "2026-08-10T15:00:00Z")
        let transport = FakeCalendarTransport(
            stubs: [
                // Cycle 1 (subA only) — the first request is held open so the connect lands mid-cycle.
                .init(urlContains: "calendarList", statusCode: 200, body: Self.calendarListBody(ids: ["calA"])),
                .init(urlContains: "/calendars/calA/events", statusCode: 200, body: Self.eventsBody(events: [a1])),
                // Cycle 2 (subA + subB).
                .init(urlContains: "calendarList", statusCode: 200, body: Self.calendarListBody(ids: ["calA"])),
                .init(urlContains: "/calendars/calA/events", statusCode: 200, body: Self.eventsBody(events: [a1])),
                .init(urlContains: "calendarList", statusCode: 200, body: Self.calendarListBody(ids: ["calB"])),
                .init(urlContains: "/calendars/calB/events", statusCode: 200, body: Self.eventsBody(events: [b1])),
            ],
            firstRequestDelayNanoseconds: 100_000_000
        )
        let tokens = FakeTokenProvider()
        let (engine, store) = try makeEngine(transport: transport, tokenProvider: tokens, accountIDs: ["subA"])

        let firstCall = Task { await engine.syncNow() }
        // Wait until cycle 1 is provably in flight (its first request recorded, response held).
        while transport.requests.isEmpty {
            await Task.yield()
        }

        // Connect subB mid-cycle, then trigger the immediate re-sync (in production `start()`'s
        // `$accounts` subscription calls `syncNow()`; tests drive it directly). This call must
        // coalesce into the running driver and request one more cycle — not silently no-op.
        tokens.results["subB"] = .success("token-subB")
        try store.upsert(
            GoogleAccount(
                id: "subB",
                email: "subB@example.com",
                displayName: nil,
                grantedScopes: ["openid"],
                connectedAt: fixedNow,
                statusRaw: GoogleAccountStatus.connected.rawValue
            ),
            refreshToken: "rt-subB"
        )
        await engine.syncNow()
        await firstCall.value

        XCTAssertEqual(
            engine.snapshot.flatMap(\.events).map(\.id),
            ["google:subA:a1", "google:subB:b1"],
            "the follow-up cycle fetched the mid-cycle connect — no 5-min tick needed"
        )
        let calendarListFetches = transport.requests.filter {
            $0.url?.absoluteString.contains("calendarList") == true
        }
        XCTAssertEqual(calendarListFetches.count, 3, "cycle 1 (subA) + cycle 2 (subA and subB) — exactly one extra cycle")
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

    // MARK: - Per-calendar isolation (PR #7 review finding 1)

    func testOneFailingCalendarDoesNotAbortTheAccountsOtherCalendars() async throws {
        // A shared/subscribed calendar whose `events.list` 403s forever must not freeze the whole
        // account slice — the other calendars' events still land, and the failure is reported.
        let transport = FakeCalendarTransport(stubs: [
            .init(urlContains: "calendarList", statusCode: 200, body: Self.calendarListBody(ids: ["cal1", "cal2", "cal3"])),
            .init(urlContains: "/calendars/cal1/events", statusCode: 200, body: Self.eventsBody(
                events: [Self.event("e1", start: "2026-08-10T10:00:00Z", end: "2026-08-10T11:00:00Z")]
            )),
            .init(urlContains: "/calendars/cal2/events", statusCode: 403, body: #"{"error": "forbidden"}"#),
            .init(urlContains: "/calendars/cal3/events", statusCode: 200, body: Self.eventsBody(
                events: [Self.event("e3", start: "2026-08-10T14:00:00Z", end: "2026-08-10T15:00:00Z")]
            )),
        ])
        let tokens = FakeTokenProvider()
        let (engine, _) = try makeEngine(transport: transport, tokenProvider: tokens, accountIDs: ["sub-1"])

        await engine.syncNow()

        XCTAssertEqual(
            engine.snapshot.flatMap(\.events).map(\.id),
            ["google:sub-1:e1", "google:sub-1:e3"],
            "the two readable calendars' events land despite the 403 in between"
        )
        XCTAssertEqual(
            engine.snapshot.map(\.calendar.id),
            ["google:sub-1:cal1", "google:sub-1:cal3"],
            "a calendar with no previously fetched events is skipped, not emptied into the snapshot"
        )
        let error = try XCTUnwrap(engine.lastSyncError, "the partial failure is user-facing")
        XCTAssertTrue(error.contains("sub-1@example.com"), "the note names the account")
        XCTAssertTrue(error.contains("1"), "the note carries the failed-calendar count")
        XCTAssertEqual(engine.lastSyncAt, fixedNow, "the cycle still counts as attempted")
    }

    func testFailingCalendarKeepsItsOwnLastGoodEventsWhileSiblingsUpdate() async throws {
        let transport = FakeCalendarTransport(stubs: [
            .init(urlContains: "calendarList", statusCode: 200, body: Self.calendarListBody(ids: ["cal1", "cal2"])),
            .init(urlContains: "/calendars/cal1/events", statusCode: 200, body: Self.eventsBody(
                events: [Self.event("a1", start: "2026-08-10T10:00:00Z", end: "2026-08-10T11:00:00Z")]
            )),
            .init(urlContains: "/calendars/cal2/events", statusCode: 200, body: Self.eventsBody(
                events: [Self.event("b1", start: "2026-08-10T12:00:00Z", end: "2026-08-10T13:00:00Z")]
            )),
        ])
        let tokens = FakeTokenProvider()
        let (engine, _) = try makeEngine(transport: transport, tokenProvider: tokens, accountIDs: ["sub-1"])
        await engine.syncNow()
        XCTAssertNil(engine.lastSyncError)

        // Cycle 2: cal1 gains a new event, cal2 breaks — cal2 degrades to stale, never to empty.
        transport.setStubs([
            .init(urlContains: "calendarList", statusCode: 200, body: Self.calendarListBody(ids: ["cal1", "cal2"])),
            .init(urlContains: "/calendars/cal1/events", statusCode: 200, body: Self.eventsBody(
                events: [Self.event("a2", start: "2026-08-10T16:00:00Z", end: "2026-08-10T17:00:00Z")]
            )),
            .init(urlContains: "/calendars/cal2/events", statusCode: 404, body: "gone"),
        ])
        await engine.syncNow()

        XCTAssertEqual(
            engine.snapshot.flatMap(\.events).map(\.id),
            ["google:sub-1:a2", "google:sub-1:b1"],
            "cal1 updated; cal2 served from its own last good events"
        )
        XCTAssertNotNil(engine.lastSyncError)
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
