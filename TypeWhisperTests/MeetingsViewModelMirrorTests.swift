import Combine
import XCTest
@testable import TypeWhisper

/// [Perf · finding 12] The `MeetingsViewModel` service mirrors land synchronously (no main-queue hop)
/// and publish only on change.
@MainActor
final class MeetingsViewModelMirrorTests: XCTestCase {
    private var harness: MeetingsViewModelHarness!

    override func setUp() async throws {
        try await super.setUp()
        harness = try MeetingsViewModelHarness()
    }

    override func tearDown() async throws {
        await harness.tearDown()
        harness = nil
        try await super.tearDown()
    }

    private func event(_ id: String, startIn: TimeInterval) -> CalendarEventDTO {
        CalendarEventDTO(
            id: id, title: id,
            startDate: Date().addingTimeInterval(startIn),
            endDate: Date().addingTimeInterval(startIn + 1800),
            isAllDay: false, attendees: []
        )
    }

    func testCalendarMirrorsLandWithoutARunLoopTurn() async {
        let vm = harness.viewModel
        harness.calendarProvider.eventsToReturn = [event("a", startIn: 3600)]
        XCTAssertEqual(vm.calendarAuthorizationStatus, .notDetermined)

        await harness.calendarService.requestAccess()
        // Read straight after the service's writes — a `receive(on: .main)` hop would still be queued.
        XCTAssertEqual(vm.calendarAuthorizationStatus, .authorized)
        XCTAssertEqual(vm.upcomingEvents.map(\.id), ["a"])
        XCTAssertTrue(vm.isCalendarAuthorized)
    }

    func testUnchangedCalendarRefreshDoesNotRepublishTheViewModel() async {
        let vm = harness.viewModel
        harness.calendarProvider.eventsToReturn = [event("a", startIn: 3600)]
        await harness.calendarService.requestAccess()

        var publishes = 0
        let watch = vm.objectWillChange.sink { publishes += 1 }
        harness.calendarService.refresh(now: Date())
        XCTAssertEqual(publishes, 0, "an equal window must not invalidate views observing the VM")
        withExtendedLifetime(watch) {}
    }

    /// Read straight after `start()` / `stop()` return — the continuation runs in the same main-actor
    /// job as the service's last writes, so a `receive(on: .main)` mirror would still be stale here.
    /// This is the window the double-start guards used to dodge by reading the service directly.
    func testCaptureMirrorsAreCurrentWhenStartAndStopReturn() async throws {
        let vm = harness.viewModel
        let capture = harness.captureService
        let meeting = harness.meetingService.createMeeting(title: "Sync")

        try await capture.start(meeting: meeting)
        XCTAssertTrue(vm.isCapturing)
        XCTAssertTrue(vm.activeMeeting === meeting)
        XCTAssertEqual(vm.isCapturing, capture.isCapturing)

        await capture.stop()
        XCTAssertEqual(vm.isCapturing, capture.isCapturing)
        XCTAssertEqual(vm.isFinalizing, capture.isFinalizing)
        XCTAssertTrue(vm.activeMeeting === capture.activeMeeting)
    }
}
