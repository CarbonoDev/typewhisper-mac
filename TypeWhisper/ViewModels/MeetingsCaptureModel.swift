import Combine
import Foundation

/// [Perf Phase 2 · VM split] The live-capture slice of `MeetingsViewModel`: the capture service's
/// state mirrored for views, on its own `ObservableObject` so a capture flag flipping re-renders only
/// the views that observe this slice (live band, home banner, transcript panel, document chrome,
/// list/timeline live markers) instead of every observer of the singleton view model.
///
/// Owned by `MeetingsViewModel` as `capture` (a plain `let`); the VM forwards the old property names
/// as computed properties. Writes still go through `MeetingCaptureService` — this object only
/// mirrors it, plus `captureErrorMessage`, which the VM's capture actions also set.
/// See `docs/specs/2026-10-06-meetings-vm-split.md`.
@MainActor
final class MeetingsCaptureModel: ObservableObject {
    @Published private(set) var activeMeeting: Meeting?
    @Published private(set) var isCapturing = false
    /// True while `stop()`'s off-MainActor teardown is finalizing this meeting (recorder mixdown,
    /// audio adopt). Mirrored from the capture service so the live band and the document bottom bar
    /// show a "Finalizing…" posture the instant Stop is pressed, without the window freezing.
    @Published private(set) var isFinalizing = false
    @Published private(set) var isDegradedLiveMode = false
    /// Mirrors `MeetingCaptureService.errorMessage`; also written by the VM's capture actions
    /// (start failure, "already recording"), which is why the setter is internal.
    @Published var captureErrorMessage: String?
    // [Track C] AD8 final re-transcription degradation, mirrored from the capture service so the
    // detail view can surface a status (never an error dialog) when a meeting's final pass ran in a
    // reduced mode. `finalRetranscriptionDegradedMeetingID` scopes the banner to the affected meeting.
    @Published private(set) var finalRetranscriptionDegraded = false
    @Published private(set) var finalRetranscriptionDegradedMeetingID: UUID?

    private var cancellables = Set<AnyCancellable>()

    init(captureService: MeetingCaptureService) {
        activeMeeting = captureService.activeMeeting
        isCapturing = captureService.isCapturing
        isFinalizing = captureService.isFinalizing
        isDegradedLiveMode = captureService.isDegradedLiveMode
        captureErrorMessage = captureService.errorMessage
        finalRetranscriptionDegraded = captureService.finalRetranscriptionDegraded
        finalRetranscriptionDegradedMeetingID = captureService.finalRetranscriptionDegradedMeetingID

        // Capture state mirrors are synchronous, so they equal the service's flags at every await
        // point (`MeetingsViewModelMirrorTests`). `activeMeeting` compares by object identity:
        // `Meeting` equality is by persistent id, and a refetched instance must still replace the old one.
        captureService.$activeMeeting
            .sink { [weak self] meeting in
                guard let self, self.activeMeeting !== meeting else { return }
                self.activeMeeting = meeting
            }
            .store(in: &cancellables)
        captureService.$isCapturing.mirror(to: self, \.isCapturing).store(in: &cancellables)
        captureService.$isFinalizing.mirror(to: self, \.isFinalizing).store(in: &cancellables)
        captureService.$isDegradedLiveMode.mirror(to: self, \.isDegradedLiveMode).store(in: &cancellables)
        captureService.$finalRetranscriptionDegraded
            .mirror(to: self, \.finalRetranscriptionDegraded).store(in: &cancellables)
        captureService.$finalRetranscriptionDegradedMeetingID
            .mirror(to: self, \.finalRetranscriptionDegradedMeetingID).store(in: &cancellables)
        captureService.$errorMessage.mirror(to: self, \.captureErrorMessage).store(in: &cancellables)
    }

    /// Whether `meetingID` is the meeting currently being captured.
    func isCapturing(meetingID: UUID) -> Bool {
        isCapturing && activeMeeting?.id == meetingID
    }

    /// Whether `meetingID` is the meeting whose capture is currently finalizing.
    func isFinalizing(meetingID: UUID) -> Bool {
        isFinalizing && activeMeeting?.id == meetingID
    }
}
