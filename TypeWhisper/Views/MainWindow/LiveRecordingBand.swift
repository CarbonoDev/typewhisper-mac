import SwiftUI

/// Sidebar band shown while a meeting is being captured (UI Step 0, D3). Reads the existing
/// `isCapturing` / `activeMeeting` / `captureElapsedSeconds` published state; clicking it routes to
/// the live meeting document. Renders nothing when no capture is active.
struct LiveRecordingBand: View {
    @ObservedObject private var viewModel = MeetingsViewModel.shared
    @ObservedObject private var coordinator = MainWindowCoordinator.shared

    var body: some View {
        if viewModel.isCapturing, let active = viewModel.activeMeeting {
            Button {
                coordinator.openMeeting(id: active.id)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "record.circle")
                        .foregroundStyle(.red)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(active.title)
                            .lineLimit(1)
                            .font(.callout)
                        Text(Self.elapsedString(viewModel.captureElapsedSeconds))
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.red.opacity(0.08))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(String(localized: "mainwindow.liveBand.accessibility")))
        }
    }

    static func elapsedString(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%d:%02d", m, s)
    }
}
