import XCTest
@testable import TypeWhisper

/// Pure Drive v3 request assembly and wire decoding ([Google Phase 2 · M1]): the D-D3 normative
/// discovery query — including the assertion that its `name contains` terms are **derived from**
/// the canonical marker list `ImportedMeetingTitle.notesSuffixes` (D-D3/F3) — watermark
/// formatting, literal escaping, export URL + MIME, and the Phase 1 §9 file-ID namespacing.
final class GoogleDriveAPITests: XCTestCase {

    // MARK: - Helpers

    private func queryItems(of request: URLRequest) -> [String: String] {
        guard let url = request.url,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return [:] }
        var items: [String: String] = [:]
        for item in components.queryItems ?? [] {
            items[item.name] = item.value
        }
        return items
    }

    // MARK: - files.list (D-D3)

    func testFilesListRequestBuildsNormativeQuery() {
        let request = GoogleDriveAPI.filesListRequest(token: "tok-123")

        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer tok-123")
        XCTAssertEqual(request.url?.host, "www.googleapis.com")
        XCTAssertEqual(request.url?.path, "/drive/v3/files")

        let items = queryItems(of: request)
        let q = items["q"] ?? ""
        XCTAssertTrue(q.hasPrefix("mimeType='application/vnd.google-apps.document' and ("))
        XCTAssertTrue(q.hasSuffix(") and trashed = false"), "no watermark bound without a watermark")
        XCTAssertEqual(
            items["fields"],
            "nextPageToken, files(id, name, mimeType, createdTime, modifiedTime)"
        )
        XCTAssertEqual(items["orderBy"], "modifiedTime")
        XCTAssertEqual(items["pageSize"], String(GoogleDriveAPI.pageSize))
        XCTAssertNil(items["pageToken"])
    }

    /// D-D3/F3: one `name contains '<phrase>'` term per canonical marker phrase, generated from
    /// `ImportedMeetingTitle.notesSuffixes` — one list, two derivations, impossible to drift.
    func testFilesListNameTermsAreDerivedFromCanonicalMarkerList() {
        let q = queryItems(of: GoogleDriveAPI.filesListRequest(token: "t"))["q"] ?? ""

        for phrase in ImportedMeetingTitle.notesSuffixes {
            XCTAssertTrue(
                q.contains("name contains '\(phrase)'"),
                "missing term for canonical marker '\(phrase)'"
            )
        }
        // Exactly the canonical list — no extra hard-coded markers.
        let termCount = q.components(separatedBy: "name contains").count - 1
        XCTAssertEqual(termCount, ImportedMeetingTitle.notesSuffixes.count)
        // And the list itself still carries the three Gemini phrases the query relies on.
        XCTAssertEqual(
            Set(ImportedMeetingTitle.notesSuffixes),
            ["notas de gemini", "notes by gemini", "gemini notes"]
        )
    }

    func testFilesListRequestAppendsWatermarkBound() {
        let watermark = Date(timeIntervalSince1970: 1_770_000_000)
        let request = GoogleDriveAPI.filesListRequest(token: "t", watermark: watermark)

        let q = queryItems(of: request)["q"] ?? ""
        let expected = " and modifiedTime > '\(GoogleCalendarAPI.rfc3339String(watermark))'"
        XCTAssertTrue(q.hasSuffix(expected), "watermark must be the trailing RFC 3339 bound; got: \(q)")
    }

    func testFilesListRequestCarriesPageToken() {
        let request = GoogleDriveAPI.filesListRequest(token: "t", pageToken: "page-2")
        XCTAssertEqual(queryItems(of: request)["pageToken"], "page-2")
    }

    func testEscapedQueryLiteralEscapesQuotesAndBackslashes() {
        XCTAssertEqual(GoogleDriveAPI.escapedQueryLiteral("O'Brien"), "O\\'Brien")
        XCTAssertEqual(GoogleDriveAPI.escapedQueryLiteral(#"a\b"#), #"a\\b"#)
        XCTAssertEqual(GoogleDriveAPI.escapedQueryLiteral("plain"), "plain")
    }

    // MARK: - files.export (D-D3)

    func testExportRequestBuildsURLAndMIME() {
        let request = GoogleDriveAPI.exportRequest(
            fileID: "doc-abc_123",
            mimeType: GoogleDriveAPI.markdownExportMIME,
            token: "tok-9"
        )

        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.path, "/drive/v3/files/doc-abc_123/export")
        XCTAssertEqual(queryItems(of: request)["mimeType"], "text/markdown")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer tok-9")
    }

    func testExportRequestPercentEncodesFileID() {
        let request = GoogleDriveAPI.exportRequest(fileID: "we/ird id", mimeType: "text/plain", token: "t")
        // A hostile ID never terminates the path early — it rides as one encoded segment.
        XCTAssertTrue(request.url!.absoluteString.contains("/files/we%2Fird%20id/export"))
    }

    // MARK: - Namespacing (Phase 1 §9)

    func testFileIDNamespacingMatchesGoogleConvention() {
        let namespaced = GoogleDriveAPI.fileID(sub: "sub-42", raw: "1AbC")
        XCTAssertEqual(namespaced, "google:sub-42:1AbC")
        // Round-trips through the one canonical parser.
        XCTAssertEqual(GoogleCalendarID.accountSub(fromNamespacedID: namespaced), "sub-42")
    }

    // MARK: - Wire decoding

    func testFileListPageDecodingAndDateAccessors() throws {
        let json = #"""
        {
          "nextPageToken": "next-1",
          "files": [
            {
              "id": "f1",
              "name": "Weekly sync - 2026_07_07 11_00 CST - Notas de Gemini",
              "mimeType": "application/vnd.google-apps.document",
              "createdTime": "2026-07-07T17:05:00.000Z",
              "modifiedTime": "2026-07-07T18:00:30.500Z"
            }
          ]
        }
        """#
        let page = try JSONDecoder().decode(GoogleDriveAPI.GDriveFileListPage.self, from: Data(json.utf8))

        XCTAssertEqual(page.nextPageToken, "next-1")
        let file = try XCTUnwrap(page.files?.first)
        XCTAssertEqual(file.id, "f1")
        XCTAssertEqual(file.name, "Weekly sync - 2026_07_07 11_00 CST - Notas de Gemini")
        XCTAssertEqual(file.createdDate, GoogleCalendarAPI.date(fromRFC3339: "2026-07-07T17:05:00.000Z"))
        XCTAssertEqual(file.modifiedDate, GoogleCalendarAPI.date(fromRFC3339: "2026-07-07T18:00:30.500Z"))
    }

    func testRequestFailedDescribesStatusCode() {
        XCTAssertEqual(
            GoogleDriveAPI.RequestFailed(statusCode: 403).errorDescription,
            "Google Drive API returned HTTP 403"
        )
    }
}
