import Foundation

/// Gmail v1 wire types and request builders ([Google Phase 3 · M1]). Pure and static — the
/// `GoogleCalendarAPI` shape: `GmailContextService` sends the requests through
/// `GoogleHTTPTransport` and decodes the responses; nothing here touches the network, so the whole
/// surface is unit-testable with fixture JSON (`GmailContextServiceTests`).
enum GmailAPI {
    static let baseURL = URL(string: "https://gmail.googleapis.com/gmail/v1")!

    // MARK: - Wire models (Decodable mirrors; only the fields Phase 3 reads)

    /// One entry of `users/me/messages` — an id pair only; everything else needs a `get`.
    struct GmailMessageRef: Decodable, Sendable {
        let id: String
        let threadId: String
    }

    struct GmailMessageList: Decodable, Sendable {
        let messages: [GmailMessageRef]?
        let resultSizeEstimate: Int?
    }

    struct GmailHeader: Decodable, Sendable {
        let name: String
        let value: String
    }

    struct GmailBody: Decodable, Sendable {
        /// Base64url-encoded content (`GmailBodyText` decodes it).
        let data: String?
    }

    /// A MIME node: leaf parts carry `body.data`; multiparts carry `parts`. Recursive, matching
    /// the wire shape (`multipart/alternative` inside `multipart/mixed` is common).
    struct GmailPayload: Decodable, Sendable {
        let mimeType: String?
        let headers: [GmailHeader]?
        let body: GmailBody?
        let parts: [GmailPayload]?
    }

    /// A message as returned by `format=metadata` (headers + snippet) or `format=full`
    /// (adds the body payload tree).
    struct GmailMessage: Decodable, Sendable {
        let id: String
        let threadId: String
        let snippet: String?
        /// Epoch milliseconds as a string (Gmail's wire form).
        let internalDate: String?
        let payload: GmailPayload?
    }

    // MARK: - Request builders

    /// `GET users/me/messages?q=…` — server-side search. `maxResults` is the per-clause cap
    /// (D-M1 two-call merge: 25 for the attendee query, 10 for the subject query).
    static func listRequest(token: String, query: String, maxResults: Int) -> URLRequest {
        var components = URLComponents(
            url: baseURL.appendingPathComponent("users/me/messages"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "maxResults", value: String(maxResults)),
        ]
        // URLQueryItem leaves a literal `+` unencoded and Google decodes `+` as a space, which
        // would garble plus-addressed attendee clauses (john+cal@x.com) — escape it explicitly
        // (the GmailWebURL precedent; review finding, M1).
        components.percentEncodedQuery = components.percentEncodedQuery?
            .replacingOccurrences(of: "+", with: "%2B")
        return authorizedGET(components.url!, token: token)
    }

    /// `GET users/me/messages/{id}?format=metadata` with the four headers the candidate list
    /// renders plus `Message-ID` — the only mailbox-independent identity, which cross-account
    /// dedupe keys on (message/thread ids differ per mailbox, D-M2). The response also carries
    /// `snippet` and `threadId` (D-M1 step 3).
    static func messageMetadataRequest(token: String, id: String) -> URLRequest {
        var components = messageComponents(id: id)
        components.queryItems = [
            URLQueryItem(name: "format", value: "metadata"),
            URLQueryItem(name: "metadataHeaders", value: "Subject"),
            URLQueryItem(name: "metadataHeaders", value: "From"),
            URLQueryItem(name: "metadataHeaders", value: "To"),
            URLQueryItem(name: "metadataHeaders", value: "Date"),
            URLQueryItem(name: "metadataHeaders", value: "Message-ID"),
        ]
        return authorizedGET(components.url!, token: token)
    }

    /// `GET users/me/messages/{id}?format=full` — body payload for the top-K passages actually
    /// fed to an LLM (D-M1 step 5); never issued for the UI list.
    static func messageFullRequest(token: String, id: String) -> URLRequest {
        var components = messageComponents(id: id)
        components.queryItems = [URLQueryItem(name: "format", value: "full")]
        return authorizedGET(components.url!, token: token)
    }

    // MARK: - Errors

    /// A non-200 API response. Transient by contract (quota, 5xx): surfaced as a fetch error and
    /// retried on the next refresh — only `GoogleAuthError.needsReauth` (thrown by the token seam,
    /// never here) demotes an account (the `GoogleCalendarAPI.RequestFailed` shape).
    struct RequestFailed: Error, LocalizedError, Equatable {
        let statusCode: Int
        var errorDescription: String? { "Gmail API returned HTTP \(statusCode)" }
    }

    // MARK: - Private

    private static func messageComponents(id: String) -> URLComponents {
        // Message IDs are hex, but percent-encode the path segment defensively (the
        // `GoogleCalendarAPI` calendar-ID precedent).
        let encoded = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
        return URLComponents(string: "\(baseURL.absoluteString)/users/me/messages/\(encoded)")!
    }

    private static func authorizedGET(_ url: URL, token: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }
}
