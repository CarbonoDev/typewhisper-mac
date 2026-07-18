import XCTest
@testable import TypeWhisper

/// Track E (ME-1) — the pure Space sidebar-highlight predicates. Asserts route-equality highlight
/// and that Space folder/note selection is **disjoint** from the first-party `.folder`/`.tag`
/// families (plan D5/V7). SwiftUI-free.
@MainActor
final class SpaceSelectionTests: XCTestCase {

    // MARK: - Space folder highlight

    func testSpaceFolderSelectedOnMatchingRoute() {
        XCTAssertTrue(SpaceSelection.isSpaceFolderSelected(
            "Meetings/Acme", route: .spaceFolder("Meetings/Acme")))
        // Normalized on both sides: a trailing slash still matches.
        XCTAssertTrue(SpaceSelection.isSpaceFolderSelected(
            "Meetings/Acme", route: .spaceFolder("Meetings/Acme/")))
        XCTAssertFalse(SpaceSelection.isSpaceFolderSelected(
            "Meetings/Acme", route: .spaceFolder("Meetings/Acme2")),
            "component-distinct siblings must not match")
    }

    func testSpaceFolderNotSelectedOnOtherRouteFamilies() {
        let path = "Meetings/Acme"
        for route: MainWindowRoute in [
            .home, .meetings, .meeting(UUID()),
            .folder("Meetings/Acme"), .tag("acme"), .unfiled,
            .spaceNote("Meetings/Acme"),
        ] {
            XCTAssertFalse(SpaceSelection.isSpaceFolderSelected(path, route: route),
                           "space folder must not highlight for \(route)")
        }
    }

    // MARK: - Space note highlight

    func testSpaceNoteSelectedOnMatchingRoute() {
        XCTAssertTrue(SpaceSelection.isSpaceNoteSelected(
            "Meetings/Acme/Roadmap.md", route: .spaceNote("Meetings/Acme/Roadmap.md")))
        XCTAssertFalse(SpaceSelection.isSpaceNoteSelected(
            "Meetings/Acme/Roadmap.md", route: .spaceNote("Meetings/Acme/Other.md")))
    }

    func testSpaceNoteNotSelectedOnOtherRouteFamilies() {
        let path = "Meetings/Acme/Roadmap.md"
        for route: MainWindowRoute in [
            .home, .meetings, .folder("Meetings/Acme"), .tag("acme"),
            .spaceFolder("Meetings/Acme/Roadmap.md"),
        ] {
            XCTAssertFalse(SpaceSelection.isSpaceNoteSelected(path, route: route),
                           "space note must not highlight for \(route)")
        }
    }

    // MARK: - Disjoint families (a first-party folder never lights a Space row)

    func testFirstPartyFolderRouteDoesNotSelectSpace() {
        let route: MainWindowRoute = .folder("Meetings/Acme")
        XCTAssertFalse(SpaceSelection.isSpaceFolderSelected("Meetings/Acme", route: route))
        XCTAssertFalse(SpaceSelection.isSpaceNoteSelected("Meetings/Acme", route: route))
    }
}
