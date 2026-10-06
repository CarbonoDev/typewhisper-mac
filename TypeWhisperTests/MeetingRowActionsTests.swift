import XCTest
@testable import TypeWhisper

/// [Perf Phase 2] Row menus record a pending action on the list's `MeetingRowActions`, which the
/// list presents once. These pin the recorded targets and the draft text the dialogs start from.
@MainActor
final class MeetingRowActionsTests: XCTestCase {
    func testRenameStartsFromTheCurrentTitle() {
        let meeting = Meeting(title: "Weekly sync")
        let actions = MeetingRowActions(meetingSource: { [meeting] })
        actions.beginRename(meeting.id)
        XCTAssertEqual(actions.pending, .rename(meeting.id))
        XCTAssertEqual(actions.draftText, "Weekly sync")
    }

    func testTargetsResolveInOrderAndSkipVanishedMeetings() {
        let a = Meeting(title: "A"), b = Meeting(title: "B")
        let actions = MeetingRowActions(meetingSource: { [a, b] })
        XCTAssertEqual(actions.meetings(for: [b.id, UUID(), a.id]).map(\.id), [b.id, a.id])
    }

    func testNewFolderStartsEmptyAndKeepsTargets() {
        let actions = MeetingRowActions(meetingSource: { [] })
        let ids = [UUID(), UUID()]
        actions.draftText = "leftover"
        actions.beginNewFolder(ids)
        XCTAssertEqual(actions.pending, .newFolder(ids))
        XCTAssertEqual(actions.draftText, "")
    }

    func testPendingAccessorsMatchOnlyTheirCase() {
        let id = UUID()
        XCTAssertEqual(MeetingRowPendingAction.rename(id).renameID, id)
        XCTAssertNil(MeetingRowPendingAction.rename(id).linkEventID)
        XCTAssertEqual(MeetingRowPendingAction.delete([id]).deleteIDs, [id])
        XCTAssertNil(MeetingRowPendingAction.delete([id]).mergeIDs)
        XCTAssertEqual(MeetingRowPendingAction.merge([id]).mergeIDs, [id])
        XCTAssertEqual(MeetingRowPendingAction.newFolder([id]).newFolderIDs, [id])
        XCTAssertEqual(MeetingRowPendingAction.linkEvent(id).linkEventID, id)
        XCTAssertNil(MeetingRowPendingAction.linkEvent(id).renameID)
    }
}
