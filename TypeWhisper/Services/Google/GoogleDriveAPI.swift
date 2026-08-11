import Foundation

/// Google Drive v3 wire types and request builders ([Google Phase 2 · M1]). Pure and static, the
/// `GoogleCalendarAPI` shape: the sync engine / importer send these requests through
/// `GoogleHTTPTransport` and decode the pages; nothing here touches the network, so the whole
/// surface is unit-testable (`GoogleDriveAPITests`).
enum GoogleDriveAPI {
    static let baseURL = URL(string: "https://www.googleapis.com/drive/v3")!

    /// The Drive scope Phase 2 requests (D-D2). Restricted; consent works under the Testing-mode
    /// screen (D-D1). `drive.meet.readonly` is the flagged tightening candidate — if QA step 11
    /// shows `files.list`/`files.export` behave under it, the switch is this one constant plus a
    /// consent-screen swap (the code is scope-agnostic by construction).
    static let readonlyScope = "https://www.googleapis.com/auth/drive.readonly"

    /// Discovery page size (D-D3); `nextPageToken` drives pagination.
    static let pageSize = 100
    /// Upper bound on pages walked per list pass — a runaway-pagination guard for the engine and
    /// the backfill scan (D-D3). 20 pages × 100 files is far beyond any real Gemini-notes corpus.
    static let maxListPages = 20

    /// Export MIME for Gemini notes docs (D-D3, load-bearing): Google's Docs→markdown converter
    /// preserves the heading/bold markup `TranscriptFileParser.parseGeminiNotes` keys on;
    /// `text/plain` drops it, so the Gemini rung would never fire.
    static let markdownExportMIME = "text/markdown"
    /// Degraded fallback when the markdown export itself is rejected (D-D3 fallback rung 2).
    static let plainTextExportMIME = "text/plain"

    // MARK: - Namespacing

    /// Ledger identity for a Drive file: `google:<sub>:<driveFileID>` (the Phase 1 §9 convention).
    /// Composed through `GoogleCalendarID` — the one place the namespace format lives — so the
    /// prefix can never drift from calendar/event IDs (D-D5).
    static func fileID(sub: String, raw: String) -> String {
        GoogleCalendarID.eventID(sub: sub, raw: raw)
    }

    // MARK: - Wire models (Decodable mirrors of the v3 resources; only the fields Phase 2 reads)

    /// One file of a `files.list` page. Times stay RFC 3339 strings on the wire (the
    /// `GoogleCalendarAPI` discipline); the parsed accessors are what the ledger/matcher consume.
    struct GDriveFile: Decodable, Equatable, Sendable {
        let id: String
        let name: String
        let mimeType: String?
        let createdTime: String?
        let modifiedTime: String?

        var createdDate: Date? { createdTime.flatMap(GoogleCalendarAPI.date(fromRFC3339:)) }
        var modifiedDate: Date? { modifiedTime.flatMap(GoogleCalendarAPI.date(fromRFC3339:)) }
    }

    struct GDriveFileListPage: Decodable, Sendable {
        let files: [GDriveFile]?
        let nextPageToken: String?
    }

    // MARK: - Request builders

    /// `GET files` — the D-D3 discovery query. The `name contains` terms are **derived from**
    /// `ImportedMeetingTitle.notesSuffixes` (the canonical marker list, D-D3/F3): one term per
    /// phrase, verbatim (Drive matches case-insensitively) — one list, two derivations (the title
    /// cleaner wraps the same phrases in its suffix regex), impossible to drift.
    ///
    /// `watermark` bounds the scan to `modifiedTime > watermark` (auto-import); `nil` scans all
    /// history (backfill, D-D7). `corpora`/`driveId` stay at defaults (user corpus) for v1.
    static func filesListRequest(
        token: String,
        watermark: Date? = nil,
        pageToken: String? = nil
    ) -> URLRequest {
        let nameTerms = ImportedMeetingTitle.notesSuffixes
            .map { "name contains '\(escapedQueryLiteral($0))'" }
            .joined(separator: " or ")
        var q = "mimeType='application/vnd.google-apps.document' and (\(nameTerms)) and trashed = false"
        if let watermark {
            q += " and modifiedTime > '\(GoogleCalendarAPI.rfc3339String(watermark))'"
        }
        var components = URLComponents(
            url: baseURL.appendingPathComponent("files"),
            resolvingAgainstBaseURL: false
        )!
        var items = [
            URLQueryItem(name: "q", value: q),
            URLQueryItem(name: "fields", value: "nextPageToken, files(id, name, mimeType, createdTime, modifiedTime)"),
            URLQueryItem(name: "orderBy", value: "modifiedTime"),
            URLQueryItem(name: "pageSize", value: String(pageSize)),
        ]
        if let pageToken {
            items.append(URLQueryItem(name: "pageToken", value: pageToken))
        }
        components.queryItems = items
        return authorizedGET(components.url!, token: token)
    }

    /// `GET files/{fileID}/export?mimeType=…` — Docs content export (D-D3). `fileID` is the **raw**
    /// Drive ID (never the namespaced ledger ID); percent-encoded defensively even though Drive IDs
    /// are URL-safe today.
    static func exportRequest(fileID: String, mimeType: String, token: String) -> URLRequest {
        let encodedID = fileID.addingPercentEncoding(withAllowedCharacters: fileIDAllowed) ?? fileID
        var components = URLComponents(string: "\(baseURL.absoluteString)/files/\(encodedID)/export")!
        components.queryItems = [URLQueryItem(name: "mimeType", value: mimeType)]
        return authorizedGET(components.url!, token: token)
    }

    /// Escape a string literal for the Drive query language: backslash-escape `\` and `'` inside
    /// the single-quoted `name contains '…'` term (D-D3 normative query).
    static func escapedQueryLiteral(_ raw: String) -> String {
        raw
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
    }

    // MARK: - Errors

    /// A non-200 API response. Transient by contract (quota, 5xx, auth hiccup): the sync engine
    /// surfaces it via `lastSyncError` and retries next tick; the importer records a ledger failure
    /// (D-D5) — only `GoogleAuthError.needsReauth` (thrown by the token seam, never here) demotes
    /// an account (Phase 1 error-taxonomy contract).
    struct RequestFailed: Error, LocalizedError, Equatable {
        let statusCode: Int
        var errorDescription: String? { "Google Drive API returned HTTP \(statusCode)" }
    }

    // MARK: - Private

    private static let fileIDAllowed: CharacterSet = {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return allowed
    }()

    private static func authorizedGET(_ url: URL, token: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }
}
