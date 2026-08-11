import Foundation
import AppKit
import Combine
import os.log

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "TypeWhisper", category: "GoogleAuthService")

/// Errors surfaced by the Google OAuth flow and token management (D-G2). `Equatable` so tests can
/// assert the exact failure; descriptions are debug-facing (M1 ships no UI strings — M2 localizes
/// what it surfaces).
enum GoogleAuthError: LocalizedError, Equatable {
    /// No OAuth client ID/secret pasted in settings yet.
    case notConfigured
    /// The user cancelled — either denied consent in the browser (`error=access_denied`) or hit
    /// the cancel affordance while waiting for the redirect.
    case cancelled
    /// The loopback listener gave up waiting for the redirect (5-minute window, D-G2).
    case timedOut
    /// The callback's `state` echo did not match the value sent with the authorization request.
    case stateMismatch
    /// The authorization-code exchange (or callback/ID-token parsing around it) failed.
    case exchangeFailed(String)
    /// An access-token refresh failed for a transient/unknown reason (network, 5xx).
    case refreshFailed(String)
    /// The refresh token was rejected (`invalid_grant`) — revoked or expired; the account is
    /// flipped to `.needsReauth` and must be reconnected.
    case needsReauth

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            "Google OAuth client is not configured"
        case .cancelled:
            "Google sign-in was cancelled"
        case .timedOut:
            "Timed out waiting for the Google sign-in redirect"
        case .stateMismatch:
            "OAuth state mismatch in the sign-in redirect"
        case .exchangeFailed(let detail):
            "Google token exchange failed: \(detail)"
        case .refreshFailed(let detail):
            "Google token refresh failed: \(detail)"
        case .needsReauth:
            "Google account needs to be reconnected"
        }
    }
}

/// Runs the D-G2 OAuth flow end to end (loopback server + browser + PKCE + token exchange) and
/// manages access tokens for connected accounts: in-memory cache, on-demand refresh with a 60 s
/// expiry skew, single-flight per account, and `invalid_grant` → `.needsReauth` surfacing.
/// Access tokens are never persisted (D-G5); durable state lives in the injected
/// `GoogleAccountStore`. `accessToken(for:)` is the one seam later phases and the calendar sync
/// engine (M3, `GoogleAccessTokenProviding`) consume — Google access tokens carry the union of
/// granted scopes, so the seam stays scope-agnostic (§9).
@MainActor
final class GoogleAuthService: ObservableObject {
    /// Phase 1's data scope. Later phases pass their scopes through
    /// `reauthorize(accountID:additionalScopes:)` instead of adding constants here (§9).
    nonisolated static let calendarScope = "https://www.googleapis.com/auth/calendar.readonly"
    /// Always requested: `openid` yields the ID token (`sub` account key), `email`/`profile` the
    /// settings-row identity.
    nonisolated static let identityScopes = ["openid", "email", "profile"]
    /// How long the loopback server waits for the browser redirect before giving up (D-G2).
    nonisolated static let connectTimeout: TimeInterval = 5 * 60

    private struct CachedToken: Sendable {
        let token: String
        let expiresAt: Date
    }

    /// An in-flight refresh paired with a generation id, so cleanup only evicts the exact entry it
    /// created — an unconditional eviction could drop a *successor's* in-flight task after a
    /// disconnect/reconnect race and break single-flight (SR review).
    private struct RefreshEntry {
        let id: UUID
        let task: Task<CachedToken, Error>
    }

    /// Everything one authorization flow owns (SR review): the flow's `defer` tears down only its
    /// own session and clears `activeSession` only while it still points at this session, so a
    /// restarted connect can never clobber the successor flow's server, timeout task, or parked
    /// continuation.
    @MainActor
    private final class ConnectSession {
        let server: any GoogleLoopbackServing
        var continuation: CheckedContinuation<URL, Error>?
        /// Callback that raced in before the continuation was parked (redirects can be fast).
        var bufferedCallbackURL: URL?
        var timeoutTask: Task<Void, Never>?
        /// Failure recorded before the continuation was parked (cancel/timeout/restart racing the
        /// flow's synchronous prefix) — a late park resumes with it immediately instead of hanging.
        var failedError: GoogleAuthError?

        init(server: any GoogleLoopbackServing) {
            self.server = server
        }
    }

