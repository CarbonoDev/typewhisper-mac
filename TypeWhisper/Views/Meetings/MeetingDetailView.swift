import SwiftUI

/// Read-only view of a stored meeting: its transcript segments and notes. Live capture uses
/// `MeetingLiveCaptureView`; this is the resting state (scheduled/completed/interrupted).
struct MeetingDetailView: View {
    @ObservedObject private var viewModel = MeetingsViewModel.shared
    let meeting: Meeting

    /// Whether speaker identification can run (loaded async; nil while probing). Drives whether the
    /// "Identify speakers" action is shown (plan M9: hidden when the sidecar is unavailable).
    @State private var diarizationAvailability: MeetingDiarizationEnricher.Availability?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header

                if meeting.state == .interrupted {
                    interruptedBanner
                }

                // AD8: the final re-transcription for this meeting degraded to a safer path
                // (unavailable override engine or an oversized cloud pass). Surfaced as a status,
                // never an error dialog — the live-stabilized transcript was kept.
                if viewModel.finalRetranscriptionDegradedMeetingID == meeting.id {
                    finalPassDegradedBanner
                }

                // Pre-meeting brief (M5): available regardless of whether a transcript exists yet,
                // since it draws on prior meetings and the knowledge base, not this meeting's audio.
                Divider()
                MeetingBriefView(meeting: meeting)

                if !meeting.segments.isEmpty {
                    Divider()
                    MeetingOutputsView(meeting: meeting)

                    // In-meeting Q&A (M6): ask against this meeting's transcript + knowledge base.
                    Divider()
                    MeetingQAView(meeting: meeting)
                }

                Divider()

                transcriptSection

                if !meeting.segments.isEmpty {
                    Divider()
                    diarizationSection
                }

                if !meeting.notes.isEmpty {
                    notesSection
                }

                // Obsidian export (M7): available once the meeting has anything worth exporting.
                if hasExportableContent {
                    Divider()
                    MeetingExportView(meeting: meeting)
                        .id(meeting.id)
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

    private var finalPassDegradedBanner: some View {
        Label(String(localized: "meetings.finalPass.degradedStatus"), systemImage: "wifi.exclamationmark")
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
                let speakerMap = meeting.speakerMap
                ForEach(segments, id: \.id) { segment in
                    HStack(alignment: .top, spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(Self.timestamp(segment.start))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                            // Distinguish merged-in imported content from live capture (M8: sources
                            // must be distinguishable in the UI).
                            if segment.source != .liveCapture {
                                Text(String(localized: "meetings.detail.importedTag"))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 1)
                                    .background(.secondary.opacity(0.15), in: Capsule())
                            }
                        }
                        .frame(width: 56, alignment: .leading)
                        VStack(alignment: .leading, spacing: 2) {
                            if let speaker = Self.speakerName(for: segment, speakerMap: speakerMap) {
                                Text(speaker)
                                    .font(.caption.bold())
                                    .foregroundStyle(.secondary)
                            }
                            Text(segment.text)
                                .textSelection(.enabled)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }

    // MARK: - Speaker diarization (M9)

    private var hasSpeakerLabels: Bool {
        meeting.segments.contains { ($0.speakerLabel?.isEmpty == false) }
    }

    @ViewBuilder
    private var diarizationSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(String(localized: "meetings.diarization.title"))
                    .font(.headline)
                Spacer()
                identifyButton
            }

            if let status = viewModel.diarizationStatusMessage {
                Label(status, systemImage: "info.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if let error = viewModel.diarizationErrorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }

            if hasSpeakerLabels {
                SpeakerMappingView(meeting: meeting)
            }
        }
        .task(id: meeting.id) {
            diarizationAvailability = await viewModel.diarizationAvailability(for: meeting)
        }
    }

    @ViewBuilder
    private var identifyButton: some View {
        // Hidden entirely while the feature is unavailable (no audio / no sidecar) — plan M9/D8.
        if let availability = diarizationAvailability, availability != .unavailable {
            Button {
                Task { await viewModel.identifySpeakers(for: meeting) }
            } label: {
                if viewModel.isEnriching {
                    ProgressView().controlSize(.small)
                } else {
                    Label(String(localized: "meetings.diarization.identify"), systemImage: "person.wave.2")
                }
            }
            .disabled(viewModel.isEnriching)
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

    private var hasExportableContent: Bool {
        !meeting.segments.isEmpty || !meeting.outputs.isEmpty || !meeting.notes.isEmpty
    }

    static func timestamp(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    /// The display speaker for a segment: its raw `SPEAKER_xx` label resolved through the meeting's
    /// speaker map (plan M9), or the raw label when unmapped, or nil when the segment is unlabeled.
    static func speakerName(for segment: MeetingSegment, speakerMap: [String: String]) -> String? {
        guard let label = segment.speakerLabel?.trimmingCharacters(in: .whitespacesAndNewlines),
              !label.isEmpty else { return nil }
        if let mapped = speakerMap[label]?.trimmingCharacters(in: .whitespacesAndNewlines), !mapped.isEmpty {
            return mapped
        }
        return label
    }
}
