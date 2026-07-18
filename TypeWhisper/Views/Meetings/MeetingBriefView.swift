import SwiftUI

/// [Sprint 1] The pre-meeting brief, restyled as the briefing page's hero: rendered markdown in the
/// article voice with a provenance footnote (fixing the old raw-`Text` render that showed literal
/// `#` headings), or — when no brief exists yet — a single quiet empty-state card whose primary
/// action generates one. The generate/regenerate menu keeps the "For this run" / "Save as default…"
/// model-override submenus (M5/D10).
struct MeetingBriefView: View {
    @ObservedObject private var viewModel = MeetingsViewModel.shared
    // [Track J] Observe the queue directly so the meeting-scoped brief spinner reacts to job state
    // (the VM does not republish on queue mutations — plan J2 §CC7).
    @ObservedObject private var jobQueue = JobQueueService.shared
    // [M5/D10] The prompt-provider catalog for the one-shot "For this run" / "Save as default…" submenus.
    @ObservedObject private var promptProcessingService = ServiceContainer.shared.promptProcessingService
    let meeting: Meeting
    /// Optional escape hatch shown in the empty state ("Import a transcript instead…") — the
    /// scheduled page's only remaining import affordance (the other lives in the overflow menu).
    var onImportTap: (() -> Void)?

    init(meeting: Meeting, onImportTap: (() -> Void)? = nil) {
        self.meeting = meeting
        self.onImportTap = onImportTap
    }

    var body: some View {
        VStack(alignment: .leading, spacing: MeetingTheme.s3) {
            if let error = viewModel.briefErrorMessage {
                VStack(alignment: .leading, spacing: MeetingTheme.s1) {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)

                    if viewModel.briefErrorNeedsProvider {
                        Button(String(localized: "meetings.error.selectProvider")) {
                            viewModel.openProviderSettings()
                        }
                        .buttonStyle(.link)
                        .font(.caption)
                    }
                }
            }

            if let latest = viewModel.latestOutput(ofKind: .brief, for: meeting) {
                // Talking points lift out of the prose as a checkable agenda; checks persist and
                // carry into the live view.
                let agenda = MeetingOutputParser.parseAgenda(markdown: latest.content)
                VStack(alignment: .leading, spacing: MeetingTheme.sectionGap) {
                    VStack(alignment: .leading, spacing: MeetingTheme.s2) {
                        MeetingSectionLabel(String(localized: "meetings.brief.sectionTitle")) {
                            generateMenu(prominent: false)
                        }
                        MeetingProse(markdown: agenda.strippedMarkdown) {
                            if let provenance = provenance(for: latest) {
                                Text(provenance)
                                    .font(MeetingTheme.footnote)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                    if !agenda.items.isEmpty {
                        MeetingAgendaSection(meetingID: meeting.id, items: agenda.items)
                    }
                }
            } else {
                emptyState
            }
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        MeetingEmptyStateCard(
            icon: "sparkles",
            title: String(localized: "meetingdoc.brief.empty.title"),
            message: viewModel.isVaultConnected
                ? String(localized: "meetingdoc.brief.empty.message")
                : String(localized: "meetings.brief.noVaultHint")
        ) {
            VStack(spacing: MeetingTheme.s2) {
                generateMenu(prominent: true)
                if let onImportTap {
                    Button(String(localized: "meetingdoc.brief.importInstead"), action: onImportTap)
                        .buttonStyle(.link)
                        .font(.caption)
                }
            }
        }
    }

    // MARK: - Generate / regenerate

    @ViewBuilder
    private func generateMenu(prominent: Bool) -> some View {
        let hasExisting = viewModel.latestOutput(ofKind: .brief, for: meeting) != nil
        let label = hasExisting
            ? String(localized: "meetings.brief.regenerate")
            : String(localized: "meetings.brief.generate")

        if viewModel.isGeneratingBrief(for: meeting) {
            ProgressView()
                .controlSize(.small)
        } else if prominent {
            Menu {
                overrideMenuItems
            } label: {
                Label(label, systemImage: "sparkles")
            } primaryAction: {
                viewModel.generateBrief(for: meeting)
            }
            .menuStyle(.button)
            .buttonStyle(.borderedProminent)
            .fixedSize()
        } else {
            Menu {
                overrideMenuItems
            } label: {
                Text(label)
                    .font(.caption)
            } primaryAction: {
                viewModel.generateBrief(for: meeting)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }

    /// [M5/D10] One-shot model override for this brief run (wins the ladder, persists nothing),
    /// plus "Save as default…" targeting the brief template when one exists.
    @ViewBuilder
    private var overrideMenuItems: some View {
        Menu(String(localized: "meetingdoc.generate.forThisRun")) {
            modelPickerContents { providerId, modelId in
                viewModel.generateBrief(
                    for: meeting, providerOverride: providerId, modelOverride: modelId
                )
            }
        }
        if let briefTemplate = viewModel.templates(ofKind: .brief).first {
            Menu(String(localized: "meetingdoc.generate.saveAsDefault")) {
                modelPickerContents { providerId, modelId in
                    viewModel.saveModelDefaultToTemplate(
                        provider: providerId, model: modelId, for: briefTemplate
                    )
                }
            }
        }
    }

    /// [M5/D10] The provider→model nesting shared by the "For this run" and "Save as default…" submenus.
    @ViewBuilder
    private func modelPickerContents(
        action: @escaping (_ providerId: String, _ modelId: String?) -> Void
    ) -> some View {
        ForEach(promptProcessingService.availableProviders, id: \.id) { provider in
            let models = promptProcessingService.modelsForProvider(provider.id)
            if models.isEmpty {
                Button(provider.displayName) { action(provider.id, nil) }
            } else {
                Menu(provider.displayName) {
                    ForEach(models, id: \.id) { model in
                        Button(model.displayName) { action(provider.id, model.id) }
                    }
                }
            }
        }
    }

    private func provenance(for output: MeetingOutput) -> String? {
        var parts: [String] = []
        if let provider = output.providerUsed, !provider.isEmpty { parts.append(provider) }
        if let model = output.modelUsed, !model.isEmpty { parts.append(model) }
        let source = parts.joined(separator: " · ")
        let timestamp = output.createdAt.formatted(date: .abbreviated, time: .shortened)
        if source.isEmpty { return timestamp }
        return "\(source) — \(timestamp)"
    }
}
