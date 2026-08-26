import SwiftUI

/// The prominent "recording now" banner at the top of the Home feed while a meeting is being
/// captured (plan Track C / D6). Reads the existing `isCapturing` / `activeMeeting` /
/// `captureElapsedSeconds` published state; clicking it routes to the live meeting document via the
/// shared coordinator. Renders nothing when no capture is active.
struct HomeLiveBanner: View {
    @ObservedObject private var viewModel = MeetingsViewModel.shared
    @ObservedObject private var coordinator = MainWindowCoordinator.shared

    var body: some View {
        // Stay visible across both the live span and the post-Stop "finalizing" span (the off-main
        // teardown), so Home reflects that the meeting is still being wrapped up.
        if viewModel.isCapturing || viewModel.isFinalizing, let active = viewModel.activeMeeting {
            let finalizing = viewModel.isFinalizing
            Button {
                coordinator.openMeeting(id: active.id)
            } label: {
                HStack(spacing: 12) {
                    if finalizing {
                        ProgressView().controlSize(.regular)
                    } else {
                        Image(systemName: "record.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.red)
                            .symbolEffect(.pulse, options: .repeating)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(finalizing
                            ? String(localized: "meetingdoc.finalizing")
                            : String(localized: "home.live.recording"))
                            .font(.caption)
                            .textCase(.uppercase)
                            .foregroundStyle(finalizing ? Color.secondary : Color.red)
                        Text(active.title)
                            .font(.headline)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    if !finalizing {
                        Text(LiveRecordingBand.elapsedString(viewModel.captureElapsedSeconds))
                            .font(.title3)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(MeetingTheme.s4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    (finalizing ? Color.secondary : Color.red).opacity(0.08),
                    in: RoundedRectangle(cornerRadius: MeetingTheme.cardRadius)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: MeetingTheme.cardRadius)
                        .stroke((finalizing ? Color.secondary : Color.red).opacity(0.25), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(String(localized: "home.live.accessibility")))
        }
    }
}
