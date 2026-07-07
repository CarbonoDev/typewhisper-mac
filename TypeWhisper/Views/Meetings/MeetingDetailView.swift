import SwiftUI

/// Read-only view of a stored meeting: its transcript segments and notes. Live capture uses
/// `MeetingLiveCaptureView`; this is the resting state (scheduled/completed/interrupted).
struct MeetingDetailView: View {
    @ObservedObject private var viewModel = MeetingsViewModel.shared
    let meeting: Meeting

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header

                if meeting.state == .interrupted {
                    interruptedBanner
                }

                if !meeting.segments.isEmpty {
                    Divider()
                    MeetingOutputsView(meeting: meeting)
                }

                Divider()

                transcriptSection

                if !meeting.notes.isEmpty {
                    notesSection
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .toolbar {
            if viewModel.canStartCapture, meeting.state != .live {
                ToolbarItem {
                    Button {
                        Task { await viewModel.startCapture(for: meeting) }
                    } label: {
                        Label(String(localized: "meetings.capture.start"), systemImage: "record.circle")
                    }
                }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(meeting.title)
                .font(.title2)
                .bold()
            HStack(spacing: 8) {
                if let start = meeting.startDate {
                    Text(start, style: .date)
                }
                Text(meeting.state.displayName)
                    .foregroundStyle(.secondary)
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
    }

    private var interruptedBanner: some View {
        Label(String(localized: "meetings.detail.interruptedBanner"), systemImage: "exclamationmark.triangle")
            .font(.callout)
            .foregroundStyle(.orange)
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }

    private var transcriptSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "meetings.detail.transcript"))
                .font(.headline)
            let segments = meeting.segments.sorted { $0.order < $1.order }
            if segments.isEmpty {
                Text(String(localized: "meetings.detail.noTranscript"))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(segments, id: \.id) { segment in
                    HStack(alignment: .top, spacing: 8) {
                        Text(Self.timestamp(segment.start))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 56, alignment: .leading)
                        Text(segment.text)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }

    private var notesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "meetings.detail.notes"))
                .font(.headline)
            ForEach(meeting.notes.sorted { $0.createdAt < $1.createdAt }, id: \.id) { note in
                HStack(alignment: .top, spacing: 8) {
                    if let offset = note.timestampOffset {
                        Text(Self.timestamp(offset))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 56, alignment: .leading)
                    }
                    Text(note.text)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    static func timestamp(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}
