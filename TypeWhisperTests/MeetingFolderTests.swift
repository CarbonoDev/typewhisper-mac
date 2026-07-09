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

    /// Unfiled filter selects exactly the meetings with no folder (blank/whitespace ⇒ unfiled), matching
    /// the sidebar count predicate, and composes (AND) with a tag.
    func testUnfiledFilterAndTagComposition() {
        let meetings = [
            makeMeeting("a", folder: nil, tags: ["hiring"]),
            makeMeeting("b", folder: "   ", tags: ["roadmap"]),
            makeMeeting("c", folder: "Clients/Acme", tags: ["hiring"]),
            makeMeeting("d", folder: nil)
        ]
        let unfiled = MeetingsViewModel.filteredMeetings(meetings, folder: nil, tag: nil, unfiledOnly: true)
        XCTAssertEqual(Set(unfiled.map(\.title)), ["a", "b", "d"], "blank folder counts as unfiled")

        let unfiledAndTag = MeetingsViewModel.filteredMeetings(meetings, folder: nil, tag: "hiring", unfiledOnly: true)
        XCTAssertEqual(unfiledAndTag.map(\.title), ["a"], "unfiled AND tag compose — c is filed, so excluded")

        // unfiledOnly wins over a (defensively) supplied folder — the two verticals are exclusive.
        let unfiledWins = MeetingsViewModel.filteredMeetings(meetings, folder: "Clients/Acme", tag: nil, unfiledOnly: true)
        XCTAssertEqual(Set(unfiledWins.map(\.title)), ["a", "b", "d"])

        // Default (unfiledOnly: false) is unchanged — the whole list passes through.
        XCTAssertEqual(MeetingsViewModel.filteredMeetings(meetings, folder: nil, tag: nil).count, 4)
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

    // MARK: - Unfiled vertical facet (owner request)

    func testShowUnfiledSetsFlagAndRoute() {
        let coordinator = MainWindowCoordinator()
        coordinator.showUnfiled()
        XCTAssertTrue(coordinator.unfiledOnly)
        XCTAssertEqual(coordinator.route, .unfiled)
        XCTAssertNil(coordinator.activeFolder)
    }

    func testUnfiledAndFolderAreMutuallyExclusive() {
        let coordinator = MainWindowCoordinator()
        coordinator.showUnfiled()
        coordinator.showFolder("Clients/Acme")
        XCTAssertFalse(coordinator.unfiledOnly, "selecting a folder clears unfiled")
        XCTAssertEqual(coordinator.activeFolder, "Clients/Acme")

        coordinator.showUnfiled()
        XCTAssertNil(coordinator.activeFolder, "selecting unfiled clears the folder")
        XCTAssertTrue(coordinator.unfiledOnly)
    }

    func testShowUnfiledPreservesTagAndComposes() {
        let coordinator = MainWindowCoordinator()
        coordinator.showTag("hiring")
        coordinator.showUnfiled()
        XCTAssertTrue(coordinator.unfiledOnly)
        XCTAssertEqual(coordinator.activeTag, "hiring", "tag preserved — unfiled+tag AND compose")

        // Selecting a tag while unfiled is active preserves unfiled.
        coordinator.showTag("roadmap")
        XCTAssertTrue(coordinator.unfiledOnly)
        XCTAssertEqual(coordinator.activeTag, "roadmap")
    }

    func testClearUnfiledFilterKeepsTag() {
        let coordinator = MainWindowCoordinator()
        coordinator.showUnfiled()
        coordinator.showTag("hiring")
        coordinator.clearUnfiledFilter()
        XCTAssertFalse(coordinator.unfiledOnly)
        XCTAssertEqual(coordinator.activeTag, "hiring")
        XCTAssertEqual(coordinator.route, .tag("hiring"), "route falls back to the surviving tag filter")
    }

    func testClearTagFilterKeepsUnfiled() {
        let coordinator = MainWindowCoordinator()
        coordinator.showUnfiled()
        coordinator.showTag("hiring")
        coordinator.clearTagFilter()
        XCTAssertNil(coordinator.activeTag)
        XCTAssertTrue(coordinator.unfiledOnly)
        XCTAssertEqual(coordinator.route, .unfiled, "route falls back to the surviving unfiled filter")
    }

    func testNavigatingAwayClearsUnfiled() {
        let coordinator = MainWindowCoordinator()
        coordinator.showUnfiled()
        coordinator.showTag("hiring")
        coordinator.show(.home)
        XCTAssertFalse(coordinator.unfiledOnly)
        XCTAssertNil(coordinator.activeTag)
    }
}

