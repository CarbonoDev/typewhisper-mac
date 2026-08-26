import XCTest
@testable import TypeWhisper

// MARK: - Derived tag index (plan D6/M3)

@MainActor
final class MeetingOrganizationIndexTests: XCTestCase {
    /// Pure derivation: counts by case-folded key, dedupes within a meeting, sorted by display name.
    func testTagCountsCaseFoldAndCountAcrossMeetings() throws {
        let dir = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(dir) }
        let service = MeetingService(appSupportDirectory: dir)

        let a = service.createMeeting(title: "A")
        let b = service.createMeeting(title: "B")
        let c = service.createMeeting(title: "C")
        service.setObsidianTags(["Hiring", "q3"], for: a)
        service.setObsidianTags(["hiring"], for: b)   // case-variant of Hiring
        service.setObsidianTags(["Q3", "roadmap"], for: c)

        let counts = MeetingOrganizationIndex.tagCounts(from: service.meetings)
        let byKey = Dictionary(uniqueKeysWithValues: counts.map { ($0.key, $0) })

        XCTAssertEqual(byKey["hiring"]?.count, 2, "case-folded Hiring/hiring count together")
        XCTAssertEqual(byKey["q3"]?.count, 2, "case-folded q3/Q3 count together")
        XCTAssertEqual(byKey["roadmap"]?.count, 1)
        // Display name is one of the original casings present for that key (which exact casing wins is
        // the fetch order — an implementation detail; the key is the stable case-folded grouping).
        XCTAssertEqual(byKey["hiring"]?.name.lowercased(), "hiring")
        XCTAssertEqual(byKey["q3"]?.name.lowercased(), "q3")
        // Sorted alphabetically (case-insensitive) by display name.
        XCTAssertEqual(counts.map(\.key), ["hiring", "q3", "roadmap"])
    }

    /// A single meeting carrying two case-variants of the same tag counts once.
    func testTagDedupedWithinAMeeting() throws {
        let dir = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(dir) }
        let service = MeetingService(appSupportDirectory: dir)
        let a = service.createMeeting(title: "A")
        // setObsidianTags dedupes exact strings but keeps case variants, so both persist.
        service.setObsidianTags(["Hiring", "hiring"], for: a)

        let counts = MeetingOrganizationIndex.tagCounts(from: service.meetings)
        XCTAssertEqual(counts.count, 1)
        XCTAssertEqual(counts.first?.count, 1, "one meeting counts once regardless of case variants")
    }

    /// The index republishes when `MeetingService.$meetings` fires (a tag edit refreshes counts).
    func testIndexRefreshesOnMeetingsChange() throws {
        let dir = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(dir) }
        let service = MeetingService(appSupportDirectory: dir)
        let index = MeetingOrganizationIndex(meetingService: service)
        XCTAssertTrue(index.tagCounts.isEmpty)

        let a = service.createMeeting(title: "A")
        service.setObsidianTags(["hiring"], for: a)
        XCTAssertEqual(index.tagCounts.map(\.key), ["hiring"])
        XCTAssertEqual(index.tagCounts.first?.count, 1)

        let b = service.createMeeting(title: "B")
        service.setObsidianTags(["hiring", "roadmap"], for: b)
        XCTAssertEqual(index.tagCounts.map(\.key), ["hiring", "roadmap"])
        XCTAssertEqual(index.tagCounts.first { $0.key == "hiring" }?.count, 2)
    }
}

// MARK: - Bulk tag mutators (plan D6)

@MainActor
final class MeetingTagServiceTests: XCTestCase {
    func testRenameTagAffectsEveryMeetingAndPersists() throws {
        let dir = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(dir) }

        let idA: UUID
        let idB: UUID
        do {
            let service = MeetingService(appSupportDirectory: dir)
            let a = service.createMeeting(title: "A")
            let b = service.createMeeting(title: "B")
            let c = service.createMeeting(title: "C")
            idA = a.id
            idB = b.id
            service.setObsidianTags(["hiring", "q3"], for: a)
            service.setObsidianTags(["Hiring"], for: b)   // case-variant still renamed
            service.setObsidianTags(["roadmap"], for: c)  // untouched

            service.renameTag("hiring", to: "recruiting")
            XCTAssertEqual(Set(a.tags), ["recruiting", "q3"])
            XCTAssertEqual(b.tags, ["recruiting"])
            XCTAssertEqual(c.tags, ["roadmap"], "unrelated meeting untouched")
        }

