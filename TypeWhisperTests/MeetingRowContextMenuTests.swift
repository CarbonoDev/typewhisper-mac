import XCTest
@testable import TypeWhisper

/// LX-2 — the pure single-vs-multi menu-mode selector and count-aware delete confirmation (plan LX-2,
/// D4). Mirrors `HistoryView.recordContextMenu(for:)`: a right-click shows the bulk menu only when the
/// row is inside a **multi**-selection (`count > 1` AND the id is selected); every other case is the
/// single-row menu. No SwiftUI — the two row surfaces call these same statics.
@MainActor
final class MeetingRowContextMenuTests: XCTestCase {
    private let a = UUID(), b = UUID(), c = UUID()

    // MARK: - Menu mode

    func testModeIsSingleWhenSelectionEmpty() {
        XCTAssertEqual(
            MeetingsViewModel.contextMenuMode(rightClicked: a, selection: []),
            .single
        )
    }

    func testModeIsSingleWhenRightClickOutsideMultiSelection() {
        // b and c are selected; right-clicking a (not in the selection) acts on a alone.
        XCTAssertEqual(
            MeetingsViewModel.contextMenuMode(rightClicked: a, selection: [b, c]),
            .single
        )
    }

    func testModeIsSingleForLoneSelectionEvenWhenItContainsTheRow() {
        // A single-item selection is not "multi" — the single menu, exactly like HistoryView.
        XCTAssertEqual(
            MeetingsViewModel.contextMenuMode(rightClicked: a, selection: [a]),
            .single
        )
    }

    func testModeIsBulkWithCountWhenRightClickInsideMultiSelection() {
        XCTAssertEqual(
            MeetingsViewModel.contextMenuMode(rightClicked: a, selection: [a, b, c]),
            .bulk(count: 3)
        )
    }

    // MARK: - Delete confirmation counting

    func testDeleteConfirmationCountIsOneForSingle() {
        XCTAssertEqual(MeetingsViewModel.deleteConfirmationCount(rightClicked: a, selection: []), 1)
        XCTAssertEqual(MeetingsViewModel.deleteConfirmationCount(rightClicked: a, selection: [a]), 1)
        XCTAssertEqual(MeetingsViewModel.deleteConfirmationCount(rightClicked: a, selection: [b, c]), 1)
    }

    func testDeleteConfirmationCountIsSelectionSizeForBulk() {
        XCTAssertEqual(MeetingsViewModel.deleteConfirmationCount(rightClicked: a, selection: [a, b]), 2)
        XCTAssertEqual(MeetingsViewModel.deleteConfirmationCount(rightClicked: a, selection: [a, b, c]), 3)
    }
}
