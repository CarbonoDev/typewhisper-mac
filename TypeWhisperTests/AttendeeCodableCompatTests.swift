import XCTest
@testable import TypeWhisper

/// `Attendee` is persisted as a Codable JSON blob on `Meeting` (`attendeesJSON`), so the M3 field
/// additions (`isOrganizer`, `responseStatusRaw`) must decode old payloads to `nil` — the same
/// additive-optional precedent as `isSelf` (spec §4).
final class AttendeeCodableCompatTests: XCTestCase {
    func testOldPayloadWithoutNewKeysDecodesWithNils() throws {
        let old = #"{"name": "Ada Lovelace", "email": "ada@example.com"}"#
        let attendee = try JSONDecoder().decode(Attendee.self, from: Data(old.utf8))
        XCTAssertEqual(attendee.name, "Ada Lovelace")
        XCTAssertEqual(attendee.email, "ada@example.com")
        XCTAssertNil(attendee.isSelf)
        XCTAssertNil(attendee.isOrganizer)
        XCTAssertNil(attendee.responseStatusRaw)
        XCTAssertNil(attendee.responseStatus)
    }

    func testRoundTripWithNewFields() throws {
        let original = Attendee(
            name: "Grace Hopper",
            email: "grace@example.com",
            isSelf: true,
            isOrganizer: true,
            responseStatusRaw: "accepted"
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Attendee.self, from: data)
        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.isOrganizer, true)
        XCTAssertEqual(decoded.responseStatusRaw, "accepted")
        XCTAssertEqual(decoded.responseStatus, .accepted)
    }

    func testResponseStatusMappingAndUnknownRawValue() {
        XCTAssertEqual(Attendee(name: "A", responseStatusRaw: "accepted").responseStatus, .accepted)
        XCTAssertEqual(Attendee(name: "A", responseStatusRaw: "declined").responseStatus, .declined)
        XCTAssertEqual(Attendee(name: "A", responseStatusRaw: "tentative").responseStatus, .tentative)
        XCTAssertEqual(Attendee(name: "A", responseStatusRaw: "needsAction").responseStatus, .needsAction)
        XCTAssertNil(
            Attendee(name: "A", responseStatusRaw: "somethingNew").responseStatus,
            "unrecognized raw values read as unknown but round-trip losslessly through the raw field"
        )
    }
}