        // Reopen: the single save persisted every affected meeting.
        let reopened = MeetingService(appSupportDirectory: dir)
        let a = try XCTUnwrap(reopened.meetings.first { $0.id == idA })
        let b = try XCTUnwrap(reopened.meetings.first { $0.id == idB })
        XCTAssertTrue(a.tags.contains("recruiting"))
        XCTAssertFalse(a.tags.contains { $0.lowercased() == "hiring" })
        XCTAssertEqual(b.tags, ["recruiting"])
    }

    /// Renaming a tag onto one a meeting already carries merges (no case-variant twin).
    func testRenameMergesOntoExistingTag() throws {
        let dir = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(dir) }
        let service = MeetingService(appSupportDirectory: dir)
        let a = service.createMeeting(title: "A")
        service.setObsidianTags(["hiring", "recruiting"], for: a)

        service.renameTag("hiring", to: "Recruiting")
        // Only one recruiting-ish tag survives (case-insensitive dedupe keeps the first occurrence).
        XCTAssertEqual(a.tags.filter { $0.lowercased() == "recruiting" }.count, 1)
        XCTAssertEqual(a.tags.count, 1)
    }

    func testDeleteTagRemovesEverywhere() throws {
        let dir = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(dir) }
        let service = MeetingService(appSupportDirectory: dir)
        let a = service.createMeeting(title: "A")
        let b = service.createMeeting(title: "B")
        service.setObsidianTags(["hiring", "q3"], for: a)
        service.setObsidianTags(["Hiring"], for: b)

        service.deleteTag("hiring")
        XCTAssertEqual(a.tags, ["q3"])
        XCTAssertTrue(b.tags.isEmpty, "case-variant removed too")
        XCTAssertNil(MeetingOrganizationIndex.tagCounts(from: service.meetings).first { $0.key == "hiring" })
    }

    func testRenameNoOpWhenTagAbsentOrTargetBlank() throws {
        let dir = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(dir) }
        let service = MeetingService(appSupportDirectory: dir)
        let a = service.createMeeting(title: "A")
        service.setObsidianTags(["hiring"], for: a)

        service.renameTag("missing", to: "x")
        XCTAssertEqual(a.tags, ["hiring"])
        service.renameTag("hiring", to: "   ")
        XCTAssertEqual(a.tags, ["hiring"], "blank target is a no-op")
    }
}

// MARK: - Pure filter + autocomplete (plan D8)

@MainActor
final class MeetingTagFilterTests: XCTestCase {
    private func makeMeeting(_ tags: [String]) -> Meeting {
        let meeting = Meeting(title: "M")
        meeting.tags = tags
        return meeting
    }

    func testTaggedWithIsCaseFoldedMembership() {
        let a = makeMeeting(["hiring", "q3"])
        let b = makeMeeting(["Hiring"])
        let c = makeMeeting(["roadmap"])
        let filtered = MeetingsViewModel.meetings([a, b, c], taggedWith: "HIRING")
        XCTAssertEqual(Set(filtered.map(\.title)), ["M"])
        XCTAssertEqual(filtered.count, 2, "both case variants match; roadmap excluded")
    }

    func testTagSuggestionsExcludeMeetingTagsAndFilterByQuery() {
        let counts = [
            MeetingTagCount(key: "hiring", name: "hiring", count: 3),
            MeetingTagCount(key: "roadmap", name: "roadmap", count: 2),
            MeetingTagCount(key: "q3", name: "q3", count: 1)
        ]
        let meeting = makeMeeting(["hiring"])
        let all = MeetingsViewModel.tagSuggestions(from: counts, query: "", excluding: meeting)
        XCTAssertEqual(all, ["roadmap", "q3"], "hiring already on meeting is excluded")

        let filtered = MeetingsViewModel.tagSuggestions(from: counts, query: "road", excluding: meeting)
        XCTAssertEqual(filtered, ["roadmap"])
    }
}

// MARK: - Navigation: tag route + coordinator filter (plan D8)

@MainActor
final class MeetingTagNavigationTests: XCTestCase {
    func testTagRouteEquality() {
        XCTAssertEqual(MainWindowRoute.tag("hiring"), .tag("hiring"))
        XCTAssertNotEqual(MainWindowRoute.tag("hiring"), .tag("q3"))
        XCTAssertNotEqual(MainWindowRoute.tag("hiring"), .meetings)
    }

    func testShowTagSetsFilterAndRoute() {
        let coordinator = MainWindowCoordinator()
        coordinator.showTag("hiring")
        XCTAssertEqual(coordinator.route, .tag("hiring"))
        XCTAssertEqual(coordinator.activeTag, "hiring")
    }

    func testNavigatingAwayClearsTagFilter() {
        let coordinator = MainWindowCoordinator()
        coordinator.showTag("hiring")
        coordinator.show(.meetings)
        XCTAssertNil(coordinator.activeTag)
        coordinator.showTag("q3")
        coordinator.show(.home)
        XCTAssertNil(coordinator.activeTag)
    }

    func testClearTagFilterReturnsToMeetings() {
        let coordinator = MainWindowCoordinator()
        coordinator.showTag("hiring")
        coordinator.clearTagFilter()
        XCTAssertEqual(coordinator.route, .meetings)
        XCTAssertNil(coordinator.activeTag)
    }
}
