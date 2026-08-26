import Foundation
import os

typealias APIHandler = @Sendable (HTTPRequest) async -> HTTPResponse

final class APIRouter: Sendable {
    private typealias RouteEntry = (method: String, path: String, handler: APIHandler)

    /// Who may call the local API from a browser extension, and with what credential.
    ///
    /// Both halves are deliberately strict. `allowedOrigins` is an explicit allowlist (empty by
    /// default — nothing is trusted until the user pastes the bridge extension's id into Settings),
    /// because *every* extension the user has installed shares the `chrome-extension://` scheme:
    /// echoing the scheme rather than the identity would hand each of them the whole meeting archive.
    /// `token` is the credential an allowlisted extension must still present, and it applies even when
    /// "Require API Token" is off for loopback callers — an extension is not a local tool the user
    /// launched, it is code from the browser, so it never rides on the loopback exemption.
    struct ExtensionOriginPolicy: Sendable {
        /// Normalized full origins, e.g. `chrome-extension://abcdefghijklmnopabcdefghijklmnop`.
        var allowedOrigins: Set<String>
        /// The API token an extension caller must present. Nil/empty denies every extension request.
        var token: String?

        static let denyAll = ExtensionOriginPolicy(allowedOrigins: [], token: nil)

        func allows(_ origin: String) -> Bool {
            allowedOrigins.contains(origin.lowercased())
        }
    }

    private let routes = OSAllocatedUnfairLock<[RouteEntry]>(initialState: [])
    private let apiTokenProvider: @Sendable () -> String?
    private let extensionOriginPolicy: @Sendable () -> ExtensionOriginPolicy

    init(
        apiTokenProvider: @escaping @Sendable () -> String? = { nil },
        extensionOriginPolicy: @escaping @Sendable () -> ExtensionOriginPolicy = { .denyAll }
    ) {
        self.apiTokenProvider = apiTokenProvider
        self.extensionOriginPolicy = extensionOriginPolicy
    }

    func register(_ method: String, _ path: String, handler: @escaping APIHandler) {
        routes.withLock { routes in
            routes.append((method: method.uppercased(), path: path, handler: handler))
        }
    }

    func route(_ request: HTTPRequest) async -> HTTPResponse {
        // A browser-extension caller is handled apart from every other client: it must be on the
        // allowlist, and it must carry the token whatever the loopback token setting says.
        let extensionOrigin = Self.extensionOrigin(of: request)
        var extensionPolicy: ExtensionOriginPolicy?
        if let extensionOrigin {
            let policy = extensionOriginPolicy()
            guard policy.allows(extensionOrigin) else {
                // No CORS headers on the way out: an unlisted extension learns nothing and the browser
                // blocks the response body regardless.
                return Self.forbiddenOrigin
            }
            extensionPolicy = policy
        }
        let cors = Self.corsHeaders(forAllowedExtensionOrigin: extensionOrigin)

        if request.method == "OPTIONS" {
            // A CORS preflight never carries `Authorization` (browsers strip it), so it is answered on
            // the allowlist alone; the real request that follows is token-checked below.
            return HTTPResponse(status: 204, contentType: "text/plain", body: Data()).adding(headers: cors)
        }

        let registeredRoutes = routes.withLock { $0 }

        // Exact-path routes win over `{placeholder}` patterns, so a literal like
        // `/v1/meetings/import-transcript` is never shadowed by `/v1/meetings/{id}`.
        for route in registeredRoutes where !route.path.contains("{") {
            if route.method == request.method && route.path == request.path {
                guard isAuthorized(request, extensionPolicy: extensionPolicy) else {
                    return Self.unauthorized.adding(headers: cors)
                }
                return await route.handler(request).adding(headers: cors)
            }
        }

        for route in registeredRoutes where route.path.contains("{") {
            guard route.method == request.method,
                  let pathParams = Self.matchPattern(route.path, path: request.path) else { continue }
            guard isAuthorized(request, extensionPolicy: extensionPolicy) else {
                return Self.unauthorized.adding(headers: cors)
            }
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

    /// The request's `Origin`, normalized, when it is a browser-extension origin — the only kind of
    /// cross-origin caller this API knows about. Nil for a plain local client (the CLI, Raycast,
    /// `curl`), which sends no `Origin` at all, and for ordinary web pages, which get no CORS headers
    /// and therefore cannot read a response.
    static func extensionOrigin(of request: HTTPRequest) -> String? {
        guard let origin = request.headers["origin"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
            origin.hasPrefix("chrome-extension://") || origin.hasPrefix("moz-extension://") else {
            return nil
        }
        return origin
    }

    /// Parse the user-configured allowlist into normalized origins. Accepts either bare extension ids
    /// (what `chrome://extensions` shows, expanded to both extension schemes) or full origins, one per
    /// line or comma-separated. An empty setting yields an empty set — nothing is trusted by default.
    static func parseAllowedExtensionOrigins(_ raw: String) -> Set<String> {
        var origins: Set<String> = []
        for entry in raw.components(separatedBy: CharacterSet(charactersIn: ",\n\r ")) {
            let trimmed = entry.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !trimmed.isEmpty else { continue }
            if trimmed.contains("://") {
                guard trimmed.hasPrefix("chrome-extension://") || trimmed.hasPrefix("moz-extension://") else {
                    continue
                }
                var origin = trimmed
                while origin.hasSuffix("/") { origin.removeLast() }
                origins.insert(origin)
            } else {
                origins.insert("chrome-extension://\(trimmed)")
                origins.insert("moz-extension://\(trimmed)")
            }
        }
        return origins
    }

    /// CORS headers for an **allowlisted** browser-extension caller (the Google Meet caption bridge).
    ///
    /// Deliberately neither `Access-Control-Allow-Origin: *` nor a blanket echo of any
    /// `chrome-extension://` origin: every extension the user has installed shares that scheme, so
    /// echoing the scheme would CORS-approve the whole meeting archive (and the live-segment injection
    /// endpoints) to all of them. Only the extension the user pasted into Settings is echoed, and by
    /// then it has also had to present the API token. Every other caller gets no CORS headers at all,
    /// which is what the browser needs to see in order to block the response.
    static func corsHeaders(forAllowedExtensionOrigin origin: String?) -> [String: String] {
        guard let origin else { return [:] }
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

    private static let forbiddenOrigin = HTTPResponse.error(
        status: 403,
        message: "Browser extension origin is not allowed. Add its extension id in Settings › Advanced › API Server."
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

    private func isAuthorized(_ request: HTTPRequest, extensionPolicy: ExtensionOriginPolicy?) -> Bool {
        // An allowlisted extension still authenticates on every route — including the otherwise public
        // `/v1/status` — and is never covered by the "no token configured ⇒ everything is authorized"
        // rule that exists for local tools the user launched themselves.
        if let extensionPolicy {
            guard let expectedToken = extensionPolicy.token, !expectedToken.isEmpty,
                  let providedToken = request.bearerToken ?? request.apiTokenHeader else {
                return false
            }
            return Self.constantTimeEquals(providedToken, expectedToken)
        }

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
