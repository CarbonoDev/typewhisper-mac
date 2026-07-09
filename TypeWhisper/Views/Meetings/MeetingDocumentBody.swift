import SwiftUI

/// [Track B] The state-switched body of the meeting document (plan D4). Retires the old
/// `MeetingLiveCaptureView` ↔ `MeetingDetailView` branch into one screen:
/// - `.scheduledEmpty` — pre-meeting brief, an "import a transcript" affordance (owner requirement
///   #2), and the per-meeting final re-transcription override.
/// - `.liveNotes` — editable, timeline-stamped notes plus in-meeting Q&A.
/// - `.renderedOutput` — the selected output rendered as markdown, generate affordances, brief,
///   Q&A, speaker diarization / mapping, and notes. The merge-into-this-meeting entry point now
///   lives in the header chip row (`MeetingDocumentHeader.importChip`) so it is discoverable on any
///   meeting with a transcript or completed state, not buried at the bottom of the document.
struct MeetingDocumentBody: View {
    @ObservedObject private var viewModel = MeetingsViewModel.shared
    // [Track J] Observe the queue directly so the meeting-scoped "Identify speakers" spinner reacts to
    // `.diarization` job state (the VM no longer mirrors `isEnriching` — plan J2 §CC7).
    @ObservedObject private var jobQueue = JobQueueService.shared
    @ObservedObject var model: MeetingDocumentModel
    let meeting: Meeting
    let presentation: MeetingsViewModel.DocumentPresentation

    var body: some View {
        switch presentation.bodyMode {
        case .scheduledEmpty:
            scheduledEmptyBody
        case .liveNotes:
            liveNotesBody
        case .renderedOutput:
            renderedOutputBody
        }
    }

    // MARK: - Scheduled / empty

    private var scheduledEmptyBody: some View {
        VStack(alignment: .leading, spacing: 20) {
            MeetingBriefView(meeting: meeting)

            Divider()
            MeetingRelatedDocsSection(meeting: meeting)

            Divider()
            importAffordance

            if meeting.state == .scheduled || meeting.state == .live {
                Divider()
                MeetingFinalRetranscriptionOverrideView(meeting: meeting)
            }
        }
    }

    /// Owner requirement #2: an "import transcript or audio" affordance in the empty / scheduled
    /// state ("Have a transcript? Import it").
    private var importAffordance: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "meetingdoc.import.prompt.title"))
                .font(.headline)
            Text(String(localized: "meetingdoc.import.prompt.message"))
                .font(.callout)
                .foregroundStyle(.secondary)
            Button {
                model.isPresentingImport = true
            } label: {
                Label(String(localized: "meetingdoc.import.prompt.button"), systemImage: "square.and.arrow.down")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Live capture

    private var liveNotesBody: some View {
        VStack(alignment: .leading, spacing: 20) {
            MeetingNotesPane(meeting: meeting)
            Divider()
            MeetingQAView(meeting: meeting)
        }
    }

    // MARK: - Rendered output (stopped / completed)

    private var renderedOutputBody: some View {
        VStack(alignment: .leading, spacing: 20) {
            outputSection

            Divider()
            MeetingBriefView(meeting: meeting)

            Divider()
            MeetingRelatedDocsSection(meeting: meeting)

            if !meeting.segments.isEmpty {
                Divider()
                MeetingQAView(meeting: meeting)

                Divider()
                SpeakerSection(meeting: meeting)
            }

            if !meeting.notes.isEmpty {
                Divider()
                notesSection
            }

            // The per-meeting final-pass override still matters for a scheduled meeting that already
            // carries an imported transcript, and for a stopped-but-resumable one (state .live) — the
            // final pass runs at the next stop. Collapsed so it doesn't dominate the rendered document.
            if meeting.state == .scheduled || meeting.state == .live {
                Divider()
                DisclosureGroup(String(localized: "meetingdoc.finalPass.disclosure")) {
                    MeetingFinalRetranscriptionOverrideView(meeting: meeting)
                        .padding(.top, 8)
                }
                .font(.headline)
            }
        }
    }

    @ViewBuilder
    private var outputSection: some View {
        let latest = viewModel.latestOutput(ofKind: model.selectedOutputKind, for: meeting)
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(MeetingsViewModel.outputKindLabel(model.selectedOutputKind))
                    .font(.title3.bold())
                Spacer()
                if let latest, let provenance = Self.provenance(for: latest) {
                    Text(provenance)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            // Re-hosted from the retired MeetingOutputsView: let the user fold in-meeting notes into
            // (or out of) generated outputs. Only meaningful when the meeting actually has notes;
            // MeetingLLMService reads meeting.notesIncludedInOutputs at generation time.
            if !meeting.notes.isEmpty {
                Toggle(isOn: notesIncludedBinding) {
                    Text(String(localized: "meetings.output.includeNotes"))
                        .font(.caption)
                }
                .toggleStyle(.checkbox)
            }

            if let error = viewModel.outputErrorMessage {
                VStack(alignment: .leading, spacing: 4) {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)

                    if viewModel.outputErrorNeedsProvider {
                        Button(String(localized: "meetings.error.selectProvider")) {
                            viewModel.openProviderSettings()
                        }
                        .buttonStyle(.link)
                        .font(.caption)
                    }
                }
            }

            if let latest {
                MarkdownDocumentView(markdown: latest.content)
            } else {
                emptyOutputPlaceholder
            }
        }
    }

    private var notesIncludedBinding: Binding<Bool> {
        Binding(
            get: { meeting.notesIncludedInOutputs },
            set: { viewModel.setNotesIncluded($0, for: meeting) }
        )
    }

    private var emptyOutputPlaceholder: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "meetingdoc.output.none"))
                .foregroundStyle(.secondary)
            if meeting.segments.isEmpty {
                Text(String(localized: "meetingdoc.output.needsTranscript"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text(String(localized: "meetingdoc.output.generateHint"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Notes (read-only list in the resting state)

    private var notesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "meetings.detail.notes"))
                .font(.headline)
            ForEach(meeting.notes.sorted { $0.createdAt < $1.createdAt }, id: \.id) { note in
                HStack(alignment: .top, spacing: 8) {
                    if let offset = note.timestampOffset {
                        Text(MeetingTranscriptPanel.timestamp(offset))
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

    static func provenance(for output: MeetingOutput) -> String? {
        var parts: [String] = []
        if let provider = output.providerUsed, !provider.isEmpty { parts.append(provider) }
        if let model = output.modelUsed, !model.isEmpty { parts.append(model) }
        let source = parts.joined(separator: " · ")
        let timestamp = output.createdAt.formatted(date: .abbreviated, time: .shortened)
        if source.isEmpty { return timestamp }
        return "\(source) — \(timestamp)"
    }
}

/// [Track B] Per-meeting override for the final (post-stop) re-transcription (addendum AD8), moved
/// verbatim from the retired `MeetingDetailView`. Adds an "inherit" option on top of the global
/// picker's three modes: `.inherit` (nil) defers to the matched rule → global default →
/// `.sameEngine`, so an unconfigured meeting behaves exactly as before.
struct MeetingFinalRetranscriptionOverrideView: View {
    @ObservedObject private var viewModel = MeetingsViewModel.shared
    let meeting: Meeting

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
