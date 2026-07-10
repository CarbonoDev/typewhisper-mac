import XCTest
@testable import TypeWhisper

/// LX-1 — Meetings-list multi-select (plan D3). Pure tests for selection normalization on filter
/// change and the ⌘/⇧-click gesture math. No SwiftUI; the view wiring calls these same statics.
@MainActor
final class MeetingListSelectionTests: XCTestCase {
    // MARK: - Normalization (History's "normalize, don't nuke")

    func testNormalizedSelectionKeepsVisibleDropsHidden() {
        let a = UUID(), b = UUID(), c = UUID()
        let selection: Set<UUID> = [a, b, c]
        let visible = [a, c] // b is now filtered out
        XCTAssertEqual(MeetingsViewModel.normalizedSelection(selection, toVisibleIDs: visible), [a, c])
    }

    func testNormalizedSelectionKeepsStillVisiblePicks() {
        let a = UUID(), b = UUID()
        // Nothing hidden → selection unchanged.
        XCTAssertEqual(MeetingsViewModel.normalizedSelection([a, b], toVisibleIDs: [a, b]), [a, b])
    }

    func testNormalizedSelectionEmptyWhenNothingVisible() {
        let a = UUID(), b = UUID()
        XCTAssertTrue(MeetingsViewModel.normalizedSelection([a, b], toVisibleIDs: []).isEmpty)
    }

    // MARK: - Gesture math

    private let ids = (0..<5).map { _ in UUID() }

    func testReplaceSelectsOnlyTheClickedRowAndSetsAnchor() {
        let result = MeetingsViewModel.SelectionGesture.apply(
            click: .replace, on: ids[2], selection: [ids[0], ids[4]], anchor: ids[0], orderedIDs: ids
        )
        XCTAssertEqual(result.selection, [ids[2]])
        XCTAssertEqual(result.anchor, ids[2])
    }

    func testToggleAddsAndRemovesAndMovesAnchor() {
        let added = MeetingsViewModel.SelectionGesture.apply(
            click: .toggle, on: ids[1], selection: [ids[0]], anchor: ids[0], orderedIDs: ids
        )
        XCTAssertEqual(added.selection, [ids[0], ids[1]])
        XCTAssertEqual(added.anchor, ids[1])

        let removed = MeetingsViewModel.SelectionGesture.apply(
            click: .toggle, on: ids[1], selection: [ids[0], ids[1]], anchor: ids[0], orderedIDs: ids
        )
        XCTAssertEqual(removed.selection, [ids[0]])
        XCTAssertEqual(removed.anchor, ids[1])
    }

    func testRangeSelectsContiguousSpanFromAnchorInclusiveEitherDirection() {
        // Anchor at index 1, click index 3 → span [1,2,3], unioned onto existing.
        let forward = MeetingsViewModel.SelectionGesture.apply(
            click: .range, on: ids[3], selection: [ids[1]], anchor: ids[1], orderedIDs: ids
        )
        XCTAssertEqual(forward.selection, [ids[1], ids[2], ids[3]])
        XCTAssertEqual(forward.anchor, ids[1], "anchor unchanged so repeated ⇧-clicks re-extend")

        // Reverse direction spans the same inclusive block.
        let backward = MeetingsViewModel.SelectionGesture.apply(
            click: .range, on: ids[0], selection: [], anchor: ids[2], orderedIDs: ids
        )
        XCTAssertEqual(backward.selection, [ids[0], ids[1], ids[2]])
    }

    func testRangeUnionPreservesPriorPicks() {
        // A prior ⌘-click selected ids[4]; a ⇧-click range must not drop it.
        let result = MeetingsViewModel.SelectionGesture.apply(
            click: .range, on: ids[2], selection: [ids[0], ids[4]], anchor: ids[0], orderedIDs: ids
        )
        XCTAssertEqual(result.selection, [ids[0], ids[1], ids[2], ids[4]])
    }

    func testRangeWithoutAnchorDegradesToReplace() {
        let result = MeetingsViewModel.SelectionGesture.apply(
            click: .range, on: ids[2], selection: [ids[0]], anchor: nil, orderedIDs: ids
        )
        XCTAssertEqual(result.selection, [ids[2]])
        XCTAssertEqual(result.anchor, ids[2])
    }

    func testSelectAllReturnsEveryVisibleID() {
        XCTAssertEqual(MeetingsViewModel.SelectionGesture.selectAll(ids), Set(ids))
    }
}
