import XCTest
@testable import TypeWhisper

/// `GmailBodyText` — pure D-M1 step-5 extraction: base64url decoding, plain-part-first traversal,
/// naive HTML strip + entity decode, snippet fallback, 2,000-char cap.
final class GmailBodyTextTests: XCTestCase {
    /// RFC 4648 §5 encoding as Gmail sends it: `-`/`_` alphabet, padding stripped.
    private func b64url(_ text: String) -> String {
        Data(text.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func leaf(mime: String, text: String) -> GmailAPI.GmailPayload {
        GmailAPI.GmailPayload(
            mimeType: mime,
            headers: nil,
            body: GmailAPI.GmailBody(data: b64url(text)),
            parts: nil
        )
    }

    private func multipart(_ mime: String, parts: [GmailAPI.GmailPayload]) -> GmailAPI.GmailPayload {
        GmailAPI.GmailPayload(mimeType: mime, headers: nil, body: nil, parts: parts)
    }

    // MARK: - base64url

    func testDecodesBase64URLAlphabetWithoutPadding() {
        // "8-bit ÿ~?" exercises bytes that produce `+`/`/` in classic base64 and needs padding.
        let original = "Señor ÿ~? plan: 100% >> done"
        XCTAssertEqual(GmailBodyText.decodeBase64URL(b64url(original)), original)
    }

    func testUndecodableDataReturnsNil() {
        XCTAssertNil(GmailBodyText.decodeBase64URL("!!not base64!!"))
    }

    // MARK: - Part traversal

    func testPrefersPlainPartOverHTMLSibling() {
        let payload = multipart("multipart/alternative", parts: [
            leaf(mime: "text/html", text: "<b>rich</b>"),
            leaf(mime: "text/plain", text: "plain wins"),
        ])
        XCTAssertEqual(GmailBodyText.extract(payload: payload, snippet: "snip"), "plain wins")
    }

    func testFindsPlainPartInNestedMultipart() {
        let payload = multipart("multipart/mixed", parts: [
            multipart("multipart/alternative", parts: [
                leaf(mime: "text/plain", text: "nested body"),
                leaf(mime: "text/html", text: "<p>html</p>"),
            ]),
            leaf(mime: "application/pdf", text: "binary"),
        ])
        XCTAssertEqual(GmailBodyText.extract(payload: payload, snippet: "snip"), "nested body")
    }

    func testSinglePartPlainMessageBodyOnThePayloadItself() {
        XCTAssertEqual(
            GmailBodyText.extract(payload: leaf(mime: "text/plain", text: "top-level body"), snippet: "snip"),
            "top-level body"
        )
    }

    // MARK: - HTML fallback

    func testHTMLFallbackStripsTagsAndDecodesEntities() {
        let payload = multipart("multipart/alternative", parts: [
            leaf(
                mime: "text/html",
                text: "<html><style>p {color: red}</style><body><p>Q3 plan &amp; budget</p><br><div>&quot;agreed&quot; &lt;maybe&gt;</div></body></html>"
            ),
        ])
        let extracted = GmailBodyText.extract(payload: payload, snippet: "snip")
        // `</p>` + `<br>` collapse to one blank line; entities decode AFTER tag stripping, so the
        // literal `<maybe>` survives.
        XCTAssertEqual(extracted, "Q3 plan & budget\n\n\"agreed\" <maybe>")
        XCTAssertFalse(extracted.contains("color"), "style blocks dropped")
    }

    func testMultiLineStyleBlockIsFullyStripped() {
        // Real HTML mail always carries multi-line <style> blocks; without dot-matches-newline
        // the raw CSS would land inside the extracted passage (M1 review finding).
        let html = """
        <html><head><STYLE type="text/css">
        .body { color: red; }
        .footer {
            font-size: 10px;
        }
        </STYLE></head><body><p>Hello budget</p></body></html>
        """
        let payload = multipart("multipart/alternative", parts: [leaf(mime: "text/html", text: html)])
        let extracted = GmailBodyText.extract(payload: payload, snippet: "snip")
        XCTAssertEqual(extracted, "Hello budget")
        XCTAssertFalse(extracted.contains("color"), "multi-line CSS must not survive")
    }

    func testAmpersandEntityDecodesLastSoDoubleEscapesStayLiteral() {
        let payload = multipart("multipart/alternative", parts: [
            leaf(mime: "text/html", text: "<p>a &amp;lt; b</p>"),
        ])
        XCTAssertEqual(
            GmailBodyText.extract(payload: payload, snippet: ""),
            "a &lt; b",
            "&amp;lt; is the author writing the literal \"&lt;\" — never re-decoded to \"<\""
        )
    }

    // MARK: - Snippet fallback + cap

    func testFallsBackToSnippetWhenNoTextPartDecodes() {
        XCTAssertEqual(GmailBodyText.extract(payload: nil, snippet: "the snippet"), "the snippet")
        let attachmentOnly = multipart("multipart/mixed", parts: [leaf(mime: "application/pdf", text: "x")])
        XCTAssertEqual(GmailBodyText.extract(payload: attachmentOnly, snippet: "the snippet"), "the snippet")
    }

    func testContentIsCappedAtTwoThousandChars() {
        let long = String(repeating: "a", count: 3_000)
        let extracted = GmailBodyText.extract(payload: leaf(mime: "text/plain", text: long), snippet: "")
        XCTAssertEqual(extracted.count, GmailBodyText.contentCharCap)
        XCTAssertEqual(GmailBodyText.contentCharCap, 2_000, "mirrors ObsidianVaultService.passageCharBudget (D-M1)")
    }
}
