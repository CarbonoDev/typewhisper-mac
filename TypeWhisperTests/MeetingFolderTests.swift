import XCTest
@testable import TypeWhisper

// MARK: - Derived folder tree (plan D7/M4)

@MainActor
final class MeetingFolderTreeTests: XCTestCase {
    private func makeMeeting(_ folder: String?) -> Meeting {
        let meeting = Meeting(title: "M")
        meeting.folderPath = folder
        return meeting
    }

    /// Descendant-inclusive counts: a meeting under `Clients/Acme` counts toward both `Clients/Acme`
    /// and its ancestor `Clients`; siblings are separate; every level sorts by display name.
    func testTreeDescendantInclusiveCountsAndNesting() {
        let meetings = [
            makeMeeting("Clients/Acme"),
            makeMeeting("Clients/Acme"),
            makeMeeting("Clients/Globex"),
            makeMeeting("Internal")
        ]
        let tree = MeetingOrganizationIndex.folderTree(from: meetings)

        XCTAssertEqual(tree.map(\.name), ["Clients", "Internal"], "roots sorted alphabetically")
        let clients = try! XCTUnwrap(tree.first { $0.path == "Clients" })
        XCTAssertEqual(clients.count, 3, "descendant-inclusive: 2 Acme + 1 Globex")
        XCTAssertEqual(clients.children.map(\.name), ["Acme", "Globex"])
        XCTAssertEqual(clients.children.first { $0.path == "Clients/Acme" }?.count, 2)
        XCTAssertEqual(clients.children.first { $0.path == "Clients/Globex" }?.count, 1)
        XCTAssertEqual(tree.first { $0.path == "Internal" }?.count, 1)
    }

    /// Unfiled = meetings with nil/blank folder; not represented as a tree node.
    func testUnfiledCountAndExclusionFromTree() {
        let meetings = [makeMeeting(nil), makeMeeting("   "), makeMeeting("Acme")]
        XCTAssertEqual(MeetingOrganizationIndex.unfiledCount(from: meetings), 2)
        let tree = MeetingOrganizationIndex.folderTree(from: meetings)
        XCTAssertEqual(tree.map(\.path), ["Acme"])
    }

    /// Component boundaries: `Acme` and `Acme2` are distinct roots, never conflated.
    func testComponentWiseDistinctFolders() {
        let tree = MeetingOrganizationIndex.folderTree(from: [makeMeeting("Acme"), makeMeeting("Acme2")])
        XCTAssertEqual(Set(tree.map(\.path)), ["Acme", "Acme2"])
        XCTAssertEqual(tree.first { $0.path == "Acme" }?.count, 1)
    }

    /// Amendment seam: a configured-but-empty folder path (no meetings) still surfaces as a node with
    /// count 0, unioned into the derived tree.
    func testConfiguredButEmptyFolderSurfacesWithZeroCount() {
        let tree = MeetingOrganizationIndex.folderTree(
            from: [makeMeeting("Clients/Acme")],
            configuredPaths: ["Clients/Globex", "Personal"]
        )
        let clients = try! XCTUnwrap(tree.first { $0.path == "Clients" })
        XCTAssertEqual(clients.children.map(\.path), ["Clients/Acme", "Clients/Globex"])
        XCTAssertEqual(clients.children.first { $0.path == "Clients/Globex" }?.count, 0, "configured, no meetings")
        XCTAssertNotNil(tree.first { $0.path == "Personal" }, "configured root node present")
    }

    /// The index re-derives the tree when `$meetings` fires, and re-derives when the configured-paths
    /// provider is (re)assigned — the M7 union point.
    func testIndexPublishesTreeAndRebuildsOnConfiguredProvider() throws {
        let dir = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(dir) }
        let service = MeetingService(appSupportDirectory: dir)
        let index = MeetingOrganizationIndex(meetingService: service)
        XCTAssertTrue(index.folderTree.isEmpty)

        let a = service.createMeeting(title: "A")
        service.setFolder("Clients/Acme", for: a)
        XCTAssertEqual(index.folderTree.map(\.path), ["Clients"])
        XCTAssertEqual(index.unfiledCount, 0)

        index.configuredFolderPathsProvider = { ["Archive"] }
        XCTAssertEqual(Set(index.folderTree.map(\.path)), ["Clients", "Archive"])
    }
}

// MARK: - Folder mutators (plan D7)

@MainActor
final class MeetingFolderServiceTests: XCTestCase {
    /// renameFolder rewrites the prefix on the folder and all descendants, component-wise, and leaves
    /// a look-alike sibling (`Acme2`) untouched — persisted in one save.
    func testRenameFolderPrefixRewritesDescendantsOnly() throws {
        let dir = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(dir) }

