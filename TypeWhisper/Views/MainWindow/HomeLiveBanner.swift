import SwiftUI

/// The prominent "recording now" banner at the top of the Home feed while a meeting is being
/// captured (plan Track C / D6). Reads the existing `isCapturing` / `activeMeeting` /
/// `captureElapsedSeconds` published state; clicking it routes to the live meeting document via the
/// shared coordinator. Renders nothing when no capture is active.
struct HomeLiveBanner: View {
    @ObservedObject private var viewModel = MeetingsViewModel.shared
    @ObservedObject private var coordinator = MainWindowCoordinator.shared

    var body: some View {
        if viewModel.isCapturing, let active = viewModel.activeMeeting {
            Button {
                coordinator.openMeeting(id: active.id)
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "record.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.red)
                        .symbolEffect(.pulse, options: .repeating)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(String(localized: "home.live.recording"))
                            .font(.caption)
                            .textCase(.uppercase)
                            .foregroundStyle(.red)
                        Text(active.title)
                            .font(.headline)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    Text(LiveRecordingBand.elapsedString(viewModel.captureElapsedSeconds))
                        .font(.title3)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.red.opacity(0.25), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(String(localized: "home.live.accessibility")))
        }
    }
}
