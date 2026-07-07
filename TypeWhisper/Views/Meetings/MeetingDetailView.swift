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

                // AD8: per-meeting final re-transcription override. Only meaningful before the final
                // pass runs (at stop), so it is offered only while the meeting is still scheduled or
                // live; a completed meeting's transcript is already produced.
                if meeting.state == .scheduled || meeting.state == .live {
                    Divider()
                    MeetingFinalRetranscriptionOverrideView(meeting: meeting)
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

/// [Track C] Per-meeting override for the final (post-stop) re-transcription (addendum AD8). Adds an
/// "inherit" option on top of the global picker's three modes: `.inherit` (nil) defers to the matched
/// rule → global default → `.sameEngine`, so an unconfigured meeting behaves exactly as before.
private struct MeetingFinalRetranscriptionOverrideView: View {
    @ObservedObject private var viewModel = MeetingsViewModel.shared
    let meeting: Meeting

    /// The four choices offered per meeting; `.inherit` maps to a nil persisted override.
    private enum Mode: Hashable {
        case inherit
        case off
        case sameEngine
        case engine
    }

    private var current: FinalRetranscriptionPolicy? {
        viewModel.finalRetranscriptionOverride(for: meeting)
    }

    private var currentEngineId: String? {
        if case .engine(let id, _) = current { return id }
        return nil
    }

    private var currentModel: String? {
        if case .engine(_, let model) = current { return model }
        return nil
    }

    private var mode: Binding<Mode> {
        Binding(
            get: {
                switch current {
                case .none: return .inherit
                case .off: return .off
                case .sameEngine: return .sameEngine
                case .engine: return .engine
                }
            },
            set: { newMode in
                switch newMode {
                case .inherit:
                    viewModel.setFinalRetranscriptionOverride(nil, for: meeting)
                case .off:
                    viewModel.setFinalRetranscriptionOverride(.off, for: meeting)
                case .sameEngine:
                    viewModel.setFinalRetranscriptionOverride(.sameEngine, for: meeting)
                case .engine:
                    let firstEngine = viewModel.transcriptionEngineOptions.first?.id ?? ""
                    viewModel.setFinalRetranscriptionOverride(
                        .engine(id: currentEngineId ?? firstEngine, model: currentModel),
                        for: meeting
                    )
                }
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "meetings.finalPass.perMeeting.title"))
                .font(.headline)
            Text(String(localized: "meetings.finalPass.perMeeting.subtitle"))
                .font(.caption)
                .foregroundStyle(.secondary)

            Picker(String(localized: "meetings.finalPass.mode.label"), selection: mode) {
                Text(String(localized: "meetings.finalPass.perMeeting.inherit")).tag(Mode.inherit)
                Text(String(localized: "meetings.finalPass.mode.off")).tag(Mode.off)
                Text(String(localized: "meetings.finalPass.mode.sameEngine")).tag(Mode.sameEngine)
                Text(String(localized: "meetings.finalPass.mode.engine")).tag(Mode.engine)
            }
            .pickerStyle(.radioGroup)

            if mode.wrappedValue == .engine {
                enginePicker
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var enginePicker: some View {
        let engineBinding = Binding<String>(
            get: { currentEngineId ?? viewModel.transcriptionEngineOptions.first?.id ?? "" },
            set: { viewModel.setFinalRetranscriptionOverride(.engine(id: $0, model: currentModel), for: meeting) }
        )
        let modelBinding = Binding<String>(
            get: { currentModel ?? "" },
            set: { newValue in
                let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                viewModel.setFinalRetranscriptionOverride(
                    .engine(
                        id: currentEngineId ?? viewModel.transcriptionEngineOptions.first?.id ?? "",
                        model: trimmed.isEmpty ? nil : trimmed
                    ),
                    for: meeting
                )
            }
        )
        return VStack(alignment: .leading, spacing: 6) {
            Picker(String(localized: "meetings.finalPass.engine"), selection: engineBinding) {
                ForEach(viewModel.transcriptionEngineOptions, id: \.id) { option in
                    Text(option.name).tag(option.id)
                }
            }
            TextField(String(localized: "meetings.finalPass.model"), text: modelBinding)
                .textFieldStyle(.roundedBorder)
        }
        .padding(.leading, 16)
    }
}
