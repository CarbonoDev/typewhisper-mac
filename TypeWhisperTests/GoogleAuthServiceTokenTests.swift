import XCTest
@testable import TypeWhisper

/// `GoogleAuthService` over a fake transport, an in-memory secret store, a fake loopback server,
/// and an injected clock (§7). Covers token management (refresh on the 60 s expiry skew,
/// single-flight per account, `invalid_grant` → `.needsReauth`) and the connect-flow state
/// machine (cancel mid-wait, restart-while-pending — SR review). No test binds a listener or
/// opens a browser; redirects are delivered by invoking the fake server's `onCallback` directly.
@MainActor
final class GoogleAuthServiceTokenTests: XCTestCase {
    // MARK: - Fakes

    /// Records start/stop and exposes `onCallback` so tests deliver the redirect directly.
    private final class FakeLoopbackServer: GoogleLoopbackServing {
        var onCallback: @MainActor (URL) -> Void = { _ in }
        private(set) var started = false
        private(set) var stopped = false

        func start() async throws -> UInt16 {
            started = true
            return 49152
        }

        func stop() {
            stopped = true
        }
    }

    private final class InMemorySecretStore: GoogleSecretStoring {
        private var secrets: [String: String] = [:]
        func save(_ secret: String, service: String) throws { secrets[service] = secret }
        func load(service: String) -> String? { secrets[service] }
        func delete(service: String) throws { secrets[service] = nil }
        func deleteAll(prefix: String) throws {
            secrets = secrets.filter { !$0.key.hasPrefix(prefix) }
        }
    }

    /// Canned-response transport. `delayNanoseconds` keeps a refresh in flight long enough for a
    /// second caller to arrive (the single-flight test); the lock makes the call log Sendable-safe.
    private final class FakeTransport: GoogleHTTPTransport, @unchecked Sendable {
        struct CannedResponse {
            let statusCode: Int
            let body: String
        }

        private let lock = NSLock()
        private var responses: [CannedResponse]
        private var _requests: [URLRequest] = []
        let delayNanoseconds: UInt64

        init(responses: [CannedResponse], delayNanoseconds: UInt64 = 0) {
            self.responses = responses
            self.delayNanoseconds = delayNanoseconds
        }

        var requests: [URLRequest] {
            lock.lock()
            defer { lock.unlock() }
            return _requests
        }

