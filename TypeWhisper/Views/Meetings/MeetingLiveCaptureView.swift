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
                sidePane
                    .frame(width: 320)
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

    /// The right column: in-meeting notes above the live Q&A chat pane (plan M6). Each half keeps
    /// its own scroll region — `MeetingNotesPane` already scrolls its list internally, so it is not
    /// nested inside another ScrollView (which would collapse it to zero height).
    private var sidePane: some View {
        VStack(alignment: .leading, spacing: 0) {
            MeetingNotesPane(meeting: meeting)
                .padding()
                .frame(maxHeight: .infinity)
            Divider()
            ScrollView {
                MeetingQAView(meeting: meeting)
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .frame(maxHeight: .infinity)
        }
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