    private let store: GoogleAccountStore
    private let transport: GoogleHTTPTransport
    /// Injected clock so expiry-skew tests are time-deterministic (§7).
    private let now: () -> Date
    /// Injected browser seam (`NSWorkspace.shared.open` in production).
    private let openBrowser: (URL) -> Void
    /// Injected listener factory (real `GoogleLoopbackServer` in production). Receives the flow's
    /// `state` so the server only treats the matching redirect as the callback (SR review).
    private let makeServer: (String) -> any GoogleLoopbackServing
    /// Refresh when the cached token expires within this window, so a token handed out is never
    /// on the verge of dying mid-request (D-G2).
    private let refreshSkew: TimeInterval = 60

    /// In-memory only — never persisted (D-G5).
    private var tokenCache: [String: CachedToken] = [:]
    /// Single-flight refresh per account: a second caller awaits the in-flight task instead of
    /// issuing a second network call (D-G2).
    private var refreshTasks: [String: RefreshEntry] = [:]

    /// The authorization flow currently awaiting its redirect, if any (one at a time; a new
    /// connect cancels a stale one).
    private var activeSession: ConnectSession?

    init(
        store: GoogleAccountStore,
        transport: GoogleHTTPTransport = URLSessionGoogleTransport(),
        now: @escaping () -> Date = Date.init,
        openBrowser: @escaping (URL) -> Void = { NSWorkspace.shared.open($0) },
        makeServer: @escaping (String) -> any GoogleLoopbackServing = { GoogleLoopbackServer(expectedState: $0) }
    ) {
        self.store = store
        self.transport = transport
        self.now = now
        self.openBrowser = openBrowser
        self.makeServer = makeServer
    }

    // MARK: - Connect / reauthorize

    /// Runs the full D-G2 flow for a new (or re-added) account: ephemeral loopback port, browser
    /// authorization with PKCE, code exchange, ID-token identity, then `store.upsert` (deduped by
    /// `sub`, so re-adding an account updates it in place).
    func connectAccount() async throws -> GoogleAccount {
        try await runAuthorizationFlow(
            scopes: Self.identityScopes + [Self.calendarScope],
            loginHint: nil
        )
    }

    /// Re-runs the flow for an existing account to widen its grant (`include_granted_scopes=true`
    /// makes Google merge scopes server-side). Used by "Reconnect" on `.needsReauth` (empty
    /// `additionalScopes`) and by Phases 2–3 to add Drive/Gmail scopes (§9).
    func reauthorize(accountID: String, additionalScopes: [String]) async throws {
        var scopes = Self.identityScopes + [Self.calendarScope]
        for scope in additionalScopes where !scopes.contains(scope) {
            scopes.append(scope)
        }
        _ = try await runAuthorizationFlow(
            scopes: scopes,
            loginHint: store.account(id: accountID)?.email
        )
    }

    /// Cancels a connect flow in progress: stops the loopback listener and fails the pending wait
    /// with `.cancelled`. The M2 settings row's cancel affordance calls this (D-G2).
    func cancelConnect() {
        if let session = activeSession {
            fail(session, with: .cancelled)
        }
    }

    /// Best-effort revocation (D-G2): the revoke call may fail (offline, already revoked) — the
    /// account is removed from the index and its Keychain prefix swept regardless.
    ///
    /// Note for consumers (M3+): cancelling the in-flight refresh here surfaces a plain
    /// `CancellationError` — not a `GoogleAuthError` — to any concurrent `accessToken(for:)`
    /// awaiter. The error taxonomy is not closed; treat unknown errors as transient.
    func disconnect(accountID: String) async {
        if let refreshToken = store.refreshToken(for: accountID) {
            let request = GoogleOAuthFlow.revokeRequest(token: refreshToken)
            _ = try? await transport.send(request)
        }
        refreshTasks[accountID]?.task.cancel()
        refreshTasks[accountID] = nil
        tokenCache[accountID] = nil
        store.remove(accountID: accountID)
    }

    // MARK: - Access tokens

