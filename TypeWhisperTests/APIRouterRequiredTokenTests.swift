import XCTest
@testable import TypeWhisper

/// Routes registered with `requiresToken` demand the API token from every caller, including plain
/// loopback clients that are otherwise exempt while "Require API Token" is off. The presence
/// endpoints rely on this (docs/specs/2026-09-30-meeting-presence-api-proposal.md §6.1).
final class APIRouterRequiredTokenTests: XCTestCase {
    private let token = "secret-token"

    /// A router in the default configuration: loopback enforcement off (`apiTokenProvider` yields
    /// nil), with `currentToken` as the token the app actually holds.
    private func makeRouter(currentToken: String?) -> APIRouter {
        let router = APIRouter(
            apiTokenProvider: { nil },
            extensionOriginPolicy: { [currentToken] in
                APIRouter.ExtensionOriginPolicy(allowedOrigins: [], token: currentToken)
            }
        )
        let ok: APIHandler = { _ in HTTPResponse(status: 200, contentType: "text/plain", body: Data()) }
        router.register("GET", "/v1/open", handler: ok)
        router.register("GET", "/v1/guarded", requiresToken: true, handler: ok)
        router.register("GET", "/v1/guarded/{id}", requiresToken: true, handler: ok)
        return router
    }

    private func request(_ path: String, headers: [String: String] = [:]) -> HTTPRequest {
        HTTPRequest(method: "GET", path: path, queryParams: [:], headers: headers, body: Data())
    }

    func testOrdinaryRouteStaysOpenToLoopbackCallersWhenEnforcementIsOff() async {
        let response = await makeRouter(currentToken: token).route(request("/v1/open"))
        XCTAssertEqual(response.status, 200)
    }

    func testTokenRequiredRouteRejectsACallerWithoutTheToken() async {
        let router = makeRouter(currentToken: token)
        let missing = await router.route(request("/v1/guarded"))
        XCTAssertEqual(missing.status, 401)
        let wrong = await router.route(request("/v1/guarded", headers: ["authorization": "Bearer nope"]))
        XCTAssertEqual(wrong.status, 401)
    }

    func testTokenRequiredRouteAcceptsEitherTokenHeader() async {
        let router = makeRouter(currentToken: token)
        let bearer = await router.route(request("/v1/guarded", headers: ["authorization": "Bearer \(token)"]))
        XCTAssertEqual(bearer.status, 200)
        let header = await router.route(request("/v1/guarded", headers: ["x-typewhisper-api-token": token]))
        XCTAssertEqual(header.status, 200)
    }

    func testTokenRequiredPatternRouteIsGuardedToo() async {
        let router = makeRouter(currentToken: token)
        let missing = await router.route(request("/v1/guarded/abc"))
        XCTAssertEqual(missing.status, 401)
        let authorized = await router.route(request("/v1/guarded/abc", headers: ["authorization": "Bearer \(token)"]))
        XCTAssertEqual(authorized.status, 200)
    }

    func testTokenRequiredRouteDeniesEveryoneWhileNoTokenExists() async {
        let router = makeRouter(currentToken: nil)
        let response = await router.route(request("/v1/guarded", headers: ["authorization": "Bearer anything"]))
        XCTAssertEqual(response.status, 401)
    }
}
