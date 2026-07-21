import Foundation
import os

typealias APIHandler = @Sendable (HTTPRequest) async -> HTTPResponse

final class APIRouter: Sendable {
    private typealias RouteEntry = (method: String, path: String, handler: APIHandler)

    private let routes = OSAllocatedUnfairLock<[RouteEntry]>(initialState: [])
    private let apiTokenProvider: @Sendable () -> String?

    init(apiTokenProvider: @escaping @Sendable () -> String? = { nil }) {
        self.apiTokenProvider = apiTokenProvider
    }

    func register(_ method: String, _ path: String, handler: @escaping APIHandler) {
        routes.withLock { routes in
            routes.append((method: method.uppercased(), path: path, handler: handler))
        }
    }

    func route(_ request: HTTPRequest) async -> HTTPResponse {
        let cors = Self.corsHeaders(for: request)

        if request.method == "OPTIONS" {
            return HTTPResponse(status: 204, contentType: "text/plain", body: Data()).adding(headers: cors)
        }

        let registeredRoutes = routes.withLock { $0 }

        // Exact-path routes win over `{placeholder}` patterns, so a literal like
        // `/v1/meetings/import-transcript` is never shadowed by `/v1/meetings/{id}`.
        for route in registeredRoutes where !route.path.contains("{") {
            if route.method == request.method && route.path == request.path {
                guard isAuthorized(request) else { return Self.unauthorized.adding(headers: cors) }
                return await route.handler(request).adding(headers: cors)
            }
        }

        for route in registeredRoutes where route.path.contains("{") {
            guard route.method == request.method,
                  let pathParams = Self.matchPattern(route.path, path: request.path) else { continue }
            guard isAuthorized(request) else { return Self.unauthorized.adding(headers: cors) }
            let matched = HTTPRequest(
                method: request.method,
                path: request.path,
                queryParams: request.queryParams,
                headers: request.headers,
                body: request.body,
                pathParams: pathParams
            )
            return await route.handler(matched).adding(headers: cors)
        }

        return HTTPResponse
            .error(status: 404, message: "Not found: \(request.method) \(request.path)")
            .adding(headers: cors)
    }

    /// CORS headers for browser-extension callers (the Google Meet caption bridge).
    ///
    /// Deliberately **not** `Access-Control-Allow-Origin: *`. The API token is optional — when it is
    /// unset every route is authorized — so a wildcard would let any web page the user happens to
    /// have open drive the local API. A `chrome-extension://` origin cannot be forged by page
    /// JavaScript (the browser sets `Origin` itself), so echoing only those origins keeps ordinary
    /// web content locked out while letting the extension through. Anything else gets no CORS
    /// headers at all, which is what the browser needs to see in order to block the response.
    static func corsHeaders(for request: HTTPRequest) -> [String: String] {
        guard let origin = request.headers["origin"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              origin.hasPrefix("chrome-extension://") || origin.hasPrefix("moz-extension://") else {
            return [:]
        }
        return [
            "Access-Control-Allow-Origin": origin,
            "Access-Control-Allow-Methods": "GET, POST, PUT, DELETE, OPTIONS",
            "Access-Control-Allow-Headers": "Authorization, Content-Type, X-TypeWhisper-API-Token",
            "Access-Control-Max-Age": "600",
            "Vary": "Origin",
        ]
    }

    private static let unauthorized = HTTPResponse.error(
        status: 401,
        message: "Missing or invalid API token",
        headers: ["WWW-Authenticate": "Bearer"]
    )

    /// Match a registered pattern like `/v1/meetings/{id}` against a concrete request path,
    /// returning the captured placeholder values (`["id": "..."]`) or `nil` when it does not match.
    /// Segment counts must be equal; literal segments must match exactly; each `{name}` segment
    /// captures its (percent-decoded) value.
    static func matchPattern(_ pattern: String, path: String) -> [String: String]? {
        let patternSegments = pattern.split(separator: "/", omittingEmptySubsequences: false)
        let pathSegments = path.split(separator: "/", omittingEmptySubsequences: false)
        guard patternSegments.count == pathSegments.count else { return nil }

        var params: [String: String] = [:]
        for (patternSegment, pathSegment) in zip(patternSegments, pathSegments) {
            if patternSegment.hasPrefix("{") && patternSegment.hasSuffix("}") {
                let name = String(patternSegment.dropFirst().dropLast())
                let value = String(pathSegment)
                guard !value.isEmpty else { return nil }
                params[name] = value.removingPercentEncoding ?? value
            } else if patternSegment != pathSegment {
                return nil
            }
        }
        return params
    }

    private func isAuthorized(_ request: HTTPRequest) -> Bool {
        guard !isPublicRoute(request),
              let expectedToken = apiTokenProvider(),
              !expectedToken.isEmpty else {
            return true
        }

        guard let providedToken = request.bearerToken ?? request.apiTokenHeader else {
            return false
        }

        return Self.constantTimeEquals(providedToken, expectedToken)
    }

    private func isPublicRoute(_ request: HTTPRequest) -> Bool {
        request.method == "GET" && request.path == "/v1/status"
    }

    private static func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        let lhsBytes = Array(lhs.utf8)
        let rhsBytes = Array(rhs.utf8)
        var difference = lhsBytes.count ^ rhsBytes.count
        let maxCount = max(lhsBytes.count, rhsBytes.count)

        for index in 0..<maxCount {
            let lhsByte = index < lhsBytes.count ? lhsBytes[index] : 0
            let rhsByte = index < rhsBytes.count ? rhsBytes[index] : 0
            difference |= Int(lhsByte ^ rhsByte)
        }

        return difference == 0
    }
}

private extension HTTPRequest {
    var bearerToken: String? {
        guard let authorization = headers["authorization"]?.trimmingCharacters(in: .whitespacesAndNewlines) else {
            return nil
        }

        let prefix = "Bearer "
        guard authorization.regionMatches(prefix, options: .caseInsensitive) else {
            return nil
        }

        let token = authorization.dropFirst(prefix.count).trimmingCharacters(in: .whitespacesAndNewlines)
        return token.isEmpty ? nil : token
    }

    var apiTokenHeader: String? {
        let token = headers["x-typewhisper-api-token"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        return token?.isEmpty == false ? token : nil
    }
}

private extension String {
    func regionMatches(_ prefix: String, options: String.CompareOptions) -> Bool {
        range(of: prefix, options: options, range: startIndex..<endIndex, locale: nil)?.lowerBound == startIndex
    }
}