    /// A valid access token for the account, refreshing on demand: cache hit unless the token is
    /// missing or expires within the 60 s skew; concurrent callers share one refresh
    /// (single-flight). `invalid_grant` flips the account to `.needsReauth` and throws
    /// `.needsReauth` (D-G2).
    ///
    /// Errors are not limited to `GoogleAuthError`: a disconnect racing this call surfaces
    /// `CancellationError`, and the transport can throw `URLError`. Consumers (M3's sync engine)
    /// should special-case `.needsReauth` and treat anything unknown as transient.
    func accessToken(for accountID: String) async throws -> String {
        if let cached = tokenCache[accountID],
           cached.expiresAt > now().addingTimeInterval(refreshSkew) {
            return cached.token
        }
        if let inFlight = refreshTasks[accountID] {
            return try await inFlight.task.value.token
        }
        let task = Task { [weak self] () throws -> CachedToken in
            guard let self else { throw GoogleAuthError.refreshFailed("service deallocated") }
            return try await self.refreshAccessToken(for: accountID)
        }
        let entry = RefreshEntry(id: UUID(), task: task)
        refreshTasks[accountID] = entry
        // Generation-matched cleanup (SR review): a disconnect/reconnect may already have replaced
        // this entry — evict only our own so a successor's in-flight refresh keeps single-flight.
        defer {
            if refreshTasks[accountID]?.id == entry.id {
                refreshTasks[accountID] = nil
            }
        }
        do {
            let refreshed = try await task.value
            tokenCache[accountID] = refreshed
            return refreshed.token
        } catch {
            tokenCache[accountID] = nil
            throw error
        }
    }

    private func refreshAccessToken(for accountID: String) async throws -> CachedToken {
        guard let clientID = store.clientID, let clientSecret = store.clientSecret else {
            throw GoogleAuthError.notConfigured
        }
        guard let refreshToken = store.refreshToken(for: accountID) else {
            // An indexed account without a stored token cannot recover silently — same remedy as
            // a rejected token: reconnect.
            store.setStatus(.needsReauth, for: accountID)
            throw GoogleAuthError.needsReauth
        }
        let request = GoogleOAuthFlow.tokenRefreshRequest(
            refreshToken: refreshToken,
            clientID: clientID,
            clientSecret: clientSecret
        )
        let (data, response) = try await transport.send(request)
        guard response.statusCode == 200 else {
            if Self.oauthErrorCode(in: data) == "invalid_grant" {
                // Revoked or expired refresh token (also the weekly symptom of a consent screen
                // left in Testing mode — Appendix A).
                logger.warning("Refresh token rejected (invalid_grant) for account \(accountID, privacy: .private)")
                store.setStatus(.needsReauth, for: accountID)
                throw GoogleAuthError.needsReauth
            }
            throw GoogleAuthError.refreshFailed("HTTP \(response.statusCode)")
        }
        let tokens = try Self.decodeTokenResponse(data, failure: GoogleAuthError.refreshFailed("undecodable token response"))
        return CachedToken(token: tokens.accessToken, expiresAt: now().addingTimeInterval(TimeInterval(tokens.expiresIn)))
    }

    // MARK: - Flow orchestration

    private func runAuthorizationFlow(scopes: [String], loginHint: String?) async throws -> GoogleAccount {
        guard let clientID = store.clientID, let clientSecret = store.clientSecret else {
            throw GoogleAuthError.notConfigured
        }
        // One flow at a time — a stale flow left waiting (browser tab abandoned) is cancelled so
        // its listener frees up before the new one starts. Failing it only touches the *stale*
        // session object; this flow's state below is untouchable by the old flow's unwind.
        if let stale = activeSession {
            fail(stale, with: .cancelled)
        }

        let pkce = GoogleOAuthFlow.GooglePKCE.generate()
        let state = GoogleOAuthFlow.generateState()

        let server = makeServer(state)
        let session = ConnectSession(server: server)
        server.onCallback = { [weak self] url in
            self?.deliver(url, to: session)
        }
        let port = try server.start()
        activeSession = session
        let redirectURI = "http://127.0.0.1:\(port)"

        let authorizationURL = GoogleOAuthFlow.authorizationURL(
            clientID: clientID,
            redirectURI: redirectURI,
            scopes: scopes,
            state: state,
            challenge: pkce.challenge,
            loginHint: loginHint
        )
        openBrowser(authorizationURL)

        session.timeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.connectTimeout * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.fail(session, with: .timedOut)
        }

        // Flow-scoped teardown (SR review): every mutation targets this flow's own session, and
        // `activeSession` is cleared only if it still points here — a restarted connect that
        // already installed a successor session is never clobbered by this unwind.
        defer {
            session.timeoutTask?.cancel()
            session.timeoutTask = nil
            server.stop()
            session.continuation = nil
            if activeSession === session {
                activeSession = nil
            }
        }

