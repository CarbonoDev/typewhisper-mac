import Combine
import XCTest
@testable import TypeWhisper

/// [Perf Phase 2] The list selection lives on `MeetingSelectionModel`, off `MeetingsViewModel`.
/// Deleted and merged-away meetings leave it through normalization to the visible set.
@MainActor
final class MeetingSelectionModelTests: XCTestCase {
    func testNormalizeDropsHiddenIDsAndPublishesOnlyOnChange() {
        let model = MeetingSelectionModel()
        let a = UUID(), b = UUID(), c = UUID()
        model.ids = [a, b]
        var publishes = 0
        let subscription = model.$ids.dropFirst().sink { _ in publishes += 1 }
        defer { subscription.cancel() }

        model.normalize(toVisibleIDs: [a, b, c])
        XCTAssertEqual(publishes, 0, "an unchanged selection does not republish")

        model.normalize(toVisibleIDs: [a, c])
        XCTAssertEqual(model.ids, [a])
        XCTAssertEqual(publishes, 1)
    }

    func testVisibleSelectionAndSelectedMeetingsFollowListOrder() {
        let model = MeetingSelectionModel()
        let first = Meeting(title: "First"), second = Meeting(title: "Second"), third = Meeting(title: "Third")
        model.ids = [third.id, first.id, UUID()]

        XCTAssertEqual(model.visibleSelection(in: [first.id, second.id]), [first.id])
        XCTAssertEqual(model.selectedMeetings(in: [first, second, third]).map(\.id), [first.id, third.id])
    }

    func testMergeCollapsesSelectionToTheSurvivorThroughNormalization() async throws {
        let directory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(directory) }
        let service = MeetingService(appSupportDirectory: directory)
        let a = service.createMeeting(title: "Sync", source: .adHoc)
        let b = service.createMeeting(title: "Sync", source: .adHoc)
        let model = MeetingSelectionModel()
        model.ids = [a.id, b.id]

        let merged = await MeetingMergeService(meetingService: service).merge([a, b], willAbsorb: { _ in })
        let survivor = try XCTUnwrap(merged)

        model.normalize(toVisibleIDs: service.meetings.map(\.id))
        XCTAssertEqual(model.ids, [survivor.id])
    }
}
