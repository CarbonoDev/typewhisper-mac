import SwiftUI

/// The prominent "recording now" banner at the top of the Home feed while a meeting is being
/// captured (plan Track C / D6). Reads the existing `isCapturing` / `activeMeeting` /
/// `captureClock` tick; clicking it routes to the live meeting document via the
/// shared coordinator. Renders nothing when no capture is active.
struct HomeLiveBanner: View {
    // [VM split] Reads only capture state: observes the capture slice, not the whole view model.
    @ObservedObject private var capture = MeetingsViewModel.shared.capture
    @ObservedObject private var coordinator = MainWindowCoordinator.shared

    var body: some View {
        // Stay visible across both the live span and the post-Stop "finalizing" span (the off-main
        // teardown), so Home reflects that the meeting is still being wrapped up.
        if capture.isCapturing || capture.isFinalizing, let active = capture.activeMeeting {
            let finalizing = capture.isFinalizing
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
                        CaptureElapsedText(format: LiveRecordingBand.elapsedString)
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
