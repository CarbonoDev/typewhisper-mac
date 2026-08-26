import XCTest
@testable import TypeWhisper

/// Plan M5 (sidebar IA finalization) — the pure sidebar highlight mapping. Asserts that Home,
/// Meetings, Folder, and Tag rows select consistently across every route type, and that folders and
/// tags highlight independently so they stay lit together under folder+tag AND composition (D8).
/// SwiftUI-free: exercises `SidebarSelection`'s static contract directly.
@MainActor
final class SidebarSelectionTests: XCTestCase {

    // MARK: - Home / Meetings destinations (mutually exclusive with filtered routes)

    func testHomeSelectedOnlyOnHome() {
        XCTAssertTrue(SidebarSelection.isHomeSelected(route: .home))
        for route: MainWindowRoute in [.meetings, .meeting(UUID()), .tag("hiring"), .folder("Clients")] {
            XCTAssertFalse(SidebarSelection.isHomeSelected(route: route), "Home must not highlight for \(route)")
        }
    }

    func testMeetingsSelectedForListAndDocumentButNotFilteredRoutes() {
        XCTAssertTrue(SidebarSelection.isMeetingsSelected(route: .meetings))
        XCTAssertTrue(SidebarSelection.isMeetingsSelected(route: .meeting(UUID())),
                      "a single meeting document lives under Meetings")
        // A folder/tag route highlights its own sidebar row, not Meetings.
        XCTAssertFalse(SidebarSelection.isMeetingsSelected(route: .tag("hiring")))
        XCTAssertFalse(SidebarSelection.isMeetingsSelected(route: .folder("Clients")))
        XCTAssertFalse(SidebarSelection.isMeetingsSelected(route: .home))
    }

    // MARK: - Folder rows

    func testFolderSelectedMatchesActiveFolderNormalized() {
        XCTAssertTrue(SidebarSelection.isFolderSelected("Clients/Acme", activeFolder: "Clients/Acme"))
        // Normalized on both sides: extra slashes / surrounding whitespace still match.
        XCTAssertTrue(SidebarSelection.isFolderSelected("Clients/Acme", activeFolder: " Clients / Acme /"))
        XCTAssertFalse(SidebarSelection.isFolderSelected("Clients/Acme", activeFolder: "Clients"))
        XCTAssertFalse(SidebarSelection.isFolderSelected("Clients/Acme2", activeFolder: "Clients/Acme"),
                       "component-distinct siblings must not match")
        XCTAssertFalse(SidebarSelection.isFolderSelected("Clients/Acme", activeFolder: nil))
    }

    // MARK: - Unfiled row (owner request)

    func testUnfiledSelectedTracksFlag() {
        XCTAssertTrue(SidebarSelection.isUnfiledSelected(unfiledOnly: true))
        XCTAssertFalse(SidebarSelection.isUnfiledSelected(unfiledOnly: false))
        // Unfiled is a vertical filter, not a destination: a `.meeting` route opened from the unfiled
        // list keeps it lit (via the persisted flag) without lighting Home.
        XCTAssertFalse(SidebarSelection.isHomeSelected(route: .unfiled))
        XCTAssertFalse(SidebarSelection.isMeetingsSelected(route: .unfiled),
                       "the Unfiled row highlights itself, not Meetings")
    }

    func testUnfiledAndTagHighlightIndependently() {
        // Unfiled + a tag: the Unfiled row and the tag row are both lit; neither folder, Home, nor
        // Meetings is (unfiled and folder are mutually exclusive verticals).
        XCTAssertTrue(SidebarSelection.isUnfiledSelected(unfiledOnly: true))
        XCTAssertTrue(SidebarSelection.isTagSelected("hiring", activeTag: "Hiring"))
        XCTAssertFalse(SidebarSelection.isFolderSelected("Clients", activeFolder: nil))
    }

    // MARK: - Tag rows (case-folded)

    func testTagSelectedIsCaseFolded() {
        XCTAssertTrue(SidebarSelection.isTagSelected("hiring", activeTag: "Hiring"))
        XCTAssertTrue(SidebarSelection.isTagSelected("hiring", activeTag: "hiring"))
        XCTAssertFalse(SidebarSelection.isTagSelected("hiring", activeTag: "recruiting"))
        XCTAssertFalse(SidebarSelection.isTagSelected("hiring", activeTag: nil))
    }

    // MARK: - Folder + tag compose (both rows lit at once, no single winner)

    func testFolderAndTagHighlightIndependentlyUnderAndComposition() {
        // The coordinator is on the `.folder` route with a tag also active: the folder row *and* the
        // tag row are both selected, and neither Home nor Meetings is.
        let route: MainWindowRoute = .folder("Clients/Acme")
        let activeFolder: String? = "Clients/Acme"
        let activeTag: String? = "Hiring"

        XCTAssertTrue(SidebarSelection.isFolderSelected("Clients/Acme", activeFolder: activeFolder))
        XCTAssertTrue(SidebarSelection.isTagSelected("hiring", activeTag: activeTag))
        XCTAssertFalse(SidebarSelection.isMeetingsSelected(route: route))
        XCTAssertFalse(SidebarSelection.isHomeSelected(route: route))
    }
}
