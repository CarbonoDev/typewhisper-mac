import XCTest
@testable import TypeWhisper

/// `GmailWebURL` — the pure D-M6 account-correct web URL: `authuser` by email (never the
/// ordering-fragile `/u/N/`), `#all/<messageID>` thread deep-link, percent-escaped email.
final class GmailWebURLTests: XCTestCase {
    func testBuildsAuthuserAndThreadFragmentForm() {
        let url = GmailWebURL.messageURL(messageID: "18c2f0a1b2c3", accountEmail: "ada@example.com")
        XCTAssertEqual(
            url?.absoluteString,
            "https://mail.google.com/mail/?authuser=ada%40example.com#all/18c2f0a1b2c3"
        )
    }

    func testPercentEscapesPlusAddressedEmails() {
        // "+" must be escaped explicitly — left literal it reads as a space in a query string.
        let url = GmailWebURL.messageURL(messageID: "abc123", accountEmail: "marco+work@x.com")
        XCTAssertEqual(
            url?.absoluteString,
            "https://mail.google.com/mail/?authuser=marco%2Bwork%40x.com#all/abc123"
        )
    }

    func testEmptyMessageIDOrEmptyEmailYieldsNil() {
        XCTAssertNil(GmailWebURL.messageURL(messageID: "", accountEmail: "ada@example.com"))
        XCTAssertNil(GmailWebURL.messageURL(messageID: "abc123", accountEmail: ""))
    }
}
