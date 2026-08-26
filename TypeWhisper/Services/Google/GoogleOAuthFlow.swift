import Foundation
import CryptoKit

/// Pure helpers for the Google OAuth 2.0 desktop-app flow (D-G2): PKCE material, the
/// authorization-request URL, loopback-callback parsing, and token/ID-token decoding. Everything
/// here is static and side-effect free so the whole request/response surface is unit-testable
/// without a network or a browser (`GoogleOAuthFlowTests`); `GoogleAuthService` owns the
/// stateful orchestration around these.
enum GoogleOAuthFlow {
    /// Google's OAuth endpoints. The authorization endpoint opens in the user's browser; the token
    /// and revoke endpoints are called directly (via `GoogleHTTPTransport`).
    static let authorizationEndpoint = URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!
    static let tokenEndpoint = URL(string: "https://oauth2.googleapis.com/token")!
    static let revokeEndpoint = URL(string: "https://oauth2.googleapis.com/revoke")!

    // MARK: - PKCE

    /// A PKCE verifier/challenge pair (RFC 7636, S256). PKCE is mandatory for the desktop flow —
    /// the pasted client secret is anti-typo, not the security boundary (D-G2).
    struct GooglePKCE: Sendable {
        let verifier: String
        let challenge: String

        /// A fresh random 64-char verifier (within the RFC's 43–128 range) and its S256 challenge.
        static func generate() -> GooglePKCE {
            let charset = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
            let verifier = String((0..<64).map { _ in charset.randomElement()! })
            return GooglePKCE(verifier: verifier, challenge: challenge(for: verifier))
        }

        /// S256: base64url(SHA256(verifier)), no padding. Split out from `generate()` so the RFC
        /// test vector is assertable.
        static func challenge(for verifier: String) -> String {
            let digest = Data(SHA256.hash(data: Data(verifier.utf8)))
            return digest.base64URLEncodedStringNoPadding()
        }
    }

    /// A fresh `state` value: 32 random bytes, base64url — echoed back by Google and verified in
    /// `parseCallback` to bind the callback to the request that opened the browser.
    static func generateState() -> String {
        Data((0..<32).map { _ in UInt8.random(in: .min ... .max) }).base64URLEncodedStringNoPadding()
    }

    // MARK: - Authorization request

    /// Assembles the D-G2 authorization URL. `prompt=select_account consent` guarantees an account
    /// chooser (adding a second account never silently reuses the browser session) and a refresh
    /// token even on re-connect; `include_granted_scopes=true` is the incremental-scope hook
    /// Phases 2–3 rely on. `loginHint` pre-selects the account for scope-widening re-auth (§9).
    static func authorizationURL(
        clientID: String,
        redirectURI: String,
        scopes: [String],
        state: String,
        challenge: String,
        loginHint: String? = nil
    ) -> URL {
        var components = URLComponents(url: authorizationEndpoint, resolvingAgainstBaseURL: false)!
        var items = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: scopes.joined(separator: " ")),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "select_account consent"),
            URLQueryItem(name: "include_granted_scopes", value: "true"),
        ]
        if let loginHint {
            items.append(URLQueryItem(name: "login_hint", value: loginHint))
        }
        components.queryItems = items
        return components.url!
    }

    // MARK: - Callback parsing

    /// Extracts the authorization code from the loopback redirect. The `state` echo must match the
    /// value sent with the authorization request; a user denying consent surfaces as
    /// `error=access_denied` (mapped to `.cancelled`).
    static func parseCallback(_ url: URL, expectedState: String) throws -> String {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? {
            items.first(where: { $0.name == name })?.value
        }
        guard value("state") == expectedState else {
            throw GoogleAuthError.stateMismatch
        }
        if let error = value("error") {
            if error == "access_denied" {
                throw GoogleAuthError.cancelled
            }
            throw GoogleAuthError.exchangeFailed(error)
        }
        guard let code = value("code"), !code.isEmpty else {
            throw GoogleAuthError.exchangeFailed("missing authorization code")
        }
        return code
    }

    // MARK: - Token endpoint payloads

    /// The token-endpoint response (authorization-code exchange and refresh both use this shape;
    /// `refreshToken`/`idToken` are absent on refresh responses).
    struct GoogleTokenResponse: Decodable, Sendable {
        let accessToken: String
        let expiresIn: Int
        let refreshToken: String?
        let idToken: String?
        let scope: String?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case expiresIn = "expires_in"
            case refreshToken = "refresh_token"
            case idToken = "id_token"
            case scope
        }
    }

    /// Form-encoded body for the authorization-code exchange (D-G2). The client secret is required
    /// by Google for Desktop clients even though it is not treated as confidential.
    static func tokenExchangeRequest(
        code: String,
        clientID: String,
        clientSecret: String,
        redirectURI: String,
        codeVerifier: String
    ) -> URLRequest {
        formPOST(to: tokenEndpoint, fields: [
            ("code", code),
            ("client_id", clientID),
            ("client_secret", clientSecret),
            ("redirect_uri", redirectURI),
            ("grant_type", "authorization_code"),
            ("code_verifier", codeVerifier),
        ])
    }

    /// Form-encoded body for an access-token refresh.
    static func tokenRefreshRequest(
        refreshToken: String,
        clientID: String,
        clientSecret: String
    ) -> URLRequest {
        formPOST(to: tokenEndpoint, fields: [
            ("refresh_token", refreshToken),
            ("client_id", clientID),
            ("client_secret", clientSecret),
            ("grant_type", "refresh_token"),
        ])
    }

    /// Best-effort revocation of a refresh token on disconnect (D-G2): token as a query parameter,
    /// empty POST body.
    static func revokeRequest(token: String) -> URLRequest {
        var components = URLComponents(url: revokeEndpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "token", value: token)]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        return request
    }

    // MARK: - ID token

    /// The claims Phase 1 reads from the ID token: `sub` is the stable account key (D-G3/D-G5),
    /// `email`/`name` feed the settings row.
    struct GoogleIDTokenClaims: Decodable, Sendable {
        let sub: String
        let email: String
        let name: String?
    }

    /// Decodes the ID-token JWT's payload segment. No signature verification — the token arrives
    /// directly from Google's token endpoint over TLS (D-G2), so the transport is the trust anchor.
    static func decodeIDToken(_ jwt: String) throws -> GoogleIDTokenClaims {
        let segments = jwt.split(separator: ".")
        guard segments.count == 3, let payload = Data(base64URLEncoded: String(segments[1])) else {
            throw GoogleAuthError.exchangeFailed("malformed id_token")
        }
        do {
            return try JSONDecoder().decode(GoogleIDTokenClaims.self, from: payload)
        } catch {
            throw GoogleAuthError.exchangeFailed("undecodable id_token payload")
        }
    }

    // MARK: - Private

    private static func formPOST(to url: URL, fields: [(String, String)]) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let body = fields
            .map { name, value in
                let encoded = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
                return "\(name)=\(encoded)"
            }
            .joined(separator: "&")
        request.httpBody = Data(body.utf8)
        return request
    }
}

// MARK: - base64url

extension Data {
    /// base64url without padding (RFC 4648 §5) — the encoding PKCE challenges and `state` use.
    func base64URLEncodedStringNoPadding() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Decodes base64url with or without padding (JWT segments come unpadded).
    init?(base64URLEncoded string: String) {
        var base64 = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 {
            base64.append("=")
        }
        self.init(base64Encoded: base64)
    }
}
