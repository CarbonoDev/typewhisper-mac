import SwiftUI
import AppKit

/// [Sprint 1] The state-switched body of the meeting document, rebuilt lifecycle-first:
/// - `.scheduledEmpty` — the briefing page: the pre-meeting brief is the hero, related documents
///   are the supporting context, and nothing else renders (import + final-pass override moved to
///   the masthead's overflow menu).
/// - `.liveNotes` — the capture page: notes only; Q&A lives in the transcript panel's Q&A tab.
/// - `.renderedOutput` — outcomes first: action items and decisions extracted from the generated
///   markdown, then the output article under text tabs, then a closed-by-default appendix
///   (transcript, Q&A, speakers, notes, related documents).
struct MeetingDocumentBody: View {
    @ObservedObject private var viewModel = MeetingsViewModel.shared
    // [Track J] Observe the queue directly so meeting-scoped spinners react to job state (the VM
    // does not republish on queue mutations — plan J2 §CC7).
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

    // MARK: - Scheduled / empty — the briefing page

    private var scheduledEmptyBody: some View {
        VStack(alignment: .leading, spacing: MeetingTheme.sectionGap) {
            MeetingBriefView(meeting: meeting) {
                model.isPresentingImport = true
            }
            MeetingRelatedDocsSection(meeting: meeting)
        }
    }

    // MARK: - Live capture — agenda + notes

    private var liveNotesBody: some View {
        VStack(alignment: .leading, spacing: MeetingTheme.sectionGap) {
            // The brief's talking points ride along into the meeting as a tick-off agenda —
            // unchecked items are what's left to cover.
            if let brief = viewModel.latestOutput(ofKind: .brief, for: meeting) {
                let agenda = MeetingOutputParser.parseAgenda(markdown: brief.content)
                if !agenda.items.isEmpty {
                    MeetingAgendaSection(meetingID: meeting.id, items: agenda.items)
                }
            }
            MeetingNotesPane(meeting: meeting)
        }
    }

    // MARK: - Rendered output — outcomes first

    /// Outcome extraction only applies to the prose kinds; the brief tab renders untouched (its
    /// "suggested talking points" are prep, not action items).
    private var slicesOutcomes: Bool {
        model.selectedOutputKind == .summary || model.selectedOutputKind == .extended
    }

    private var renderedOutputBody: some View {
        let latest = viewModel.latestOutput(ofKind: model.selectedOutputKind, for: meeting)
        let outcomes: MeetingOutputParser.ExtractedOutcomes? = (latest != nil && slicesOutcomes)
            ? MeetingOutputParser.parse(markdown: latest!.content)
            : nil

        return VStack(alignment: .leading, spacing: MeetingTheme.sectionGap) {
            if let outcomes, !outcomes.actions.isEmpty {
                ActionItemsSection(meeting: meeting, items: outcomes.actions)
            }
            if let outcomes, !outcomes.decisions.isEmpty {
                DecisionsSection(decisions: outcomes.decisions)
            }
            outputArticle(latest: latest, outcomes: outcomes)
            appendix
        }
    }

