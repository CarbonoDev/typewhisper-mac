import XCTest
@testable import TypeWhisper

// MARK: - File-scope helpers (callable from @Sendable transport handlers)

private func gmailListBody(_ refs: [(id: String, threadId: String)]) -> String {
    let messages = refs
        .map { #"{"id": "\#($0.id)", "threadId": "\#($0.threadId)"}"# }
        .joined(separator: ", ")
    return #"{"messages": [\#(messages)], "resultSizeEstimate": \#(refs.count)}"#
}

private func gmailMetadataBody(
    id: String,
    threadId: String,
    subject: String,
    from: String = "Ada Lovelace <ada@x.com>",
    internalDate: String,
    snippet: String = "snippet"
) -> String {
    #"""
    {"id": "\#(id)", "threadId": "\#(threadId)", "snippet": "\#(snippet)",
     "internalDate": "\#(internalDate)",
     "payload": {"mimeType": "text/plain",
                 "headers": [{"name": "Subject", "value": "\#(subject)"},
                             {"name": "From", "value": "\#(from)"}]}}
    """#
}

private func gmailFullBody(id: String, threadId: String, plainText: String) -> String {
    let data = Data(plainText.utf8).base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
    return #"""
    {"id": "\#(id)", "threadId": "\#(threadId)", "snippet": "s",
     "payload": {"mimeType": "text/plain", "body": {"data": "\#(data)"}}}
    """#
}

/// The message id in a `users/me/messages/{id}?…` URL.
private func gmailMessageID(in url: URL) -> String {
    url.deletingPathExtension().lastPathComponent
}

/// `GmailContextService` over a fake transport, fake token provider, and injected clock (§7):
/// two-call merge + threadId dedupe with attendee precedence, bounded-concurrency metadata
/// fetches, re-rank with date-order fallback, TTL cache + scope fingerprint, invalidation on
/// store `objectWillChange`, refresh bypass, per-account error isolation, `.needsReauth` skip,
/// and owning-account vs all-accounts resolution. No network, no Keychain, no real defaults.
@MainActor
final class GmailContextServiceTests: XCTestCase {
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

    /// Handler-routed canned transport: the handler synthesizes a response per request, so list /
    /// metadata / full calls route on the URL and the Authorization header. Tracks the maximum
    /// number of concurrently in-flight requests (the D-M1 bounded-width assertion); an optional
    /// delay keeps requests overlapping long enough to observe it.
    private final class FakeGmailTransport: GoogleHTTPTransport, @unchecked Sendable {
        private let lock = NSLock()
        private var handler: @Sendable (URLRequest) -> (statusCode: Int, body: String)
        private var _requests: [URLRequest] = []
        private var inFlight = 0
        private var _maxInFlight = 0
        private let delayNanoseconds: UInt64

        init(
            delayNanoseconds: UInt64 = 0,
            handler: @escaping @Sendable (URLRequest) -> (statusCode: Int, body: String)
        ) {
            self.delayNanoseconds = delayNanoseconds
            self.handler = handler
        }

        var requests: [URLRequest] {
            lock.lock()
            defer { lock.unlock() }
            return _requests
        }

        var maxInFlight: Int {
            lock.lock()
            defer { lock.unlock() }
            return _maxInFlight
        }

        func setHandler(_ new: @escaping @Sendable (URLRequest) -> (statusCode: Int, body: String)) {
            lock.lock()
            defer { lock.unlock() }
            handler = new
        }

        /// Synchronous bookkeeping under the lock (never `lock()` from an async context — the
        /// Phase 1 fake-transport precedent).
        private func begin(_ request: URLRequest) -> (@Sendable (URLRequest) -> (Int, String), UInt64) {
            lock.lock()
            defer { lock.unlock() }
            _requests.append(request)
            inFlight += 1
            _maxInFlight = max(_maxInFlight, inFlight)
            return (handler, delayNanoseconds)
        }

        private func end() {
            lock.lock()
            defer { lock.unlock() }
            inFlight -= 1
        }

        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            let (handler, delay) = begin(request)
            if delay > 0 {
                try? await Task.sleep(nanoseconds: delay)
            }
            end()
            let (statusCode, body) = handler(request)
            let response = HTTPURLResponse(
                url: request.url!, statusCode: statusCode, httpVersion: "HTTP/1.1", headerFields: nil
            )!
            return (Data(body.utf8), response)
        }
    }

    /// A canned-mailbox handler: list responses keyed by bearer token + per-clause `maxResults`,
    /// metadata/full responses keyed by message id. `failingTokens` simulates a per-account 500.
    private static func mailboxHandler(
        attendeeRefs: [String: [(id: String, threadId: String)]],
        subjectRefs: [String: [(id: String, threadId: String)]] = [:],
        metadata: [String: String],
        fullBodies: [String: (statusCode: Int, body: String)] = [:],
        failingTokens: Set<String> = []
    ) -> @Sendable (URLRequest) -> (statusCode: Int, body: String) {
        { request in
            let url = request.url!
            let urlString = url.absoluteString
            let token = (request.value(forHTTPHeaderField: "Authorization") ?? "")
                .replacingOccurrences(of: "Bearer ", with: "")
            if failingTokens.contains(token) {
                return (500, "boom")
            }
            if urlString.contains("format=metadata") {
                let id = gmailMessageID(in: url)
                return metadata[id].map { (200, $0) } ?? (404, "{}")
            }
            if urlString.contains("format=full") {
                let id = gmailMessageID(in: url)
                return fullBodies[id] ?? (404, "{}")
            }
            if urlString.contains("maxResults=25") {
                return (200, gmailListBody(attendeeRefs[token] ?? []))
            }
            if urlString.contains("maxResults=10") {
                return (200, gmailListBody(subjectRefs[token] ?? []))
            }
            return (500, "unmatched request: \(urlString)")
        }
    }

    // MARK: - Harness

    /// Mutable wall clock captured by the service's injected `now`.
    private final class ClockBox {
        var current = Date(timeIntervalSince1970: 1_786_399_200) // 2026-08-10T22:00:00Z
    }

    private var suiteName: String!
    private var defaults: UserDefaults!
    private var clock: ClockBox!

    override func setUp() {
        super.setUp()
        suiteName = "GmailContextServiceTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        clock = ClockBox()
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    /// A store + service over the fakes. Each account tuple: `(sub, gmailEnabled)`; every account
    /// is `.connected` with the Gmail scope granted and email `<sub>@example.com`, token
    /// `token-<sub>`.
    private func makeService(
        accounts: [(sub: String, gmailEnabled: Bool)],
        transport: FakeGmailTransport,
        tokenProvider: FakeTokenProvider? = nil
    ) throws -> (service: GmailContextService, store: GoogleAccountStore, tokens: FakeTokenProvider) {
        let store = GoogleAccountStore(defaults: defaults, secretStore: InMemorySecretStore())
        let tokens = tokenProvider ?? FakeTokenProvider()
        for (sub, enabled) in accounts {
            try store.upsert(
                GoogleAccount(
                    id: sub,
                    email: "\(sub)@example.com",
                    displayName: nil,
                    grantedScopes: ["openid", GmailContextService.gmailScope],
                    connectedAt: clock.current,
                    statusRaw: GoogleAccountStatus.connected.rawValue
                ),
                refreshToken: "rt-\(sub)"
            )
            store.setGmailEnabled(enabled, for: sub)
            if tokens.results[sub] == nil {
                tokens.results[sub] = .success("token-\(sub)")
            }
        }
        let clock = self.clock!
        let service = GmailContextService(
            store: store,
            tokenProvider: tokens,
            transport: transport,
            now: { clock.current }
        )
        return (service, store, tokens)
    }

    /// A calendar meeting owned by `sub` (or ad-hoc when `nil`) with one non-self attendee.
    private func makeMeeting(
        title: String = "Acme Budget Review",
        owningSub: String? = nil,
        attendees: [Attendee] = [Attendee(name: "Ada", email: "ada@x.com")]
    ) -> Meeting {
        let meeting = Meeting(title: title, startDate: clock.current.addingTimeInterval(3_600))
        meeting.calendarEventID = owningSub.map { "google:\($0):evt-1" }
        meeting.attendees = attendees
        return meeting
    }

    /// Waits for a block previously enqueued on the main queue (the cache-invalidation hop).
    private func drainMainQueue() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    private func listRequestCount(_ transport: FakeGmailTransport) -> Int {
        transport.requests.filter { $0.url!.absoluteString.contains("maxResults=") }.count
    }

    // MARK: - Two-call merge (D-M1 step 2)

    func testTwoCallMergeDedupesByThreadIDWithAttendeePrecedence() async throws {
        let transport = FakeGmailTransport(handler: Self.mailboxHandler(
            attendeeRefs: ["token-subA": [("a1", "t1"), ("a2", "t2")]],
            // s1 duplicates thread t1 → dropped (attendee result wins); s3 is a new thread.
            subjectRefs: ["token-subA": [("s1", "t1"), ("s3", "t3")]],
            metadata: [
                "a1": gmailMetadataBody(id: "a1", threadId: "t1", subject: "Budget v2", internalDate: "1786300000000"),
                "a2": gmailMetadataBody(id: "a2", threadId: "t2", subject: "Kickoff", internalDate: "1786200000000"),
                "s3": gmailMetadataBody(id: "s3", threadId: "t3", subject: "Acme intro", internalDate: "1786100000000"),
            ]
        ))
        let (service, _, _) = try makeService(accounts: [("subA", true)], transport: transport)

        let candidates = try await service.candidates(for: makeMeeting())

        XCTAssertEqual(
            candidates.map(\.id),
            ["google:subA:a1", "google:subA:a2", "google:subA:s3"],
            "merged, thread-deduped, date-descending"
        )
        XCTAssertEqual(candidates.map(\.threadID), ["t1", "t2", "t3"])
        XCTAssertEqual(candidates.first?.accountEmail, "subA@example.com")
        let metadataIDs = transport.requests
            .filter { $0.url!.absoluteString.contains("format=metadata") }
            .map { gmailMessageID(in: $0.url!) }
        XCTAssertFalse(metadataIDs.contains("s1"), "the deduped ref is never fetched")

        // The two list calls carry the per-clause caps and the right q clauses.
        let listURLs = transport.requests.compactMap(\.url).map(\.absoluteString).filter { $0.contains("maxResults=") }
        XCTAssertEqual(listURLs.count, 2)
        let attendeeList = try XCTUnwrap(listURLs.first { $0.contains("maxResults=25") })
        XCTAssertTrue(attendeeList.contains("from:ada"), "attendee clause targets the attendee address")
        let subjectList = try XCTUnwrap(listURLs.first { $0.contains("maxResults=10") })
        XCTAssertTrue(subjectList.contains("subject"), "subject clause is subject-scoped")
    }

    func testNoSignalsReturnsEmptyWithoutANetworkCall() async throws {
        let transport = FakeGmailTransport(handler: { _ in (500, "must not be called") })
        let (service, _, _) = try makeService(accounts: [("subA", true)], transport: transport)
        // Stop-word-only title AND no attendee emails ⇒ both queries nil (D-M1 step 1).
        let meeting = makeMeeting(title: "To The And", attendees: [Attendee(name: "Nameless")])

        let candidates = try await service.candidates(for: meeting)

        XCTAssertEqual(candidates, [])
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testSelfExclusionCoversSelfAttendeesAndAllConnectedAccountEmails() async throws {
        let transport = FakeGmailTransport(handler: Self.mailboxHandler(
            attendeeRefs: ["token-subA": []], subjectRefs: [:], metadata: [:]
        ))
        // subB is a second connected account — its email must be excluded even though subB itself
        // is not Gmail-enabled (D-M2: ALL connected accounts).
        let (service, _, _) = try makeService(accounts: [("subA", true), ("subB", false)], transport: transport)
        let meeting = makeMeeting(attendees: [
            Attendee(name: "Ada", email: "ada@x.com"),
            Attendee(name: "Me", email: "ME@personal.com", isSelf: true),
            Attendee(name: "Other me", email: "subB@example.com"),
        ])

        _ = try await service.candidates(for: meeting)

        let attendeeList = try XCTUnwrap(
            transport.requests.compactMap(\.url).map(\.absoluteString).first { $0.contains("maxResults=25") }
        )
        XCTAssertTrue(attendeeList.contains("ada"))
        XCTAssertFalse(attendeeList.lowercased().contains("personal.com"), "isSelf attendee excluded")
        XCTAssertFalse(attendeeList.lowercased().contains("subb"), "connected-account email excluded")
    }

    // MARK: - Request encoding (M1 review)

    func testListRequestPercentEncodesPlusSoGoogleNeverDecodesItAsASpace() {
        let request = GmailAPI.listRequest(
            token: "t",
            query: "(from:john+cal@x.com OR to:john+cal@x.com) after:2026/07/27",
            maxResults: 25
        )
        let url = request.url!.absoluteString
        XCTAssertTrue(url.contains("john%2Bcal@x.com"), "plus-addressed attendees stay intact: \(url)")
        XCTAssertFalse(url.contains("john+cal"), "a literal + would decode server-side as a space")
    }

    func testPlusAddressedAttendeeSurvivesEndToEnd() async throws {
        let transport = FakeGmailTransport(handler: Self.mailboxHandler(
            attendeeRefs: ["token-subA": []], metadata: [:]
        ))
        let (service, _, _) = try makeService(accounts: [("subA", true)], transport: transport)

        _ = try await service.candidates(
            for: makeMeeting(attendees: [Attendee(name: "John", email: "john+cal@x.com")])
        )

        let attendeeList = try XCTUnwrap(
            transport.requests.compactMap(\.url).map(\.absoluteString).first { $0.contains("maxResults=25") }
        )
        XCTAssertTrue(attendeeList.contains("john%2Bcal@x.com"))
        XCTAssertFalse(attendeeList.contains("john+cal"))
    }

    // MARK: - Bounded concurrency (D-M1 step 3, normative)

    func testMetadataFetchesRunConcurrentlyBoundedAtWidthSix() async throws {
        let refs = (1...15).map { (id: "m\($0)", threadId: "t\($0)") }
        var metadata: [String: String] = [:]
        for (index, ref) in refs.enumerated() {
            metadata[ref.id] = gmailMetadataBody(
                id: ref.id, threadId: ref.threadId, subject: "Mail \(index)",
                internalDate: "\(1_786_000_000_000 + index * 1_000)"
            )
        }
        let transport = FakeGmailTransport(
            delayNanoseconds: 30_000_000,
            handler: Self.mailboxHandler(attendeeRefs: ["token-subA": refs], metadata: metadata)
        )
        let (service, _, _) = try makeService(accounts: [("subA", true)], transport: transport)

        let candidates = try await service.candidates(for: makeMeeting())

        XCTAssertEqual(candidates.count, 15, "every ref's metadata landed")
        XCTAssertLessThanOrEqual(transport.maxInFlight, GmailContextService.metadataFetchWidth)
        XCTAssertGreaterThan(transport.maxInFlight, 1, "the fetches actually overlapped")
    }

    // MARK: - Re-rank (D-M1 step 4) + bodies (step 5)

    func testRetrieveRanksLexicallyAndFetchesBodiesForTopKOnly() async throws {
        let transport = FakeGmailTransport(handler: Self.mailboxHandler(
            attendeeRefs: ["token-subA": [("m1", "t1"), ("m2", "t2"), ("m3", "t3")]],
            metadata: [
                "m1": gmailMetadataBody(id: "m1", threadId: "t1", subject: "Lunch", internalDate: "1786300000000"),
                "m2": gmailMetadataBody(id: "m2", threadId: "t2", subject: "Contract draft attached", internalDate: "1786200000000", snippet: "the contract terms"),
                "m3": gmailMetadataBody(id: "m3", threadId: "t3", subject: "Standup", internalDate: "1786100000000"),
            ],
            fullBodies: ["m2": (200, gmailFullBody(id: "m2", threadId: "t2", plainText: "Full contract body text."))]
        ))
        let (service, _, _) = try makeService(accounts: [("subA", true)], transport: transport)

        let passages = try await service.retrieve(for: makeMeeting(), query: "contract terms", limit: 1)

        XCTAssertEqual(passages.map(\.id), ["google:subA:m2"], "lexical overlap wins the rank")
        XCTAssertEqual(passages.first?.content, "Full contract body text.")
        let fullFetches = transport.requests.filter { $0.url!.absoluteString.contains("format=full") }
        XCTAssertEqual(fullFetches.count, 1, "bodies only for the top-K actually returned")
    }

    func testRetrieveFallsBackToDateDescendingWhenLexicalRankIsEmpty() async throws {
        let transport = FakeGmailTransport(handler: Self.mailboxHandler(
            attendeeRefs: ["token-subA": [("old", "t1"), ("new", "t2")]],
            metadata: [
                "old": gmailMetadataBody(id: "old", threadId: "t1", subject: "Alpha", internalDate: "1786100000000"),
                "new": gmailMetadataBody(id: "new", threadId: "t2", subject: "Beta", internalDate: "1786300000000"),
            ]
        ))
        let (service, _, _) = try makeService(accounts: [("subA", true)], transport: transport)

        // No content-term overlap with any candidate — the server query already established
        // relevance, so the list must not blank (D-M1 step 4).
        let passages = try await service.retrieve(for: makeMeeting(), query: "zzz unrelated nonsense", limit: 1)

        XCTAssertEqual(passages.map(\.id), ["google:subA:new"], "date-descending fallback, truncated to limit")
        XCTAssertEqual(passages.first?.content, "snippet", "404 full fetch degrades to the snippet")
    }

    // MARK: - Cache (D-M1, normative)

    func testCandidatesServedFromCacheWithinTTLAndFingerprintStableAcrossSameDayFetches() async throws {
        let transport = FakeGmailTransport(handler: Self.mailboxHandler(
            attendeeRefs: ["token-subA": [("m1", "t1")]],
            metadata: ["m1": gmailMetadataBody(id: "m1", threadId: "t1", subject: "Hi", internalDate: "1786300000000")]
        ))
        let (service, _, _) = try makeService(accounts: [("subA", true)], transport: transport)
        let meeting = makeMeeting()

        _ = try await service.candidates(for: meeting)
        let listsAfterFirst = listRequestCount(transport)

        // Two minutes later, same day: the serialized window is unchanged, so the fingerprint
        // matches and the TTL is fresh — served from cache, zero new requests.
        clock.current = clock.current.addingTimeInterval(120)
        let cached = try await service.candidates(for: meeting)

        XCTAssertEqual(cached.map(\.id), ["google:subA:m1"])
        XCTAssertEqual(listRequestCount(transport), listsAfterFirst, "no refetch within TTL")
    }

    func testCacheExpiresAfterTTL() async throws {
        let transport = FakeGmailTransport(handler: Self.mailboxHandler(
            attendeeRefs: ["token-subA": [("m1", "t1")]],
            metadata: ["m1": gmailMetadataBody(id: "m1", threadId: "t1", subject: "Hi", internalDate: "1786300000000")]
        ))
        let (service, _, _) = try makeService(accounts: [("subA", true)], transport: transport)
        let meeting = makeMeeting()

        _ = try await service.candidates(for: meeting)
        let listsAfterFirst = listRequestCount(transport)

        clock.current = clock.current.addingTimeInterval(GmailContextService.defaultCacheTTL + 1)
        _ = try await service.candidates(for: meeting)

        XCTAssertEqual(listRequestCount(transport), listsAfterFirst * 2, "expired entry refetches")
    }

    func testFingerprintMissOnAttendeeChangeRefetchesWithinTTL() async throws {
        let transport = FakeGmailTransport(handler: Self.mailboxHandler(
            attendeeRefs: ["token-subA": [("m1", "t1")]],
            metadata: ["m1": gmailMetadataBody(id: "m1", threadId: "t1", subject: "Hi", internalDate: "1786300000000")]
        ))
        let (service, _, _) = try makeService(accounts: [("subA", true)], transport: transport)
        let meeting = makeMeeting()

        _ = try await service.candidates(for: meeting)
        let listsAfterFirst = listRequestCount(transport)

        meeting.attendees = meeting.attendees + [Attendee(name: "Bob", email: "bob@y.org")]
        _ = try await service.candidates(for: meeting)

        XCTAssertGreaterThan(listRequestCount(transport), listsAfterFirst, "attendee-set change misses the fingerprint")
    }

    func testFingerprintMissOnWindowChangeRefetchesWithinTTL() async throws {
        let transport = FakeGmailTransport(handler: Self.mailboxHandler(
            attendeeRefs: ["token-subA": [("m1", "t1")]],
            metadata: ["m1": gmailMetadataBody(id: "m1", threadId: "t1", subject: "Hi", internalDate: "1786300000000")]
        ))
        let (service, _, _) = try makeService(accounts: [("subA", true)], transport: transport)
        let meeting = makeMeeting()

        _ = try await service.candidates(for: meeting)
        let listsAfterFirst = listRequestCount(transport)

        meeting.startDate = meeting.startDate?.addingTimeInterval(5 * 86_400)
        _ = try await service.candidates(for: meeting)

        XCTAssertGreaterThan(listRequestCount(transport), listsAfterFirst, "a different day window misses the fingerprint")
    }

    func testStoreObjectWillChangeInvalidatesTheCacheWholesale() async throws {
        let transport = FakeGmailTransport(handler: Self.mailboxHandler(
            attendeeRefs: ["token-subA": [("m1", "t1")]],
            metadata: ["m1": gmailMetadataBody(id: "m1", threadId: "t1", subject: "Hi", internalDate: "1786300000000")]
        ))
        let (service, store, _) = try makeService(accounts: [("subA", true)], transport: transport)
        let meeting = makeMeeting()

        _ = try await service.candidates(for: meeting)
        let listsAfterFirst = listRequestCount(transport)

        // A Gmail-toggle flip announces only via `objectWillChange` (D-M7); the invalidation
        // sink hops through the main queue, so drain it before asserting.
        store.setGmailEnabled(true, for: "subA")
        await drainMainQueue()
        _ = try await service.candidates(for: meeting)

        XCTAssertGreaterThan(
            listRequestCount(transport), listsAfterFirst,
            "identical scope + fresh TTL, yet the store change dropped the entry"
        )
    }

    func testRefreshBypassesAFreshCache() async throws {
        let transport = FakeGmailTransport(handler: Self.mailboxHandler(
            attendeeRefs: ["token-subA": [("m1", "t1")]],
            metadata: ["m1": gmailMetadataBody(id: "m1", threadId: "t1", subject: "Hi", internalDate: "1786300000000")]
        ))
        let (service, _, _) = try makeService(accounts: [("subA", true)], transport: transport)
        let meeting = makeMeeting()

        _ = try await service.candidates(for: meeting)
        let listsAfterFirst = listRequestCount(transport)

        _ = try await service.refresh(for: meeting)

        XCTAssertEqual(listRequestCount(transport), listsAfterFirst * 2, "refresh always refetches")
    }

    // MARK: - Single-flight (M1 review)

    func testConcurrentSameMeetingCallsShareOneNetworkPass() async throws {
        let transport = FakeGmailTransport(
            delayNanoseconds: 30_000_000, // holds the first fetch open so the second call joins it
            handler: Self.mailboxHandler(
                attendeeRefs: ["token-subA": [("m1", "t1")]],
                metadata: ["m1": gmailMetadataBody(id: "m1", threadId: "t1", subject: "Hi", internalDate: "1786300000000")]
            )
        )
        let (service, _, _) = try makeService(accounts: [("subA", true)], transport: transport)
        let meeting = makeMeeting()

        let first = Task { try await service.candidates(for: meeting) }
        let second = Task { try await service.candidates(for: meeting) }
        let firstResult = try await first.value
        let secondResult = try await second.value

        XCTAssertEqual(firstResult.map(\.id), ["google:subA:m1"])
        XCTAssertEqual(firstResult, secondResult, "both callers get the shared pass's result")
        XCTAssertEqual(listRequestCount(transport), 2, "one two-call pass — never doubled")
        XCTAssertFalse(service.isFetching, "flag clears once the in-flight map empties")
    }

    // MARK: - Multi-account resolution (D-M2) + error isolation

    func testMeetingOwnedByEnabledAccountSearchesOnlyThatAccount() async throws {
        let transport = FakeGmailTransport(handler: Self.mailboxHandler(
            attendeeRefs: [
                "token-subA": [("a1", "t1")],
                "token-subB": [("b1", "t9")],
            ],
            metadata: ["a1": gmailMetadataBody(id: "a1", threadId: "t1", subject: "Hi", internalDate: "1786300000000")]
        ))
        let (service, _, tokens) = try makeService(accounts: [("subA", true), ("subB", true)], transport: transport)

        let candidates = try await service.candidates(for: makeMeeting(owningSub: "subA"))

        XCTAssertEqual(candidates.map(\.accountSub), ["subA"], "owning account searched exclusively")
        XCTAssertFalse(tokens.requestedAccountIDs.contains("subB"), "no token fetch for the sibling")
    }

    func testMeetingOwnedByDisabledAccountFallsBackToAllEnabledAccounts() async throws {
        let transport = FakeGmailTransport(handler: Self.mailboxHandler(
            attendeeRefs: ["token-subB": [("b1", "t9")]],
            metadata: ["b1": gmailMetadataBody(id: "b1", threadId: "t9", subject: "Hi", internalDate: "1786300000000")]
        ))
        let (service, _, _) = try makeService(accounts: [("subA", false), ("subB", true)], transport: transport)

        let candidates = try await service.candidates(for: makeMeeting(owningSub: "subA"))

        XCTAssertEqual(candidates.map(\.accountSub), ["subB"], "owner not Gmail-enabled ⇒ all enabled accounts")
    }

    func testAdHocMeetingMergesCandidatesFromEveryEnabledAccount() async throws {
        let transport = FakeGmailTransport(handler: Self.mailboxHandler(
            attendeeRefs: [
                "token-subA": [("a1", "t1")],
                "token-subB": [("b1", "t9")],
            ],
            metadata: [
                "a1": gmailMetadataBody(id: "a1", threadId: "t1", subject: "Older", internalDate: "1786100000000"),
                "b1": gmailMetadataBody(id: "b1", threadId: "t9", subject: "Newer", internalDate: "1786300000000"),
            ]
        ))
        let (service, _, _) = try makeService(accounts: [("subA", true), ("subB", true)], transport: transport)

        let candidates = try await service.candidates(for: makeMeeting(owningSub: nil))

        XCTAssertEqual(
            candidates.map(\.id),
            ["google:subB:b1", "google:subA:a1"],
            "merged across accounts, date-descending; each keeps its accountSub"
        )
    }

    func testPerAccountFailureKeepsTheOtherAccountsCandidates() async throws {
        let transport = FakeGmailTransport(handler: Self.mailboxHandler(
            attendeeRefs: ["token-subA": [("a1", "t1")]],
            metadata: ["a1": gmailMetadataBody(id: "a1", threadId: "t1", subject: "Hi", internalDate: "1786300000000")],
            failingTokens: ["token-subB"]
        ))
        let (service, _, _) = try makeService(accounts: [("subA", true), ("subB", true)], transport: transport)
        let meeting = makeMeeting()

        let candidates = try await service.candidates(for: meeting)

        XCTAssertEqual(candidates.map(\.accountSub), ["subA"], "subB's 500 never drops subA's candidates")
        // The partial loss is surfaced, not hidden behind the merged remainder (M1 review
        // adjudication) — and names the failing account.
        let partial = try XCTUnwrap(service.lastPartialError(for: meeting))
        XCTAssertTrue(partial.contains("subB@example.com"), "detail names the failing account: \(partial)")

        // A fully clean refetch clears it.
        transport.setHandler(Self.mailboxHandler(
            attendeeRefs: [
                "token-subA": [("a1", "t1")],
                "token-subB": [("b1", "t9")],
            ],
            metadata: [
                "a1": gmailMetadataBody(id: "a1", threadId: "t1", subject: "Hi", internalDate: "1786300000000"),
                "b1": gmailMetadataBody(id: "b1", threadId: "t9", subject: "Yo", internalDate: "1786200000000"),
            ]
        ))
        _ = try await service.refresh(for: meeting)
        XCTAssertNil(service.lastPartialError(for: meeting), "cleared on full success")
    }

    func testThrowsOnlyWhenEveryAccountFails() async throws {
        let transport = FakeGmailTransport(handler: Self.mailboxHandler(
            attendeeRefs: [:], metadata: [:], failingTokens: ["token-subA"]
        ))
        let (service, _, _) = try makeService(accounts: [("subA", true)], transport: transport)

        do {
            _ = try await service.candidates(for: makeMeeting())
            XCTFail("expected a throw")
        } catch let error as GmailAPI.RequestFailed {
            XCTAssertEqual(error.statusCode, 500)
        }
    }

    func testNeedsReauthAccountIsNeverSearched() async throws {
        let transport = FakeGmailTransport(handler: Self.mailboxHandler(
            attendeeRefs: ["token-subA": [("a1", "t1")]],
            metadata: ["a1": gmailMetadataBody(id: "a1", threadId: "t1", subject: "Hi", internalDate: "1786300000000")]
        ))
        let (service, store, tokens) = try makeService(accounts: [("subA", true), ("subB", true)], transport: transport)
        store.setStatus(.needsReauth, for: "subB")
        await drainMainQueue() // let the status change's invalidation land before fetching

        let candidates = try await service.candidates(for: makeMeeting())

        XCTAssertEqual(candidates.map(\.accountSub), ["subA"])
        XCTAssertFalse(tokens.requestedAccountIDs.contains("subB"), "flagged account skipped, never retried")
    }

    // MARK: - Connectivity (D-M7)

    func testIsConnectedRequiresAnEligibleAccountAndHonorsOwningAccountResolution() throws {
        let transport = FakeGmailTransport(handler: { _ in (500, "unused") })
        let (service, store, _) = try makeService(accounts: [("subA", true), ("subB", false)], transport: transport)

        XCTAssertTrue(service.isConnected)
        XCTAssertTrue(service.isConnected(for: makeMeeting(owningSub: "subA")))
        // Owned by the disabled account, but another enabled account exists → still connected
        // (the fallback searches all enabled accounts).
        XCTAssertTrue(service.isConnected(for: makeMeeting(owningSub: "subB")))

        store.setGmailEnabled(false, for: "subA")
        XCTAssertFalse(service.isConnected)
        XCTAssertFalse(service.isConnected(for: makeMeeting(owningSub: "subB")))
    }
}