        /// Records the request and dequeues the next canned response under the lock — a
        /// synchronous helper so the async `send` never holds the lock across a suspension.
        private func recordAndDequeue(_ request: URLRequest) -> CannedResponse? {
            lock.lock()
            defer { lock.unlock() }
            _requests.append(request)
            return responses.isEmpty ? nil : responses.removeFirst()
        }

        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            let canned = recordAndDequeue(request)
            if delayNanoseconds > 0 {
                try await Task.sleep(nanoseconds: delayNanoseconds)
            }
            guard let canned else {
                throw URLError(.unsupportedURL)
            }
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: canned.statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: nil
            )!
            return (Data(canned.body.utf8), response)
        }
    }

    private static func tokenBody(accessToken: String, expiresIn: Int = 3600) -> String {
        #"{"access_token": "\#(accessToken)", "expires_in": \#(expiresIn), "token_type": "Bearer"}"#
    }

    // MARK: - Harness

    private var suiteName: String!
    private var defaults: UserDefaults!
    private var store: GoogleAccountStore!
    /// Mutable wall clock injected into the service so skew math is deterministic.
    private var currentDate = Date(timeIntervalSince1970: 1_700_000_000)
    /// Authorization URLs the service "opened in the browser" (flow tests read `state` from them).
    private var openedURLs: [URL] = []

    override func setUp() {
        super.setUp()
        suiteName = "GoogleAuthServiceTokenTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        currentDate = Date(timeIntervalSince1970: 1_700_000_000)
        openedURLs = []
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    /// Builds the store (configured client + one connected account with a stored refresh token)
    /// and the service under test. MainActor helper rather than `setUp` — the store and service
    /// are MainActor-isolated, the inherited `setUp` override is not. Token-only tests pass no
    /// `servers`: any browser open or server creation then fails the test; flow tests queue one
    /// fake server per expected connect attempt.
    private func makeService(
        transport: FakeTransport,
        servers: [FakeLoopbackServer] = []
    ) throws -> GoogleAuthService {
        store = GoogleAccountStore(defaults: defaults, secretStore: InMemorySecretStore())
        store.clientID = "client-123"
        store.clientSecret = "secret-abc"
        try store.upsert(
            GoogleAccount(
                id: "sub-1",
                email: "ada@example.com",
                displayName: "Ada",
                grantedScopes: ["openid"],
                connectedAt: currentDate,
                statusRaw: GoogleAccountStatus.connected.rawValue
            ),
            refreshToken: "rt-1"
        )
        let flowExpected = !servers.isEmpty
        var pendingServers = servers
        return GoogleAuthService(
            store: store,
            transport: transport,
            now: { self.currentDate },
            openBrowser: { url in
                if flowExpected {
                    self.openedURLs.append(url)
                } else {
                    XCTFail("token tests must never open a browser")
                }
            },
            makeServer: { _ in
                guard !pendingServers.isEmpty else {
                    XCTFail("no fake loopback server queued for this connect attempt")
                    return FakeLoopbackServer()
                }
                return pendingServers.removeFirst()
            }
        )
    }

    /// The named query parameter of a URL.
    private func queryValue(_ name: String, of url: URL) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == name })?
            .value
    }

    /// An unsigned fixture ID token (payload-only trust, matching `decodeIDToken`).
    private func fixtureIDToken(sub: String, email: String, name: String) -> String {
        let header = Data(#"{"alg":"RS256","typ":"JWT"}"#.utf8).base64URLEncodedStringNoPadding()
        let payload = Data(#"{"sub":"\#(sub)","email":"\#(email)","name":"\#(name)"}"#.utf8)
            .base64URLEncodedStringNoPadding()
        return "\(header).\(payload).fixture-signature"
    }

    // MARK: - Refresh + cache

    func testRefreshesOnFirstCallThenServesFromCache() async throws {
        let transport = FakeTransport(responses: [
            .init(statusCode: 200, body: Self.tokenBody(accessToken: "at-1")),
        ])
        let service = try makeService(transport: transport)

        let first = try await service.accessToken(for: "sub-1")
        XCTAssertEqual(first, "at-1")
        XCTAssertEqual(transport.requests.count, 1)
        let body = String(data: transport.requests[0].httpBody ?? Data(), encoding: .utf8) ?? ""
        XCTAssertTrue(body.contains("grant_type=refresh_token"))
        XCTAssertTrue(body.contains("refresh_token=rt-1"))

        // Well before expiry: cache hit, no second network call.
        currentDate = currentDate.addingTimeInterval(1800)
        let second = try await service.accessToken(for: "sub-1")
        XCTAssertEqual(second, "at-1")
        XCTAssertEqual(transport.requests.count, 1)
    }

    func testRefreshesAgainInsideTheExpirySkew() async throws {
        let transport = FakeTransport(responses: [
            .init(statusCode: 200, body: Self.tokenBody(accessToken: "at-1", expiresIn: 3600)),
            .init(statusCode: 200, body: Self.tokenBody(accessToken: "at-2", expiresIn: 3600)),
        ])
        let service = try makeService(transport: transport)
        _ = try await service.accessToken(for: "sub-1")

        // 30 s of validity left — inside the 60 s skew, so the cached token must not be reused.
        currentDate = currentDate.addingTimeInterval(3600 - 30)
        let refreshed = try await service.accessToken(for: "sub-1")
        XCTAssertEqual(refreshed, "at-2")
        XCTAssertEqual(transport.requests.count, 2)
    }

    // MARK: - Single-flight

    func testConcurrentCallersShareOneRefresh() async throws {
        let transport = FakeTransport(
            responses: [.init(statusCode: 200, body: Self.tokenBody(accessToken: "at-1"))],
            delayNanoseconds: 50_000_000 // keep the refresh in flight while the second caller lands
        )
        let service = try makeService(transport: transport)

        async let first = service.accessToken(for: "sub-1")
        async let second = service.accessToken(for: "sub-1")
        let tokens = try await [first, second]

        XCTAssertEqual(tokens, ["at-1", "at-1"])
        XCTAssertEqual(transport.requests.count, 1, "second caller must await the in-flight refresh")
    }

    // MARK: - invalid_grant → needsReauth

    func testInvalidGrantFlipsAccountToNeedsReauthAndThrows() async throws {
        let transport = FakeTransport(responses: [
            .init(statusCode: 400, body: #"{"error": "invalid_grant", "error_description": "Token has been expired or revoked."}"#),
        ])
        let service = try makeService(transport: transport)

        do {
            _ = try await service.accessToken(for: "sub-1")
            XCTFail("expected needsReauth")
        } catch {
            XCTAssertEqual(error as? GoogleAuthError, .needsReauth)
        }
        XCTAssertEqual(store.accounts.first?.status, .needsReauth)
    }

    func testTransientRefreshFailureDoesNotFlipStatus() async throws {
        let transport = FakeTransport(responses: [
            .init(statusCode: 503, body: "upstream unavailable"),
        ])
        let service = try makeService(transport: transport)

        do {
            _ = try await service.accessToken(for: "sub-1")
            XCTFail("expected refreshFailed")
        } catch {
            XCTAssertEqual(error as? GoogleAuthError, .refreshFailed("HTTP 503"))
        }
        XCTAssertEqual(store.accounts.first?.status, .connected, "transient failures never demote the account")
    }

    func testMissingRefreshTokenThrowsNeedsReauthWithoutANetworkCall() async throws {
        // No stored token for this account (e.g. Keychain item swept externally): same remedy as a
        // rejected token — reconnect — and no pointless network round-trip.
        let transport = FakeTransport(responses: [])
        let service = try makeService(transport: transport)

        do {
            _ = try await service.accessToken(for: "ghost-sub")
            XCTFail("expected needsReauth")
        } catch {
            XCTAssertEqual(error as? GoogleAuthError, .needsReauth)
        }
        XCTAssertTrue(transport.requests.isEmpty, "no network call without a refresh token")
    }

    // MARK: - Connect-flow state machine (SR review)

    func testCancelMidWaitThrowsCancelledAndStopsListener() async throws {
        let server = FakeLoopbackServer()
        let service = try makeService(transport: FakeTransport(responses: []), servers: [server])

        let connect = Task { try await service.connectAccount() }
        // Let the flow run its synchronous prefix (server started, browser "opened").
        while openedURLs.isEmpty {
            await Task.yield()
        }
        service.cancelConnect()

        do {
            _ = try await connect.value
            XCTFail("expected cancelled")
        } catch {
            XCTAssertEqual(error as? GoogleAuthError, .cancelled)
        }
        XCTAssertTrue(server.stopped, "cancel must stop the loopback listener")
        XCTAssertFalse(service.isAuthorizing, "flag clears once the cancelled flow unwinds")
    }

    func testIsAuthorizingTracksFlowLifecycleAcrossRestart() async throws {
        // M2 review finding 1: the flow-active flag the settings UI renders must survive a
        // restart-while-pending — flow A's unwind may not clear it while flow B still waits.
        // Derived from `activeSession` identity, so it shares the restart test's guarantees.
        let serverA = FakeLoopbackServer()
        let serverB = FakeLoopbackServer()
        let idToken = fixtureIDToken(sub: "sub-9", email: "new@example.com", name: "New Account")
        let exchangeBody = """
        {"access_token": "at-9", "expires_in": 3600, "refresh_token": "rt-9", \
        "id_token": "\(idToken)", "scope": "openid email profile"}
        """
        let transport = FakeTransport(responses: [.init(statusCode: 200, body: exchangeBody)])
        let service = try makeService(transport: transport, servers: [serverA, serverB])
        XCTAssertFalse(service.isAuthorizing, "idle before any flow")

        let flowA = Task { try await service.connectAccount() }
        while openedURLs.count < 1 {
            await Task.yield()
        }
        XCTAssertTrue(service.isAuthorizing, "set while flow A awaits its redirect")

        let flowB = Task { try await service.connectAccount() }
        while openedURLs.count < 2 {
            await Task.yield()
        }
        _ = try? await flowA.value // flow A fully unwound (threw .cancelled)
        XCTAssertTrue(
            service.isAuthorizing,
            "flow A's unwind must not clear the flag while flow B is still waiting"
        )

        let stateB = try XCTUnwrap(queryValue("state", of: openedURLs[1]))
        serverB.onCallback(URL(string: "http://127.0.0.1:49152/?state=\(stateB)&code=code-b")!)
        _ = try await flowB.value
        XCTAssertFalse(service.isAuthorizing, "clears when the surviving flow completes")
    }

    // MARK: - Reauthorize identity check (PR #7 review finding 2)

    /// Exchange response for a flow that finishes as `sub`.
    private func exchangeBody(sub: String, email: String, name: String, refreshToken: String) -> String {
        let idToken = fixtureIDToken(sub: sub, email: email, name: name)
        return """
        {"access_token": "at-\(sub)", "expires_in": 3600, "refresh_token": "\(refreshToken)", \
        "id_token": "\(idToken)", "scope": "openid email profile"}
        """
    }

    /// Runs `flow`, waits until the browser URL for attempt `index` was opened, and delivers the
    /// matching redirect through `server`.
    private func deliverRedirect(to server: FakeLoopbackServer, attempt index: Int) async throws {
        while openedURLs.count <= index {
            await Task.yield()
        }
        let state = try XCTUnwrap(queryValue("state", of: openedURLs[index]))
        server.onCallback(URL(string: "http://127.0.0.1:49152/?state=\(state)&code=code-\(index)")!)
    }

    func testReauthorizeAsTheSameAccountSucceedsAndRefreshesIt() async throws {
        let server = FakeLoopbackServer()
        let transport = FakeTransport(responses: [
            .init(
                statusCode: 200,
                body: exchangeBody(sub: "sub-1", email: "ada@example.com", name: "Ada", refreshToken: "rt-1b")
            ),
        ])
        let service = try makeService(transport: transport, servers: [server])
        store.setStatus(.needsReauth, for: "sub-1")

        let flow = Task { try await service.reauthorize(accountID: "sub-1", additionalScopes: []) }
        try await deliverRedirect(to: server, attempt: 0)
        try await flow.value

        XCTAssertEqual(store.accounts.map(\.id), ["sub-1"], "no extra row")
        XCTAssertEqual(store.accounts.first?.status, .connected, "the repaired account is healthy again")
        XCTAssertEqual(store.refreshToken(for: "sub-1"), "rt-1b", "fresh refresh token stored")
    }

    func testReauthorizeAsADifferentAccountThrowsAndRollsBackTheNewRow() async throws {
        let server = FakeLoopbackServer()
        let transport = FakeTransport(responses: [
            .init(
                statusCode: 200,
                body: exchangeBody(sub: "sub-9", email: "grace@example.com", name: "Grace", refreshToken: "rt-9")
            ),
        ])
        let service = try makeService(transport: transport, servers: [server])
        store.setStatus(.needsReauth, for: "sub-1")

        let flow = Task { try await service.reauthorize(accountID: "sub-1", additionalScopes: []) }
        try await deliverRedirect(to: server, attempt: 0)

        do {
            try await flow.value
            XCTFail("expected wrongAccount")
        } catch {
            XCTAssertEqual(
                error as? GoogleAuthError,
                .wrongAccount(expectedEmail: "ada@example.com", signedInEmail: "grace@example.com")
            )
        }
        XCTAssertEqual(store.accounts.map(\.id), ["sub-1"], "the repair flow must not leave a new account behind")
        XCTAssertNil(store.refreshToken(for: "sub-9"), "the rolled-back row's Keychain entry is swept")
        XCTAssertEqual(store.accounts.first?.status, .needsReauth, "the requested account still needs reconnecting")
    }

    func testReauthorizeAsAnAlreadyConnectedSiblingThrowsWithoutRemovingIt() async throws {
        let server = FakeLoopbackServer()
        let transport = FakeTransport(responses: [
            .init(
                statusCode: 200,
                body: exchangeBody(sub: "sub-2", email: "bob@example.com", name: "Bob", refreshToken: "rt-2b")
            ),
        ])
        let service = try makeService(transport: transport, servers: [server])
        try store.upsert(
            GoogleAccount(
                id: "sub-2",
                email: "bob@example.com",
                displayName: "Bob",
                grantedScopes: ["openid"],
                connectedAt: currentDate,
                statusRaw: GoogleAccountStatus.connected.rawValue
            ),
            refreshToken: "rt-2"
        )
        store.setStatus(.needsReauth, for: "sub-1")

        let flow = Task { try await service.reauthorize(accountID: "sub-1", additionalScopes: []) }
        try await deliverRedirect(to: server, attempt: 0)

        do {
            try await flow.value
            XCTFail("expected wrongAccount")
        } catch {
            XCTAssertEqual(
                error as? GoogleAuthError,
                .wrongAccount(expectedEmail: "ada@example.com", signedInEmail: "bob@example.com")
            )
        }
        XCTAssertEqual(store.accounts.map(\.id).sorted(), ["sub-1", "sub-2"], "a pre-existing sibling is never removed")
        XCTAssertEqual(store.refreshToken(for: "sub-2"), "rt-2b", "the sibling keeps the token the flow just issued")
    }

    func testConnectAccountStillAcceptsAnyIdentity() async throws {
        // The identity check belongs to `reauthorize` only — adding a *new* account has no
        // expected `sub`.
        let server = FakeLoopbackServer()
        let transport = FakeTransport(responses: [
            .init(
                statusCode: 200,
                body: exchangeBody(sub: "sub-9", email: "new@example.com", name: "New", refreshToken: "rt-9")
            ),
        ])
        let service = try makeService(transport: transport, servers: [server])

        let flow = Task { try await service.connectAccount() }
        try await deliverRedirect(to: server, attempt: 0)
        let account = try await flow.value

        XCTAssertEqual(account.id, "sub-9")
        XCTAssertEqual(store.accounts.map(\.id).sorted(), ["sub-1", "sub-9"])
    }

    func testRestartWhilePendingCancelsOldFlowAndNewFlowStillCompletes() async throws {
        // The finding-1 scenario: flow B starts while flow A is awaiting its redirect. A must
        // throw `.cancelled`; B's session (server, timeout, continuation) must survive A's unwind
        // and complete when B's callback arrives.
        let serverA = FakeLoopbackServer()
        let serverB = FakeLoopbackServer()
        let idToken = fixtureIDToken(sub: "sub-9", email: "new@example.com", name: "New Account")
        let exchangeBody = """
        {"access_token": "at-9", "expires_in": 3600, "refresh_token": "rt-9", \
        "id_token": "\(idToken)", "scope": "openid email profile"}
        """
        let transport = FakeTransport(responses: [.init(statusCode: 200, body: exchangeBody)])
        let service = try makeService(transport: transport, servers: [serverA, serverB])

        let flowA = Task { try await service.connectAccount() }
        while openedURLs.count < 1 {
            await Task.yield()
        }
        let flowB = Task { try await service.connectAccount() }
        while openedURLs.count < 2 {
            await Task.yield()
        }

        do {
            _ = try await flowA.value
            XCTFail("flow A should have been cancelled by the restart")
        } catch {
            XCTAssertEqual(error as? GoogleAuthError, .cancelled)
        }
        XCTAssertTrue(serverA.stopped, "restart must stop the stale flow's listener")

        // Deliver B's redirect directly, echoing the state from the URL B opened.
        let stateB = try XCTUnwrap(queryValue("state", of: openedURLs[1]))
        serverB.onCallback(URL(string: "http://127.0.0.1:49152/?state=\(stateB)&code=code-b")!)

        let account = try await flowB.value
        XCTAssertEqual(account.id, "sub-9")
        XCTAssertEqual(account.email, "new@example.com")
        XCTAssertEqual(store.refreshToken(for: "sub-9"), "rt-9")
        XCTAssertEqual(transport.requests.count, 1, "exactly one exchange — flow B's")
    }
}
