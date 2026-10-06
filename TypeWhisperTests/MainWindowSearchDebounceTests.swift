import Combine
import XCTest
@testable import TypeWhisper

/// [Perf 1C] The coordinator's search debounce: the field text is instant, observers see one
/// publish per typing pause, clearing is immediate, and a facet reset cancels a pending commit so a
/// stale search never lands after navigation.
@MainActor
final class MainWindowSearchDebounceTests: XCTestCase {
    private func makeCoordinator() -> MainWindowCoordinator {
        let coordinator = MainWindowCoordinator()
        coordinator.searchDebounce = .milliseconds(30)
        return coordinator
    }

    private func settle() async throws {
        try await Task.sleep(for: .milliseconds(150))
    }

    func testTypingBurstPublishesOnceWithTheLastText() async throws {
        let coordinator = makeCoordinator()
        var published: [String] = []
        let subscription = coordinator.$searchText.dropFirst().sink { published.append($0) }
        defer { subscription.cancel() }

        for prefix in ["s", "su", "sum"] {
            coordinator.setSearchText(prefix)
            XCTAssertEqual(coordinator.searchFieldText, prefix, "the field is never debounced")
        }
        XCTAssertEqual(coordinator.searchText, "", "observers have not seen the burst yet")

        try await settle()
        XCTAssertEqual(coordinator.searchText, "sum")
        XCTAssertEqual(published, ["sum"])
    }

    func testClearingAppliesImmediately() async throws {
        let coordinator = makeCoordinator()
        coordinator.setSearchText("standup")
        try await settle()
        XCTAssertEqual(coordinator.searchText, "standup")

        coordinator.setSearchText("")
        XCTAssertEqual(coordinator.searchText, "")
        XCTAssertEqual(coordinator.searchFieldText, "")
    }

    func testClearingCancelsAPendingCommit() async throws {
        let coordinator = makeCoordinator()
        coordinator.setSearchText("stand")
        coordinator.setSearchText("")
        try await settle()
        XCTAssertEqual(coordinator.searchText, "")
    }

    func testNavigatingAwayDropsAPendingSearch() async throws {
        let coordinator = makeCoordinator()
        coordinator.show(.meetings)
        coordinator.setSearchText("standup")
        coordinator.show(.home)
        XCTAssertEqual(coordinator.searchFieldText, "")

        try await settle()
        XCTAssertEqual(coordinator.searchText, "", "Home stays unfiltered (owner-veto 5)")
        XCTAssertFalse(coordinator.hasActiveFacets)
    }

    func testOpeningAMeetingStillCommitsTheTypedSearch() async throws {
        let coordinator = makeCoordinator()
        coordinator.show(.meetings)
        coordinator.setSearchText("standup")
        coordinator.openMeeting(id: UUID())

        try await settle()
        XCTAssertEqual(coordinator.searchText, "standup", "the list keeps its search on return")
    }
}
