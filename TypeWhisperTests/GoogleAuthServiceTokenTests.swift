import XCTest
@testable import TypeWhisper

/// `GoogleAuthService`'s token management over a fake transport, an in-memory secret store, and an
/// injected clock (§7): refresh on the 60 s expiry skew, single-flight per account, and
/// `invalid_grant` → `.needsReauth`. The browser/loopback connect path is exercised manually
/// (QA script §7), not here.
@MainActor
final class GoogleAuthServiceTokenTests: XCTestCase {
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

    override func setUp() {
        super.setUp()
        suiteName = "GoogleAuthServiceTokenTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        currentDate = Date(timeIntervalSince1970: 1_700_000_000)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    /// Builds the store (configured client + one connected account with a stored refresh token)
    /// and the service under test. MainActor helper rather than `setUp` — the store and service
    /// are MainActor-isolated, the inherited `setUp` override is not.
    private func makeService(transport: FakeTransport) -> GoogleAuthService {
        store = GoogleAccountStore(defaults: defaults, secretStore: InMemorySecretStore())
        store.clientID = "client-123"
        store.clientSecret = "secret-abc"
        store.upsert(
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
        return GoogleAuthService(
            store: store,
            transport: transport,
            now: { self.currentDate },
            openBrowser: { _ in XCTFail("token tests must never open a browser") }
        )
    }

    // MARK: - Refresh + cache

    func testRefreshesOnFirstCallThenServesFromCache() async throws {
        let transport = FakeTransport(responses: [
            .init(statusCode: 200, body: Self.tokenBody(accessToken: "at-1")),
        ])
        let service = makeService(transport: transport)

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
        let service = makeService(transport: transport)
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
        let service = makeService(transport: transport)

        async let first = service.accessToken(for: "sub-1")
        async let second = service.accessToken(for: "sub-1")
        let tokens = try await [first, second]

        XCTAssertEqual(tokens, ["at-1", "at-1"])
        XCTAssertEqual(transport.requests.count, 1, "second caller must await the in-flight refresh")
    }

    // MARK: - invalid_grant → needsReauth

    func testInvalidGrantFlipsAccountToNeedsReauthAndThrows() async {
        let transport = FakeTransport(responses: [
            .init(statusCode: 400, body: #"{"error": "invalid_grant", "error_description": "Token has been expired or revoked."}"#),
        ])
        let service = makeService(transport: transport)

        do {
            _ = try await service.accessToken(for: "sub-1")
            XCTFail("expected needsReauth")
        } catch {
            XCTAssertEqual(error as? GoogleAuthError, .needsReauth)
        }
        XCTAssertEqual(store.accounts.first?.status, .needsReauth)
    }

    func testTransientRefreshFailureDoesNotFlipStatus() async {
        let transport = FakeTransport(responses: [
            .init(statusCode: 503, body: "upstream unavailable"),
        ])
        let service = makeService(transport: transport)

        do {
            _ = try await service.accessToken(for: "sub-1")
            XCTFail("expected refreshFailed")
        } catch {
            XCTAssertEqual(error as? GoogleAuthError, .refreshFailed("HTTP 503"))
        }
        XCTAssertEqual(store.accounts.first?.status, .connected, "transient failures never demote the account")
    }

    func testMissingRefreshTokenThrowsNeedsReauthWithoutANetworkCall() async {
        // No stored token for this account (e.g. Keychain item swept externally): same remedy as a
        // rejected token — reconnect — and no pointless network round-trip.
        let transport = FakeTransport(responses: [])
        let service = makeService(transport: transport)

        do {
            _ = try await service.accessToken(for: "ghost-sub")
            XCTFail("expected needsReauth")
        } catch {
            XCTAssertEqual(error as? GoogleAuthError, .needsReauth)
        }
        XCTAssertTrue(transport.requests.isEmpty, "no network call without a refresh token")
    }
}
