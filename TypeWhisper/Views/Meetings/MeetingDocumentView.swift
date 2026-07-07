import SwiftUI

/// Step 0 placeholder for the single-meeting document (UI Step 0, D4). Frozen contract:
/// `MeetingDocumentView(meeting:)`. This thin wrapper preserves today's behavior — live capture vs.
/// resting detail — so the main window is whole from the first merge. Track B replaces this file
/// **wholesale** with the real lifecycle document (header + state-switched body + transcript panel +
/// bottom bar); because the shell references only the type name, that replacement has zero
/// line-level conflicts.
struct MeetingDocumentView: View {
    @ObservedObject private var viewModel = MeetingsViewModel.shared
    let meeting: Meeting

    var body: some View {
        if meeting.id == viewModel.activeMeeting?.id, viewModel.isCapturing {
            MeetingLiveCaptureView(meeting: meeting)
        } else {
            MeetingDetailView(meeting: meeting)
        }
    }
}
