import SwiftUI

/// The pre-meeting brief surface for a meeting (plan M5): a generate/regenerate button plus the
/// newest persisted `.brief` output. Embedded in `MeetingDetailView`. The brief draws on prior
/// related meetings and, when connected, the Obsidian knowledge base.
struct MeetingBriefView: View {
    @ObservedObject private var viewModel = MeetingsViewModel.shared
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

        if viewModel.isGeneratingBrief {
            ProgressView()
                .controlSize(.small)
        } else {
            Button(label) {
                Task { await viewModel.generateBrief(for: meeting) }
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
