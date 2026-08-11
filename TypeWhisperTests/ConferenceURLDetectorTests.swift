import XCTest
@testable import TypeWhisper

/// [Google Phase 1 · M5] Pure tests for `ConferenceURLDetector` (spec §5 M5): the URL field wins
/// when it is a conference link, the notes scan recovers the first known-host link otherwise, and
/// non-conference URLs / lookalike hosts are ignored.
final class ConferenceURLDetectorTests: XCTestCase {
    // MARK: - URL field

    func testKnownHostURLFieldIsDetected() {
        let url = URL(string: "https://meet.google.com/abc-defg-hij")!
        XCTAssertEqual(
            ConferenceURLDetector.detect(url: url, notes: nil),
            "https://meet.google.com/abc-defg-hij"
        )
    }

    func testSubdomainOfKnownHostIsDetected() {
        let url = URL(string: "https://us02web.zoom.us/j/1234567890?pwd=x")!
        XCTAssertEqual(
            ConferenceURLDetector.detect(url: url, notes: nil),
            "https://us02web.zoom.us/j/1234567890?pwd=x"
        )
    }

    func testURLFieldWinsOverNotes() {
        let url = URL(string: "https://teams.microsoft.com/l/meetup-join/xyz")!
        let notes = "Backup: https://zoom.us/j/999"
        XCTAssertEqual(
            ConferenceURLDetector.detect(url: url, notes: notes),
            "https://teams.microsoft.com/l/meetup-join/xyz"
        )
    }

    func testNonConferenceURLFieldFallsThroughToNotes() {
        let url = URL(string: "https://example.com/agenda")!
        let notes = "Join here: https://company.webex.com/meet/marco"
        XCTAssertEqual(
            ConferenceURLDetector.detect(url: url, notes: notes),
            "https://company.webex.com/meet/marco"
        )
    }

    func testLookalikeHostIsRejected() {
        // Suffix matching must require a full label boundary: `notzoom.us` is not `zoom.us`.
        let url = URL(string: "https://notzoom.us/j/123")!
        XCTAssertNil(ConferenceURLDetector.detect(url: url, notes: nil))
    }

    func testNonHTTPSchemeIsRejected() {
        let url = URL(string: "ftp://meet.google.com/abc")!
        XCTAssertNil(ConferenceURLDetector.detect(url: url, notes: nil))
    }

    // MARK: - Notes scan

    func testFirstConferenceLinkInNotesIsPicked() {
        let notes = """
        Agenda: https://example.com/doc
        Join: https://meet.google.com/abc-defg-hij
        Backup: https://zoom.us/j/123
        """
        XCTAssertEqual(
            ConferenceURLDetector.detect(url: nil, notes: notes),
            "https://meet.google.com/abc-defg-hij"
        )
    }

    func testNotesWithOnlyNonConferenceLinksYieldNil() {
        let notes = "Docs at https://example.com and https://github.com/org/repo"
        XCTAssertNil(ConferenceURLDetector.detect(url: nil, notes: notes))
    }

    func testNotesWithoutLinksYieldNil() {
        XCTAssertNil(ConferenceURLDetector.detect(url: nil, notes: "Quarterly planning, room 4"))
    }

    func testNilInputsYieldNil() {
        XCTAssertNil(ConferenceURLDetector.detect(url: nil, notes: nil))
    }

    func testAllKnownHostsAreRecognized() {
        for host in ConferenceURLDetector.knownHosts {
            let url = URL(string: "https://\(host)/whatever")!
            XCTAssertTrue(ConferenceURLDetector.isConferenceURL(url), "expected \(host) to match")
        }
    }
}
