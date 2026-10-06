import Combine
import XCTest
@testable import TypeWhisper

/// [Perf Phase 2 · VM split] The capture slice owns the capture mirrors: a capture change fires the
/// slice's `objectWillChange` and not the view model's, and the VM's forwards read the slice.
@MainActor
final class MeetingsCaptureModelTests: XCTestCase {
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

    func testCaptureErrorFiresTheSliceButNotTheViewModel() async throws {
        let vm = harness.viewModel
        let started = await vm.createAndStartAdHocCapture()
        XCTAssertNotNil(started)

        var vmPublishes = 0
        var slicePublishes = 0
        let vmWatch = vm.objectWillChange.sink { vmPublishes += 1 }
        let sliceWatch = vm.capture.objectWillChange.sink { slicePublishes += 1 }

        // While capturing, the menu entry point only sets the (slice-owned) busy message.
        _ = await vm.startMeetingRecordingFromMenu()

        XCTAssertEqual(vm.capture.captureErrorMessage, String(localized: "meetings.recording.alreadyActive"))
        XCTAssertGreaterThan(slicePublishes, 0, "the capture slice announces its own change")
        XCTAssertEqual(vmPublishes, 0, "a capture change must not invalidate views observing the VM")
        withExtendedLifetime((vmWatch, sliceWatch)) {}
    }

    func testCaptureStartFiresTheSliceAndForwardsReadIt() async throws {
        let vm = harness.viewModel
        let meeting = harness.meetingService.createMeeting(title: "Slice")

        var slicePublishes = 0
        let sliceWatch = vm.capture.objectWillChange.sink { slicePublishes += 1 }
        try await harness.captureService.start(meeting: meeting)

        XCTAssertGreaterThan(slicePublishes, 0)
        XCTAssertTrue(vm.capture.isCapturing)
        XCTAssertTrue(vm.capture.isCapturing(meetingID: meeting.id))
        XCTAssertEqual(vm.isCapturing, vm.capture.isCapturing)
        XCTAssertTrue(vm.activeMeeting === vm.capture.activeMeeting)
        withExtendedLifetime(sliceWatch) {}
    }

    func testViewModelChangeDoesNotFireTheCaptureSlice() async {
        let vm = harness.viewModel
        var slicePublishes = 0
        let sliceWatch = vm.capture.objectWillChange.sink { slicePublishes += 1 }

        // A VM-owned change (a new meeting in the library list, a transient message).
        _ = vm.createAdHocMeeting(title: "Library change")
        vm.qaErrorMessage = "x"

        XCTAssertEqual(slicePublishes, 0, "views observing only the capture slice stay put")
        withExtendedLifetime(sliceWatch) {}
    }
}
