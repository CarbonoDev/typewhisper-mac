import Foundation

/// Google Calendar v3 wire types and request builders ([Google Phase 1 · M3]). Pure and static:
/// the sync engine sends the requests through `GoogleHTTPTransport` and decodes the pages; nothing
/// here touches the network, so the whole surface is unit-testable with fixture JSON
/// (`GoogleCalendarMapperTests` / `GoogleCalendarSyncEngineTests`).
enum GoogleCalendarAPI {
    static let baseURL = URL(string: "https://www.googleapis.com/calendar/v3")!
    /// Page size for both `calendarList` and `events` (D-G7); `nextPageToken` drives pagination.
    static let maxResults = 250

    // MARK: - Wire models (Decodable mirrors of the v3 resources; only the fields Phase 1 reads)

    /// One entry of `users/me/calendarList`.
    struct GCalCalendarListEntry: Decodable, Sendable {
        let id: String
        /// Display title. For the primary calendar this is usually the account email.
        let summary: String?
        let primary: Bool?
        /// Hex color like `"#9fe1e7"` — mapped to `CalendarColor` by the mapper.
        let backgroundColor: String?
        let accessRole: String?
    }

    struct GCalCalendarListPage: Decodable, Sendable {
        let items: [GCalCalendarListEntry]?
        let nextPageToken: String?
    }

    /// Google's start/end shape: exactly one of `date` (all-day, `yyyy-MM-dd`) or `dateTime`
    /// (RFC 3339) is present. Kept as strings — parsing happens in the (pure) mapper so the
    /// all-day time zone is injectable.
    struct GCalEventDateTime: Decodable, Sendable {
        let date: String?
        let dateTime: String?
    }

    struct GCalAttendee: Decodable, Sendable {
        let email: String?
        let displayName: String?
        let organizer: Bool?
        /// Google's `self` flag (the connected account is this attendee). Renamed — `self` is a
        /// Swift keyword.
        let isSelf: Bool?
        /// `"accepted" | "declined" | "tentative" | "needsAction"`.
        let responseStatus: String?

        enum CodingKeys: String, CodingKey {
            case email, displayName, organizer, responseStatus
            case isSelf = "self"
        }
    }

    struct GCalConferenceEntryPoint: Decodable, Sendable {
        let entryPointType: String?
        let uri: String?
    }

    struct GCalConferenceData: Decodable, Sendable {
        let entryPoints: [GCalConferenceEntryPoint]?
    }

    /// One event instance (`singleEvents=true`, so recurring events arrive as occurrence-unique
    /// instances whose `id` needs no start-timestamp suffix — D-G3).
    struct GCalEvent: Decodable, Sendable {
        let id: String
        /// `"confirmed" | "tentative" | "cancelled"` — cancelled instances are dropped by the mapper.
        let status: String?
        let summary: String?
        /// Event description; may contain HTML (the mapper strips it to plain text).
        let description: String?
        let start: GCalEventDateTime?
        let end: GCalEventDateTime?
        let attendees: [GCalAttendee]?
        let organizer: GCalAttendee?
        /// Present on instances of a recurring series — the D-G8 `seriesID` trigger.
        let recurringEventId: String?
        /// Series-stable iCalendar UID — the D-G8 `seriesID` value (bare, un-namespaced).
        let iCalUID: String?
        let hangoutLink: String?
        let conferenceData: GCalConferenceData?
        let location: String?
    }

    struct GCalEventsPage: Decodable, Sendable {
        let items: [GCalEvent]?
        let nextPageToken: String?
    }

    // MARK: - Request builders

    /// `GET users/me/calendarList` — every calendar the account can see.
    static func calendarListRequest(token: String, pageToken: String? = nil) -> URLRequest {
        var components = URLComponents(
            url: baseURL.appendingPathComponent("users/me/calendarList"),
            resolvingAgainstBaseURL: false
        )!
        var items = [URLQueryItem(name: "maxResults", value: String(maxResults))]
        if let pageToken {
            items.append(URLQueryItem(name: "pageToken", value: pageToken))
        }
        components.queryItems = items
        return authorizedGET(components.url!, token: token)
    }

    /// `GET calendars/{id}/events` in `[timeMin, timeMax]`, expanded to single instances (D-G3:
    /// `singleEvents=true` makes recurring-event IDs occurrence-unique) and excluding deletions.
    static func eventsRequest(
        calendarID: String,
        token: String,
        timeMin: Date,
        timeMax: Date,
        pageToken: String? = nil
    ) -> URLRequest {
        // Calendar IDs are email-like and can contain `#` (holiday calendars) — percent-encode the
        // path segment so it never terminates the URL early.
        let encodedID = calendarID.addingPercentEncoding(withAllowedCharacters: calendarIDAllowed) ?? calendarID
        var components = URLComponents(string: "\(baseURL.absoluteString)/calendars/\(encodedID)/events")!
        var items = [
            URLQueryItem(name: "singleEvents", value: "true"),
            URLQueryItem(name: "showDeleted", value: "false"),
            URLQueryItem(name: "maxResults", value: String(maxResults)),
            URLQueryItem(name: "timeMin", value: rfc3339String(timeMin)),
            URLQueryItem(name: "timeMax", value: rfc3339String(timeMax)),
        ]
        if let pageToken {
            items.append(URLQueryItem(name: "pageToken", value: pageToken))
        }
        components.queryItems = items
        return authorizedGET(components.url!, token: token)
    }

    // MARK: - Dates

    /// RFC 3339 rendering for `timeMin`/`timeMax` (fresh formatter per call — cheap, and avoids a
    /// non-Sendable static under strict concurrency).
    static func rfc3339String(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    /// Parses an event `dateTime` (RFC 3339, with or without fractional seconds).
    static func date(fromRFC3339 string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: string) {
            return date
        }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: string)
    }

    // MARK: - Errors

    /// A non-200 API response. Transient by contract (quota, 5xx, auth hiccup): the sync engine
    /// surfaces it via `lastSyncError` and retries on the next tick — only `GoogleAuthError
    /// .needsReauth` (thrown by the token seam, never here) demotes an account (M1 handoff).
    struct RequestFailed: Error, LocalizedError, Equatable {
        let statusCode: Int
        var errorDescription: String? { "Google Calendar API returned HTTP \(statusCode)" }
    }

    // MARK: - Private

    private static let calendarIDAllowed: CharacterSet = {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~@")
        return allowed
    }()

    private static func authorizedGET(_ url: URL, token: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }
}
