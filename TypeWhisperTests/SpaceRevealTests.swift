import XCTest
@testable import TypeWhisper

/// Track E (ME-2) — the pure meeting↔Space bridge seams. `SpaceReveal.route` computes the
/// folder-precise "Reveal in Space" destination (gated on a prior export, sanitized and root-aligned
/// to mirror the exporter); `SpaceReveal.linkedMeeting` resolves a Space note's parsed backlink to an
/// existing meeting. Both are pure — no vault, view, or coordinator.
final class SpaceRevealTests: XCTestCase {

    // MARK: - route

    func testRouteNilWhenNeverExported() {
        XCTAssertNil(SpaceReveal.route(rootFolder: "Meetings", meetingFolder: "Clients/Acme", hasExported: false))
    }

    func testRouteIsFolderPreciseAndRootAligned() {
        let route = SpaceReveal.route(rootFolder: "Meetings", meetingFolder: "Clients/Acme", hasExported: true)
        XCTAssertEqual(route, .spaceFolder("Meetings/Clients/Acme"))
    }

    func testRouteWithEmptyRootUsesMeetingFolderOnly() {
        XCTAssertEqual(
            SpaceReveal.route(rootFolder: "", meetingFolder: "Acme", hasExported: true),
            .spaceFolder("Acme"))
    }

    func testRouteWithEmptyRootAndNoFolderIsSpaceRoot() {
        XCTAssertEqual(
            SpaceReveal.route(rootFolder: "", meetingFolder: nil, hasExported: true),
            .spaceFolder(""))
    }

    /// Illegal filename characters are stripped exactly as the exporter sanitizes folder components,
    /// so the reveal lands on the folder that was actually written.
    func testRouteSanitizesIllegalComponents() {
        XCTAssertEqual(
            SpaceReveal.route(rootFolder: "Meetings", meetingFolder: "Cli:ents/Ac*me", hasExported: true),
            .spaceFolder("Meetings/Clients/Acme"))
    }

    // MARK: - linkedMeeting

    func testLinkedMeetingNilForNoBacklink() {
        XCTAssertNil(SpaceReveal.linkedMeeting(uuid: nil, existingMeetingIDs: [UUID()]))
    }

    func testLinkedMeetingNilForUnknownUUID() {
        XCTAssertNil(SpaceReveal.linkedMeeting(uuid: UUID(), existingMeetingIDs: [UUID(), UUID()]))
    }

    func testLinkedMeetingResolvesExistingUUID() {
        let id = UUID()
        XCTAssertEqual(SpaceReveal.linkedMeeting(uuid: id, existingMeetingIDs: [UUID(), id]), id)
    }
}