// MARK: - Folder page date-grouping pipeline (M12 redesign)

/// The folder detail page renders its meetings by composing the pure folder(+tag) filter with the Home
/// day-grouping (`filteredMeetings` → `homeDayGroups`). These tests pin that exact pipeline with fixed
/// dates so the meetings-first redesign groups correctly and the tag facet still composes — pure,
/// container-free, no SwiftUI.
@MainActor
final class MeetingFolderTimelineGroupingTests: XCTestCase {
    /// Fixed gregorian calendar in a stable time zone so day math is deterministic.
    private var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/New_York")!
        return cal
    }

    /// 2026-07-07 14:00 local.
    private var now: Date {
        calendar.date(from: DateComponents(year: 2026, month: 7, day: 7, hour: 14))!
    }

    private func date(daysBefore days: Int, hour: Int) -> Date {
        let day = calendar.date(byAdding: .day, value: -days, to: calendar.startOfDay(for: now))!
        return calendar.date(byAdding: .hour, value: hour, to: day)!
    }

    private func meeting(_ title: String, folder: String?, at date: Date, tags: [String] = []) -> Meeting {
        let m = Meeting(title: title, startDate: date)
        m.folderPath = folder
        m.tags = tags
        return m
    }

    /// A folder's meetings, filtered then day-grouped, land in the right day buckets (newest day first,
    /// newest-within-day first) and exclude meetings from other folders / look-alike siblings.
    func testFolderMeetingsGroupByDayNewestFirst() {
        let meetings = [
            meeting("Acme AM", folder: "Clients/Acme", at: date(daysBefore: 0, hour: 9)),
            meeting("Acme PM", folder: "Clients/Acme", at: date(daysBefore: 0, hour: 13)),
            meeting("Acme child", folder: "Clients/Acme/Q3", at: date(daysBefore: 1, hour: 10)),
            meeting("Acme old", folder: "Clients/Acme", at: date(daysBefore: 30, hour: 8)),
            meeting("Lookalike", folder: "Clients/Acme2", at: date(daysBefore: 0, hour: 11)),
            meeting("Other folder", folder: "Internal", at: date(daysBefore: 0, hour: 12)),
        ]

        let filtered = MeetingsViewModel.filteredMeetings(meetings, folder: "Clients/Acme", tag: nil)
        // Descendant-inclusive, component-boundary-safe: the Q3 child is in, Acme2/Internal are out.
        XCTAssertEqual(Set(filtered.map(\.title)), ["Acme AM", "Acme PM", "Acme child", "Acme old"])

        let groups = MeetingsViewModel.homeDayGroups(from: filtered, calendar: calendar)
        // Three days, newest first; within today the later meeting sorts first.
        XCTAssertEqual(
            groups.map { $0.meetings.map(\.title) },
            [["Acme PM", "Acme AM"], ["Acme child"], ["Acme old"]]
        )
        XCTAssertTrue(groups.map(\.date) == groups.map(\.date).sorted(by: >), "days sorted newest first")
    }

    /// The active tag facet composes (AND) before grouping: only the folder's meetings carrying the tag
    /// survive into the grouped list.
    func testFolderPlusTagComposesBeforeGrouping() {
        let meetings = [
            meeting("Tagged today", folder: "Clients/Acme", at: date(daysBefore: 0, hour: 9), tags: ["hiring"]),
            meeting("Untagged today", folder: "Clients/Acme", at: date(daysBefore: 0, hour: 10)),
            meeting("Tagged yesterday", folder: "Clients/Acme", at: date(daysBefore: 1, hour: 9), tags: ["Hiring"]),
        ]

        let filtered = MeetingsViewModel.filteredMeetings(meetings, folder: "Clients/Acme", tag: "hiring")
        let groups = MeetingsViewModel.homeDayGroups(from: filtered, calendar: calendar)
        XCTAssertEqual(
            groups.map { $0.meetings.map(\.title) },
            [["Tagged today"], ["Tagged yesterday"]],
            "case-folded tag AND folder, day-grouped"
        )
    }

    /// A folder with no matching meetings produces no groups — the page falls back to its empty state.
    func testEmptyFolderProducesNoGroups() {
        let meetings = [meeting("Elsewhere", folder: "Internal", at: date(daysBefore: 0, hour: 9))]
        let filtered = MeetingsViewModel.filteredMeetings(meetings, folder: "Clients/Acme", tag: nil)
        XCTAssertTrue(MeetingsViewModel.homeDayGroups(from: filtered, calendar: calendar).isEmpty)
    }
}
