import XCTest
@testable import TypeWhisper

/// Pure tests over the D-G2 request/response helpers — no fakes needed (§7).
final class GoogleOAuthFlowTests: XCTestCase {
    // MARK: - PKCE

    func testPKCEChallengeMatchesRFC7636Vector() {
        // Appendix B of RFC 7636: the canonical S256 verifier/challenge pair.
        let challenge = GoogleOAuthFlow.GooglePKCE.challenge(
            for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        )
        XCTAssertEqual(challenge, "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    func testGeneratedPKCEIsWellFormed() {
        let pkce = GoogleOAuthFlow.GooglePKCE.generate()
        XCTAssertEqual(pkce.verifier.count, 64)
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        XCTAssertTrue(pkce.verifier.unicodeScalars.allSatisfy { allowed.contains($0) })
        XCTAssertEqual(pkce.challenge, GoogleOAuthFlow.GooglePKCE.challenge(for: pkce.verifier))
        XCTAssertFalse(pkce.challenge.contains("="), "challenge must be base64url without padding")
        // Two generations never collide (random verifier).
        XCTAssertNotEqual(pkce.verifier, GoogleOAuthFlow.GooglePKCE.generate().verifier)
    }

    // MARK: - Authorization URL

    private func queryItems(of url: URL) -> [String: String] {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
    }

    func testAuthorizationURLCarriesTheDG2ParameterSet() {
        let url = GoogleOAuthFlow.authorizationURL(
            clientID: "client-123",
            redirectURI: "http://127.0.0.1:49152",
            scopes: ["openid", "email", "profile", GoogleAuthService.calendarScope],
            state: "state-abc",
            challenge: "challenge-xyz"
        )

        XCTAssertEqual(url.host, "accounts.google.com")
        XCTAssertEqual(url.path, "/o/oauth2/v2/auth")
        let query = queryItems(of: url)
        XCTAssertEqual(query["client_id"], "client-123")
        XCTAssertEqual(query["redirect_uri"], "http://127.0.0.1:49152")
        XCTAssertEqual(query["response_type"], "code")
        XCTAssertEqual(
            query["scope"],
            "openid email profile https://www.googleapis.com/auth/calendar.readonly"
        )
        XCTAssertEqual(query["code_challenge"], "challenge-xyz")
        XCTAssertEqual(query["code_challenge_method"], "S256")
        XCTAssertEqual(query["state"], "state-abc")
        XCTAssertEqual(query["access_type"], "offline")
        XCTAssertEqual(query["prompt"], "select_account consent")
        XCTAssertEqual(query["include_granted_scopes"], "true")
        XCTAssertNil(query["login_hint"], "no login_hint unless requested")
    }

    func testAuthorizationURLIncludesLoginHintWhenProvided() {
        let url = GoogleOAuthFlow.authorizationURL(
            clientID: "client-123",
            redirectURI: "http://127.0.0.1:49152",
            scopes: ["openid"],
            state: "s",
            challenge: "c",
            loginHint: "ada@example.com"
        )
        XCTAssertEqual(queryItems(of: url)["login_hint"], "ada@example.com")
    }

    // MARK: - Callback parsing

    func testParseCallbackExtractsCode() throws {
        let url = URL(string: "http://127.0.0.1:49152/?state=s1&code=auth-code-42&scope=openid")!
        XCTAssertEqual(try GoogleOAuthFlow.parseCallback(url, expectedState: "s1"), "auth-code-42")
    }

    func testParseCallbackRejectsStateMismatch() {
        let url = URL(string: "http://127.0.0.1:49152/?state=other&code=auth-code-42")!
        XCTAssertThrowsError(try GoogleOAuthFlow.parseCallback(url, expectedState: "s1")) { error in
            XCTAssertEqual(error as? GoogleAuthError, .stateMismatch)
        }
    }

    func testParseCallbackMapsAccessDeniedToCancelled() {
        let url = URL(string: "http://127.0.0.1:49152/?state=s1&error=access_denied")!
        XCTAssertThrowsError(try GoogleOAuthFlow.parseCallback(url, expectedState: "s1")) { error in
            XCTAssertEqual(error as? GoogleAuthError, .cancelled)
        }
    }

    func testParseCallbackSurfacesOtherErrorsAndMissingCode() {
        let serverError = URL(string: "http://127.0.0.1:49152/?state=s1&error=server_error")!
        XCTAssertThrowsError(try GoogleOAuthFlow.parseCallback(serverError, expectedState: "s1")) { error in
            XCTAssertEqual(error as? GoogleAuthError, .exchangeFailed("server_error"))
        }
        let noCode = URL(string: "http://127.0.0.1:49152/?state=s1")!
        XCTAssertThrowsError(try GoogleOAuthFlow.parseCallback(noCode, expectedState: "s1")) { error in
            XCTAssertEqual(error as? GoogleAuthError, .exchangeFailed("missing authorization code"))
        }
    }

    // MARK: - Token response decoding

    func testTokenResponseDecoding() throws {
        let json = """
        {
          "access_token": "at-1",
          "expires_in": 3599,
          "refresh_token": "rt-1",
          "id_token": "header.payload.sig",
          "scope": "openid email https://www.googleapis.com/auth/calendar.readonly",
          "token_type": "Bearer"
        }
        """
        let response = try JSONDecoder().decode(
            GoogleOAuthFlow.GoogleTokenResponse.self, from: Data(json.utf8)
        )
        XCTAssertEqual(response.accessToken, "at-1")
        XCTAssertEqual(response.expiresIn, 3599)
        XCTAssertEqual(response.refreshToken, "rt-1")
        XCTAssertEqual(response.idToken, "header.payload.sig")
        XCTAssertEqual(response.scope, "openid email https://www.googleapis.com/auth/calendar.readonly")
    }

    func testTokenResponseDecodingWithoutOptionalFields() throws {
        // Refresh responses omit refresh_token/id_token.
        let json = #"{"access_token": "at-2", "expires_in": 3600}"#
        let response = try JSONDecoder().decode(
            GoogleOAuthFlow.GoogleTokenResponse.self, from: Data(json.utf8)
        )
        XCTAssertEqual(response.accessToken, "at-2")
        XCTAssertNil(response.refreshToken)
        XCTAssertNil(response.idToken)
        XCTAssertNil(response.scope)
    }

    // MARK: - ID token decoding

    /// Assembles an unsigned fixture JWT whose payload is the given JSON object.
    private func fixtureJWT(payload: [String: Any]) -> String {
        let header = Data(#"{"alg":"RS256","typ":"JWT"}"#.utf8).base64URLEncodedStringNoPadding()
        let body = try! JSONSerialization.data(withJSONObject: payload)
            .base64URLEncodedStringNoPadding()
        return "\(header).\(body).fixture-signature"
    }

    func testDecodeIDTokenReadsSubEmailAndName() throws {
        let jwt = fixtureJWT(payload: [
            "sub": "100200300",
            "email": "ada@example.com",
            "name": "Ada Lovelace",
            "aud": "client-123",
        ])
        let claims = try GoogleOAuthFlow.decodeIDToken(jwt)
        XCTAssertEqual(claims.sub, "100200300")
        XCTAssertEqual(claims.email, "ada@example.com")
        XCTAssertEqual(claims.name, "Ada Lovelace")
    }

    func testDecodeIDTokenToleratesMissingName() throws {
        let jwt = fixtureJWT(payload: ["sub": "1", "email": "a@b.c"])
        let claims = try GoogleOAuthFlow.decodeIDToken(jwt)
        XCTAssertNil(claims.name)
    }

    func testDecodeIDTokenRejectsMalformedJWT() {
        XCTAssertThrowsError(try GoogleOAuthFlow.decodeIDToken("not-a-jwt"))
        XCTAssertThrowsError(try GoogleOAuthFlow.decodeIDToken("a.!!!not-base64url!!!.c"))
    }
}