    @ViewBuilder
    private func outputArticle(latest: MeetingOutput?, outcomes: MeetingOutputParser.ExtractedOutcomes?) -> some View {
        VStack(alignment: .leading, spacing: MeetingTheme.s4) {
            MeetingOutputTabs(tabs: outputTabs, selection: $model.selectedOutputKind)

            if let error = viewModel.outputErrorMessage {
                VStack(alignment: .leading, spacing: MeetingTheme.s1) {
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
                MeetingProse(markdown: outcomes?.strippedMarkdown ?? latest.content) {
                    if let provenance = Self.provenance(for: latest) {
                        Text(provenance)
                            .font(MeetingTheme.footnote)
                            .foregroundStyle(.tertiary)
                    }
                }
            } else {
                emptyOutputCard
            }
        }
    }

    private var outputTabs: [MeetingOutputTabs.Tab] {
        MeetingsViewModel.selectableOutputKinds.map { kind in
            MeetingOutputTabs.Tab(
                id: String(describing: kind),
                label: MeetingsViewModel.outputKindLabel(kind),
                kind: kind
            )
        }
    }

    /// Transcript exists but nothing was generated for this tab yet: one card, one action.
    private var emptyOutputCard: some View {
        MeetingEmptyStateCard(
            icon: "sparkles",
            title: String(localized: "meetingdoc.output.none"),
            message: meeting.segments.isEmpty
                ? String(localized: "meetingdoc.output.needsTranscript")
                : String(localized: "meetingdoc.output.generateHint")
        ) {
            if !meeting.segments.isEmpty {
                if viewModel.isGeneratingOutput(for: meeting) {
                    ProgressView().controlSize(.small)
                } else if let template = viewModel.defaultTemplate(ofKind: model.selectedOutputKind, for: meeting) {
                    Button {
                        viewModel.generateOutput(for: meeting, using: template)
                    } label: {
                        Label(String(localized: "meetingdoc.generate"), systemImage: "sparkles")
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
    }

    // MARK: - Appendix

    private var speakerCount: Int {
        Set(meeting.segments.compactMap { segment -> String? in
            guard let label = segment.speakerLabel?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !label.isEmpty else { return nil }
            return label
        }).count
    }

    private var transcriptDetail: String {
        var parts: [String] = []
        if let last = meeting.segments.map(\.end).max(), last > 0 {
            parts.append(Duration.seconds(last).formatted(.units(allowed: [.hours, .minutes], width: .narrow)))
        }
        if speakerCount > 1 {
            parts.append(String(format: String(localized: "meetingdoc.appendix.speakerCount"), speakerCount))
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var appendix: some View {
        VStack(alignment: .leading, spacing: MeetingTheme.s2) {
            MeetingSectionLabel(String(localized: "meetingdoc.appendix"))

            if !meeting.segments.isEmpty {
                MeetingQuietRow(
                    icon: "waveform",
                    title: String(localized: "meetingdoc.transcript.title"),
                    detail: transcriptDetail
                ) {
                    model.panelTab = .transcript
                    model.isTranscriptPanelOpen = true
                }
            }

            if !meeting.qaTurns.isEmpty {
                MeetingQuietRow(
                    icon: "sparkles",
                    title: String(localized: "meetings.qa.sectionTitle"),
                    detail: "\(meeting.qaTurns.count)"
                ) {
                    model.panelTab = .qa
                    model.isTranscriptPanelOpen = true
                }
            }

            if !meeting.segments.isEmpty {
                MeetingAppendixRow(
                    title: String(localized: "meetings.diarization.title"),
                    summary: speakerSummary
                ) {
                    SpeakerSection(meeting: meeting)
                }
            }

            if !meeting.notes.isEmpty {
                MeetingAppendixRow(
                    title: String(localized: "meetings.detail.notes"),
                    summary: "\(meeting.notes.count)"
                ) {
                    notesAppendixContent
                }
            }

            if viewModel.isVaultConnected || !viewModel.relatedDocuments(for: meeting).isEmpty {
                MeetingAppendixRow(
                    title: String(localized: "meetingdoc.related.title"),
                    summary: relatedSummary
                ) {
                    MeetingRelatedDocsSection(meeting: meeting)
                }
            }
        }
    }

    private var speakerSummary: String? {
        let mapped = meeting.speakerMap.values
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !mapped.isEmpty else { return nil }
        return mapped.sorted().joined(separator: " · ")
    }

    private var relatedSummary: String? {
        let count = viewModel.relatedDocuments(for: meeting).count
        return count > 0 ? "\(count)" : nil
    }

    private var notesAppendixContent: some View {
        VStack(alignment: .leading, spacing: MeetingTheme.s2) {
            ForEach(meeting.notes.sorted { $0.createdAt < $1.createdAt }, id: \.id) { note in
                HStack(alignment: .top, spacing: MeetingTheme.s2) {
                    if let offset = note.timestampOffset {
                        Text(MeetingTranscriptPanel.timestamp(offset))
                            .font(MeetingTheme.mono)
                            .foregroundStyle(.secondary)
                            .frame(width: 56, alignment: .leading)
                    }
                    Text(note.text)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            // Re-hosted from the retired MeetingOutputsView: fold in-meeting notes into (or out of)
            // generated outputs. MeetingLLMService reads meeting.notesIncludedInOutputs at
            // generation time.
            Toggle(isOn: notesIncludedBinding) {
                Text(String(localized: "meetings.output.includeNotes"))
                    .font(.caption)
            }
            .toggleStyle(.checkbox)
            .padding(.top, MeetingTheme.s1)
        }
    }

    private var notesIncludedBinding: Binding<Bool> {
        Binding(
            get: { meeting.notesIncludedInOutputs },
            set: { viewModel.setNotesIncluded($0, for: meeting) }
        )
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

// MARK: - Action items (extracted outcomes)

/// The extracted action-items card: checkbox rows whose done-state persists via
/// `MeetingChecklistStore` (keyed by the item's stable content hash — a regenerated, reworded item
/// intentionally resets), assignees when the parser found one, and a copy-as-markdown action.
private struct ActionItemsSection: View {
    let meeting: Meeting
    let items: [MeetingOutputParser.ActionItem]
    @ObservedObject private var store = MeetingChecklistStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: MeetingTheme.s2) {
            MeetingSectionLabel(sectionTitle) {
                Button {
                    copyAsMarkdown()
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 11))
                }
                .buttonStyle(.borderless)
                .help(String(localized: "meetingdoc.actions.copy"))
            }

            VStack(alignment: .leading, spacing: 0) {
                ForEach(items, id: \.stableID) { item in
                    row(for: item)
                }
            }
            .padding(MeetingTheme.s3)
            .background(MeetingTheme.tintedCardFill, in: RoundedRectangle(cornerRadius: MeetingTheme.cardRadius))
        }
    }

    private var sectionTitle: String {
        let done = store.doneCount(meetingID: meeting.id, itemIDs: items.map(\.stableID))
        return done > 0
            ? String(format: String(localized: "meetingdoc.actions.titleWithDone"), done, items.count)
            : String(format: String(localized: "meetingdoc.actions.title"), items.count)
    }

    private func row(for item: MeetingOutputParser.ActionItem) -> some View {
        let isDone = store.isDone(meetingID: meeting.id, itemID: item.stableID)
        return Button {
            store.setDone(!isDone, meetingID: meeting.id, itemID: item.stableID)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: MeetingTheme.s2) {
                Image(systemName: isDone ? "checkmark.square.fill" : "square")
                    .font(.system(size: 13))
                    .foregroundStyle(isDone ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                Text(item.text)
                    .font(MeetingTheme.meta)
                    .strikethrough(isDone)
                    .foregroundStyle(isDone ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .multilineTextAlignment(.leading)
                if let assignee = item.assignee {
                    Text(assignee)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, MeetingTheme.s2)
                        .padding(.vertical, 2)
                        .background(MeetingTheme.chipFill, in: Capsule())
                }
            }
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func copyAsMarkdown() {
        let lines = items.map { item -> String in
            let done = store.isDone(meetingID: meeting.id, itemID: item.stableID)
            let box = done ? "[x]" : "[ ]"
            let assignee = item.assignee.map { " (\($0))" } ?? ""
            return "- \(box) \(item.text)\(assignee)"
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
    }
}

/// Extracted decisions: quiet accent-ruled rows — statements, not checkboxes.
private struct DecisionsSection: View {
    let decisions: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: MeetingTheme.s2) {
            MeetingSectionLabel(String(format: String(localized: "meetingdoc.decisions.title"), decisions.count))
            VStack(alignment: .leading, spacing: MeetingTheme.s2) {
                ForEach(Array(decisions.enumerated()), id: \.offset) { _, decision in
                    Text(decision)
                        .font(MeetingTheme.meta)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.leading, MeetingTheme.s3)
                        .overlay(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 1.5)
                                .fill(Color.accentColor.opacity(0.5))
                                .frame(width: 3)
                        }
                }
            }
        }
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
