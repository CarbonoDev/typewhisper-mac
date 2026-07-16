import SwiftUI

/// The pre-meeting brief surface for a meeting (plan M5): a generate/regenerate button plus the
/// newest persisted `.brief` output. Embedded in `MeetingDetailView`. The brief draws on prior
/// related meetings and, when connected, the Obsidian knowledge base.
struct MeetingBriefView: View {
    @ObservedObject private var viewModel = MeetingsViewModel.shared
    // [Track J] Observe the queue directly so the meeting-scoped brief spinner reacts to job state
    // (the VM does not republish on queue mutations — plan J2 §CC7).
    @ObservedObject private var jobQueue = JobQueueService.shared
    // [M5/D10] The prompt-provider catalog for the one-shot "For this run" / "Save as default…" submenus.
    @ObservedObject private var promptProcessingService = ServiceContainer.shared.promptProcessingService
    let meeting: Meeting

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(String(localized: "meetings.brief.sectionTitle"))
                    .font(.headline)
                Spacer()
                generateButton
            }

            if !viewModel.isVaultConnected {
                Text(String(localized: "meetings.brief.noVaultHint"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if let error = viewModel.briefErrorMessage {
                VStack(alignment: .leading, spacing: 4) {
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
                Text(latest.content)
                    .font(.body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))

                if let provenance = provenance(for: latest) {
                    Text(provenance)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text(String(localized: "meetings.brief.none"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var generateButton: some View {
        let hasExisting = viewModel.latestOutput(ofKind: .brief, for: meeting) != nil
        let label = hasExisting
            ? String(localized: "meetings.brief.regenerate")
            : String(localized: "meetings.brief.generate")

        if viewModel.isGeneratingBrief(for: meeting) {
            ProgressView()
                .controlSize(.small)
        } else {
            Menu {
                // [M5/D10] One-shot model override for this brief run (wins the ladder, persists
                // nothing), plus "Save as default…" targeting the brief template when one exists.
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
            } label: {
                Text(label)
            } primaryAction: {
                viewModel.generateBrief(for: meeting)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
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