        let idAcme: UUID, idChild: UUID, idOther: UUID
        do {
            let service = MeetingService(appSupportDirectory: dir)
            let acme = service.createMeeting(title: "Acme")
            let child = service.createMeeting(title: "Child")
            let other = service.createMeeting(title: "Acme2")
            idAcme = acme.id; idChild = child.id; idOther = other.id
            service.setFolder("Clients/Acme", for: acme)
            service.setFolder("Clients/Acme/Q3", for: child)
            service.setFolder("Clients/Acme2", for: other)   // look-alike, must stay put

            service.renameFolder("Clients/Acme", to: "Clients/AcmeCorp")
            XCTAssertEqual(acme.folderPath, "Clients/AcmeCorp")
            XCTAssertEqual(child.folderPath, "Clients/AcmeCorp/Q3")
            XCTAssertEqual(other.folderPath, "Clients/Acme2", "component look-alike untouched")
        }

        let reopened = MeetingService(appSupportDirectory: dir)
        XCTAssertEqual(reopened.meetings.first { $0.id == idAcme }?.folderPath, "Clients/AcmeCorp")
        XCTAssertEqual(reopened.meetings.first { $0.id == idChild }?.folderPath, "Clients/AcmeCorp/Q3")
        XCTAssertEqual(reopened.meetings.first { $0.id == idOther }?.folderPath, "Clients/Acme2")
    }

    /// moveFolder is the same component-wise prefix rewrite (re-parents a subtree).
    func testMoveFolderReparentsSubtree() throws {
        let dir = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(dir) }
        let service = MeetingService(appSupportDirectory: dir)
        let a = service.createMeeting(title: "A")
        service.setFolder("Clients/Acme", for: a)
        service.moveFolder("Clients/Acme", to: "Archive/2024/Acme")
        XCTAssertEqual(a.folderPath, "Archive/2024/Acme")
    }

    /// deleteFolder unfiles every meeting at or under the folder; look-alikes untouched.
    func testDeleteFolderUnfilesDescendants() throws {
        let dir = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(dir) }
        let service = MeetingService(appSupportDirectory: dir)
        let a = service.createMeeting(title: "A")
        let b = service.createMeeting(title: "B")
        let c = service.createMeeting(title: "C")
        service.setFolder("Clients/Acme", for: a)
        service.setFolder("Clients/Acme/Q3", for: b)
        service.setFolder("Clients/Acme2", for: c)

        service.deleteFolder("Clients/Acme")
        XCTAssertNil(a.folderPath)
        XCTAssertNil(b.folderPath)
        XCTAssertEqual(c.folderPath, "Clients/Acme2", "look-alike stays filed")
    }

    /// setFolder normalizes components (trims, collapses blanks/extra slashes); blank ⇒ nil.
    func testSetFolderNormalizes() throws {
        let dir = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(dir) }
        let service = MeetingService(appSupportDirectory: dir)
        let a = service.createMeeting(title: "A")
        service.setFolder("  Clients // Acme /  ", for: a)
        XCTAssertEqual(a.folderPath, "Clients/Acme")
        service.setFolder("   ", for: a)
        XCTAssertNil(a.folderPath)
    }

    /// Amendment seam (plan §M4 amendment): rename/move fire `onFolderPathRewrite` with the
    /// component-wise old→new pair — even when no meeting currently sits under the folder — and delete
    /// fires `onFolderDeleted`, so the future MeetingFolderMetadataStore can follow the path.
    func testFolderSeamHooksFire() throws {
        let dir = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(dir) }
        let service = MeetingService(appSupportDirectory: dir)

        var rewrites: [(String, String)] = []
        var deletes: [String] = []
        service.onFolderPathRewrite = { rewrites.append(($0, $1)) }
        service.onFolderDeleted = { deletes.append($0) }

        // No meeting under "Clients/Ghost" — the hook must still fire (configured-but-empty follow).
        service.renameFolder("Clients/Ghost", to: "Clients/Spectre")
        XCTAssertEqual(rewrites.count, 1)
        XCTAssertEqual(rewrites.first?.0, "Clients/Ghost")
        XCTAssertEqual(rewrites.first?.1, "Clients/Spectre")

        service.deleteFolder("Clients/Spectre")
        XCTAssertEqual(deletes, ["Clients/Spectre"])
    }
}

// MARK: - Pure folder filter + composition (plan D8)

@MainActor
final class MeetingFolderFilterTests: XCTestCase {
    private func makeMeeting(_ title: String, folder: String?, tags: [String] = []) -> Meeting {
        let meeting = Meeting(title: title)
        meeting.folderPath = folder
        meeting.tags = tags
        return meeting
    }

    /// Folder filter is a component prefix match — includes descendants, excludes look-alikes.
    func testInFolderPrefixByComponents() {
        let meetings = [
            makeMeeting("a", folder: "Clients/Acme"),
            makeMeeting("b", folder: "Clients/Acme/Q3"),
            makeMeeting("c", folder: "Clients/Acme2"),
            makeMeeting("d", folder: "Internal")
        ]
        let filtered = MeetingsViewModel.meetings(meetings, inFolder: "Clients/Acme")
        XCTAssertEqual(Set(filtered.map(\.title)), ["a", "b"])
    }

