import Combine
import XCTest
@testable import TypeWhisper

/// [Perf Phase 2 · VM split] The calendar slice owns the calendar mirrors: a calendar change fires
/// the slice's `objectWillChange`, not the view model's or the capture slice's, and vice versa.
@MainActor
final class MeetingsCalendarModelTests: XCTestCase {
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

    func testCalendarChangeFiresOnlyTheCalendarSlice() async {
        let vm = harness.viewModel
        harness.calendarProvider.eventsToReturn = [event("a", startIn: 3600)]

        var vmPublishes = 0
        var calendarPublishes = 0
        var capturePublishes = 0
        let watches = [
            vm.objectWillChange.sink { vmPublishes += 1 },
            vm.calendar.objectWillChange.sink { calendarPublishes += 1 },
            vm.capture.objectWillChange.sink { capturePublishes += 1 },
        ]

        await harness.calendarService.requestAccess()

        XCTAssertEqual(vm.calendar.calendarAuthorizationStatus, .authorized)
        XCTAssertEqual(vm.calendar.upcomingEvents.map(\.id), ["a"])
        XCTAssertEqual(vm.upcomingEvents.map(\.id), ["a"], "the VM forward reads the slice")
        XCTAssertGreaterThan(calendarPublishes, 0)
        XCTAssertEqual(vmPublishes, 0, "a calendar change must not invalidate views observing the VM")
        XCTAssertEqual(capturePublishes, 0, "nor views observing the capture slice")
        withExtendedLifetime(watches) {}
    }

    func testSelectionWriteBumpsTheRevisionOnTheSliceOnly() {
        let vm = harness.viewModel
        var vmPublishes = 0
        let watch = vm.objectWillChange.sink { vmPublishes += 1 }
        let before = vm.calendarSelectionRevision

        vm.setCalendarSelected(false, for: "cal-1")

        XCTAssertEqual(vm.calendar.calendarSelectionRevision, before + 1)
        XCTAssertEqual(vmPublishes, 0)
        withExtendedLifetime(watch) {}
    }

    func testCaptureAndViewModelChangesDoNotFireTheCalendarSlice() async throws {
        let vm = harness.viewModel
        var calendarPublishes = 0
        let watch = vm.calendar.objectWillChange.sink { calendarPublishes += 1 }

        let meeting = harness.meetingService.createMeeting(title: "Live")
        try await harness.captureService.start(meeting: meeting)
        vm.qaErrorMessage = "x"

        XCTAssertTrue(vm.capture.isCapturing)
        XCTAssertEqual(calendarPublishes, 0, "views observing only the calendar slice stay put")
        withExtendedLifetime(watch) {}
    }
}
