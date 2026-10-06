import Combine
import XCTest
@testable import TypeWhisper

/// [Perf Phase 2 · VM split] The outputs slice owns templates, the Q&A in-flight set and the
/// operation messages: a change there fires only the slice, and other slices' changes do not fire it.
@MainActor
final class MeetingsOutputsModelTests: XCTestCase {
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

    func testOperationMessageFiresOnlyTheOutputsSlice() {
        let vm = harness.viewModel
        var vmPublishes = 0
        var outputsPublishes = 0
        var capturePublishes = 0
        var calendarPublishes = 0
        let watches = [
            vm.objectWillChange.sink { vmPublishes += 1 },
            vm.outputs.objectWillChange.sink { outputsPublishes += 1 },
            vm.capture.objectWillChange.sink { capturePublishes += 1 },
            vm.calendar.objectWillChange.sink { calendarPublishes += 1 },
        ]

        vm.qaErrorMessage = "failed"
        vm.exportErrorMessage = "failed"

        XCTAssertEqual(vm.outputs.qaErrorMessage, "failed", "the VM forward writes the slice")
        XCTAssertEqual(vm.exportErrorMessage, "failed")
        XCTAssertGreaterThan(outputsPublishes, 0)
        XCTAssertEqual(vmPublishes, 0, "an operation message must not invalidate views observing the VM")
        XCTAssertEqual(capturePublishes, 0)
        XCTAssertEqual(calendarPublishes, 0)
        withExtendedLifetime(watches) {}
    }

    func testClearTransientMessagesClearsTheSliceAndIsSilentWhenEmpty() {
        let vm = harness.viewModel
        vm.outputErrorMessage = "x"
        vm.diarizationStatusMessage = "y"
        vm.clearTransientMessages()
        XCTAssertNil(vm.outputs.outputErrorMessage)
        XCTAssertNil(vm.outputs.diarizationStatusMessage)

        var outputsPublishes = 0
        let watch = vm.outputs.objectWillChange.sink { outputsPublishes += 1 }
        vm.clearTransientMessages()
        XCTAssertEqual(outputsPublishes, 0, "a navigation with nothing to clear publishes nothing")
        withExtendedLifetime(watch) {}
    }

    func testCaptureAndCalendarChangesDoNotFireTheOutputsSlice() async throws {
        let vm = harness.viewModel
        var outputsPublishes = 0
        let watch = vm.outputs.objectWillChange.sink { outputsPublishes += 1 }

        await harness.calendarService.requestAccess()
        let meeting = harness.meetingService.createMeeting(title: "Live")
        try await harness.captureService.start(meeting: meeting)

        XCTAssertTrue(vm.capture.isCapturing)
        XCTAssertEqual(outputsPublishes, 0, "views observing only the outputs slice stay put")
        withExtendedLifetime(watch) {}
    }
}
