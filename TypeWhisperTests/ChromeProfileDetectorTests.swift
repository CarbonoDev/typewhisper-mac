import XCTest
@testable import TypeWhisper

/// [Join links] Pure `Local State` parsing + the auto-match rule over fixture JSON — no real
/// filesystem (the file-read seam is exercised only through its miss path with a nonexistent URL).
final class ChromeProfileDetectorTests: XCTestCase {
    private func data(_ json: String) -> Data {
        Data(json.utf8)
    }

    // MARK: - Parsing

    func testParsesProfilesWithEmailAndDisplayNameSortedByDirectory() {
        let fixture = """
        {
          "profile": {
            "info_cache": {
              "Profile 2": { "name": "Work", "user_name": "marco@simbiosis.team" },
              "Default": { "name": "Marco", "user_name": "marco@gmail.com" },
              "Profile 10": { "name": "Testing", "user_name": "" }
            },
            "last_used": "Default"
          },
          "browser": { "enabled_labs_experiments": [] }
        }
        """

        let profiles = ChromeProfileDetector.profiles(fromLocalStateData: data(fixture))

        // localizedStandardCompare: "Default" first, then numerically "Profile 2" < "Profile 10".
        XCTAssertEqual(profiles.map(\.directory), ["Default", "Profile 2", "Profile 10"])
        XCTAssertEqual(profiles.map(\.displayName), ["Marco", "Work", "Testing"])
        // Empty `user_name` reads as no signed-in email.
        XCTAssertEqual(profiles.map(\.email), ["marco@gmail.com", "marco@simbiosis.team", nil])
    }

    func testMissingNameFallsBackToDirectoryAndMissingKeysAreTolerated() {
        let fixture = """
        {
          "profile": {
            "info_cache": {
              "Profile 1": { "user_name": "a@x.com" },
              "Profile 2": { "name": "" }
            }
          }
        }
        """

        let profiles = ChromeProfileDetector.profiles(fromLocalStateData: data(fixture))

        XCTAssertEqual(profiles.map(\.displayName), ["Profile 1", "Profile 2"])
        XCTAssertEqual(profiles.map(\.email), ["a@x.com", nil])
    }

    func testMalformedOrEmptyPayloadsYieldEmptyList() {
        XCTAssertTrue(ChromeProfileDetector.profiles(fromLocalStateData: data("not json")).isEmpty)
        XCTAssertTrue(ChromeProfileDetector.profiles(fromLocalStateData: Data()).isEmpty)
        // Valid JSON, wrong shapes.
        XCTAssertTrue(ChromeProfileDetector.profiles(fromLocalStateData: data("[]")).isEmpty)
        XCTAssertTrue(ChromeProfileDetector.profiles(fromLocalStateData: data("{}")).isEmpty)
        XCTAssertTrue(ChromeProfileDetector.profiles(fromLocalStateData: data(#"{"profile": {}}"#)).isEmpty)
        XCTAssertTrue(ChromeProfileDetector.profiles(fromLocalStateData: data(#"{"profile": {"info_cache": 7}}"#)).isEmpty)
        // An entry whose value is not a dictionary is skipped, not fatal.
        let mixed = #"{"profile": {"info_cache": {"Default": {"name": "A"}, "Broken": 3}}}"#
        XCTAssertEqual(ChromeProfileDetector.profiles(fromLocalStateData: data(mixed)).map(\.directory), ["Default"])
    }

    func testMissingLocalStateFileYieldsEmptyList() {
        let missing = URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString)/Local State")
        XCTAssertTrue(ChromeProfileDetector.detectProfiles(localStateURL: missing).isEmpty)
    }

    // MARK: - Auto-match (case-insensitive, unique-only)

    private func profile(_ directory: String, email: String?) -> ChromeProfile {
        ChromeProfile(directory: directory, email: email, displayName: directory)
    }

    func testAutoMatchFindsTheSingleCaseInsensitiveMatch() {
        let profiles = [
            profile("Default", email: "other@gmail.com"),
            profile("Profile 2", email: "Marco@Simbiosis.Team")
        ]
        let match = ChromeProfileDetector.autoMatch(profiles: profiles, accountEmail: "marco@simbiosis.team")
        XCTAssertEqual(match?.directory, "Profile 2")
    }

    func testAutoMatchReturnsNilOnZeroMatches() {
        let profiles = [profile("Default", email: "other@gmail.com"), profile("Profile 2", email: nil)]
        XCTAssertNil(ChromeProfileDetector.autoMatch(profiles: profiles, accountEmail: "marco@simbiosis.team"))
        XCTAssertNil(ChromeProfileDetector.autoMatch(profiles: [], accountEmail: "marco@simbiosis.team"))
        XCTAssertNil(ChromeProfileDetector.autoMatch(profiles: profiles, accountEmail: ""))
    }

    func testAutoMatchReturnsNilOnAmbiguousMatches() {
        // Two profiles signed into the same account — never silently pick one.
        let profiles = [
            profile("Default", email: "marco@simbiosis.team"),
            profile("Profile 2", email: "MARCO@simbiosis.team")
        ]
        XCTAssertNil(ChromeProfileDetector.autoMatch(profiles: profiles, accountEmail: "marco@simbiosis.team"))
    }
}
