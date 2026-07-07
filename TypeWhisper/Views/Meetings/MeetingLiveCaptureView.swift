import SwiftUI

/// Live capture surface for the active meeting: streaming transcript preview, elapsed time, a
/// reduced-quality indicator when running the windowed fallback (plan D18), the notes pane, and a
/// Stop control that finalizes the transcript + audio.
struct MeetingLiveCaptureView: View {
    @ObservedObject private var viewModel = MeetingsViewModel.shared
    let meeting: Meeting

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            captureHeader
            Divider()
            HStack(alignment: .top, spacing: 0) {
                transcriptPane
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                MeetingNotesPane(meeting: meeting)
                    .frame(width: 300)
                    .padding()
            }
        }
    }

    private var captureHeader: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(meeting.title)
                    .font(.headline)
                HStack(spacing: 8) {
                    Label(MeetingDetailView.timestamp(viewModel.captureElapsedSeconds), systemImage: "record.circle")
                        .foregroundStyle(.red)
                        .font(.subheadline.monospacedDigit())
                    if viewModel.isDegradedLiveMode {
                        Label(String(localized: "meetings.capture.reducedQuality"), systemImage: "wifi.exclamationmark")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            }
            Spacer()
            Button {
                Task { await viewModel.stopCapture() }
            } label: {
                Label(String(localized: "meetings.capture.stop"), systemImage: "stop.circle")
            }
            .keyboardShortcut(".", modifiers: [.command])
        }
        .padding()
    }

    private var transcriptPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text(String(localized: "meetings.detail.transcript"))
                    .font(.headline)
                if viewModel.liveTranscript.isEmpty {
                    Text(String(localized: "meetings.capture.listening"))
                        .foregroundStyle(.secondary)
                } else {
                    Text(viewModel.liveTranscript)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }
}