        let callbackURL: URL = try await withCheckedThrowingContinuation { continuation in
            if let failed = session.failedError {
                // Cancelled/timed out/restarted before the continuation could park.
                continuation.resume(throwing: failed)
            } else if let buffered = session.bufferedCallbackURL {
                session.bufferedCallbackURL = nil
                continuation.resume(returning: buffered)
            } else {
                session.continuation = continuation
            }
        }

        let code = try GoogleOAuthFlow.parseCallback(callbackURL, expectedState: state)
        return try await exchangeCodeAndStore(
            code: code,
            clientID: clientID,
            clientSecret: clientSecret,
            redirectURI: redirectURI,
            codeVerifier: pkce.verifier,
            requestedScopes: scopes
        )
    }

    private func exchangeCodeAndStore(
        code: String,
        clientID: String,
        clientSecret: String,
        redirectURI: String,
        codeVerifier: String,
        requestedScopes: [String]
    ) async throws -> GoogleAccount {
        let request = GoogleOAuthFlow.tokenExchangeRequest(
            code: code,
            clientID: clientID,
            clientSecret: clientSecret,
            redirectURI: redirectURI,
            codeVerifier: codeVerifier
        )
        let (data, response) = try await transport.send(request)
        guard response.statusCode == 200 else {
            let detail = Self.oauthErrorCode(in: data) ?? "HTTP \(response.statusCode)"
            throw GoogleAuthError.exchangeFailed(detail)
        }
        let tokens = try Self.decodeTokenResponse(data, failure: GoogleAuthError.exchangeFailed("undecodable token response"))
        guard let idToken = tokens.idToken else {
            throw GoogleAuthError.exchangeFailed("missing id_token")
        }
        guard let refreshToken = tokens.refreshToken else {
            // `prompt=consent` should guarantee one (D-G2); treat absence as a failed connect
            // rather than storing an account that can never refresh.
            throw GoogleAuthError.exchangeFailed("missing refresh_token")
        }
        let claims = try GoogleOAuthFlow.decodeIDToken(idToken)

        let grantedScopes = tokens.scope.map { $0.split(separator: " ").map(String.init) } ?? requestedScopes
        let account = GoogleAccount(
            id: claims.sub,
            email: claims.email,
            displayName: claims.name,
            grantedScopes: grantedScopes,
            connectedAt: now(),
            statusRaw: GoogleAccountStatus.connected.rawValue
        )
        do {
            // A Keychain save failure must fail the connect (SR review) — otherwise the UI would
            // report success for an account that can never refresh.
            try store.upsert(account, refreshToken: refreshToken)
        } catch {
            throw GoogleAuthError.exchangeFailed("failed to store refresh token in Keychain")
        }
        tokenCache[claims.sub] = CachedToken(
            token: tokens.accessToken,
            expiresAt: now().addingTimeInterval(TimeInterval(tokens.expiresIn))
        )
        logger.info("Connected Google account \(claims.sub, privacy: .private)")
        // Return the stored row (scope union on re-add happens inside `upsert`).
        return store.account(id: claims.sub) ?? account
    }

    // MARK: - Callback plumbing (session-scoped, SR review)

    /// Routes a redirect to the session whose server produced it — never to whatever flow happens
    /// to be active, so a stale server's late callback cannot feed a successor flow.
    private func deliver(_ url: URL, to session: ConnectSession) {
        if let continuation = session.continuation {
            session.continuation = nil
            continuation.resume(returning: url)
        } else if session.failedError == nil {
            session.bufferedCallbackURL = url
        }
    }

    /// Fails one specific session (cancel, timeout, restart). Resumes its parked continuation, or
    /// records the failure for a park still in flight; idempotent for an already-finished session.
    private func fail(_ session: ConnectSession, with error: GoogleAuthError) {
        session.server.stop()
        session.timeoutTask?.cancel()
        if let continuation = session.continuation {
            session.continuation = nil
            continuation.resume(throwing: error)
        } else if session.failedError == nil {
            session.failedError = error
        }
    }

    // MARK: - Response helpers

    private static func decodeTokenResponse(
        _ data: Data,
        failure: GoogleAuthError
    ) throws -> GoogleOAuthFlow.GoogleTokenResponse {
        do {
            return try JSONDecoder().decode(GoogleOAuthFlow.GoogleTokenResponse.self, from: data)
        } catch {
            throw failure
        }
    }

    /// The `error` code in an OAuth error body (`{"error": "invalid_grant", …}`), if any.
    private static func oauthErrorCode(in data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object["error"] as? String
    }
}