    /// Folder + tag compose (AND).
    func testFolderAndTagComposition() {
        let meetings = [
            makeMeeting("a", folder: "Clients/Acme", tags: ["hiring"]),
            makeMeeting("b", folder: "Clients/Acme", tags: ["roadmap"]),
            makeMeeting("c", folder: "Internal", tags: ["hiring"])
        ]
        let both = MeetingsViewModel.filteredMeetings(meetings, folder: "Clients/Acme", tag: "hiring")
        XCTAssertEqual(both.map(\.title), ["a"])

        let folderOnly = MeetingsViewModel.filteredMeetings(meetings, folder: "Clients/Acme", tag: nil)
        XCTAssertEqual(Set(folderOnly.map(\.title)), ["a", "b"])

        let tagOnly = MeetingsViewModel.filteredMeetings(meetings, folder: nil, tag: "hiring")
        XCTAssertEqual(Set(tagOnly.map(\.title)), ["a", "c"])

        let none = MeetingsViewModel.filteredMeetings(meetings, folder: nil, tag: nil)
        XCTAssertEqual(none.count, 3)
    }

    /// Folder suggestions: all tree paths (depth-first), filtered by case-insensitive substring.
    func testFolderSuggestions() {
        let tree = MeetingOrganizationIndex.folderTree(from: [
            makeMeeting("a", folder: "Clients/Acme"),
            makeMeeting("b", folder: "Internal")
        ])
        let all = MeetingsViewModel.folderSuggestions(from: tree, query: "")
        XCTAssertEqual(Set(all), ["Clients", "Clients/Acme", "Internal"])
        let acme = MeetingsViewModel.folderSuggestions(from: tree, query: "acme")
        XCTAssertEqual(acme, ["Clients/Acme"])
    }
}

// MARK: - Navigation: folder route + coordinator filter composition (plan D8)

@MainActor
final class MeetingFolderNavigationTests: XCTestCase {
    func testFolderRouteEquality() {
        XCTAssertEqual(MainWindowRoute.folder("Clients/Acme"), .folder("Clients/Acme"))
        XCTAssertNotEqual(MainWindowRoute.folder("Clients/Acme"), .folder("Clients"))
        XCTAssertNotEqual(MainWindowRoute.folder("Clients"), .tag("Clients"))
    }

    func testShowFolderSetsFilterAndPreservesTag() {
        let coordinator = MainWindowCoordinator()
        coordinator.showTag("hiring")
        coordinator.showFolder("Clients/Acme")
        XCTAssertEqual(coordinator.route, .folder("Clients/Acme"))
        XCTAssertEqual(coordinator.activeFolder, "Clients/Acme")
        XCTAssertEqual(coordinator.activeTag, "hiring", "tag preserved — folder+tag AND compose")
    }

    func testShowTagPreservesFolder() {
        let coordinator = MainWindowCoordinator()
        coordinator.showFolder("Clients/Acme")
        coordinator.showTag("hiring")
        XCTAssertEqual(coordinator.activeFolder, "Clients/Acme")
        XCTAssertEqual(coordinator.activeTag, "hiring")
    }

    func testNavigatingAwayClearsBothFilters() {
        let coordinator = MainWindowCoordinator()
        coordinator.showFolder("Clients/Acme")
        coordinator.showTag("hiring")
        coordinator.show(.home)
        XCTAssertNil(coordinator.activeFolder)
        XCTAssertNil(coordinator.activeTag)
    }

    func testClearFolderFilterKeepsTag() {
        let coordinator = MainWindowCoordinator()
        coordinator.showFolder("Clients/Acme")
        coordinator.showTag("hiring")
        coordinator.clearFolderFilter()
        XCTAssertNil(coordinator.activeFolder)
        XCTAssertEqual(coordinator.activeTag, "hiring")
        XCTAssertEqual(coordinator.route, .tag("hiring"), "route falls back to the surviving tag filter")
    }

    func testClearTagFilterKeepsFolder() {
        let coordinator = MainWindowCoordinator()
        coordinator.showFolder("Clients/Acme")
        coordinator.showTag("hiring")
        coordinator.clearTagFilter()
        XCTAssertNil(coordinator.activeTag)
        XCTAssertEqual(coordinator.activeFolder, "Clients/Acme")
        XCTAssertEqual(coordinator.route, .folder("Clients/Acme"))
    }

    func testClearAllFiltersResetsToMeetings() {
        let coordinator = MainWindowCoordinator()
        coordinator.showFolder("Clients/Acme")
        coordinator.showTag("hiring")
        coordinator.clearAllFilters()
        XCTAssertNil(coordinator.activeFolder)
        XCTAssertNil(coordinator.activeTag)
        XCTAssertEqual(coordinator.route, .meetings)
    }
}
