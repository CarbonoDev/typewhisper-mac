import SwiftUI

/// The generated-outputs surface for a stored meeting (plan M4): a Summary section and an
/// Extended-analysis section, each with a template-driven generate/regenerate menu, plus the
/// "include notes in outputs" toggle. Embedded in `MeetingDetailView`.
struct MeetingOutputsView: View {
    @ObservedObject private var viewModel = MeetingsViewModel.shared
    let meeting: Meeting

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(String(localized: "meetings.output.sectionTitle"))
                    .font(.headline)
                Spacer()
                Toggle(isOn: notesBinding) {
                    Text(String(localized: "meetings.output.includeNotes"))
                        .font(.caption)
                }
                .toggleStyle(.checkbox)
                .disabled(meeting.notes.isEmpty)
            }

            if let error = viewModel.outputErrorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            outputSection(kind: .summary, title: String(localized: "meetings.output.kind.summary"))
            outputSection(kind: .extended, title: String(localized: "meetings.output.kind.extended"))
        }
    }

    private var notesBinding: Binding<Bool> {
        Binding(
            get: { meeting.notesIncludedInOutputs },
            set: { viewModel.setNotesIncluded($0, for: meeting) }
        )
    }

    @ViewBuilder
    private func outputSection(kind: MeetingOutputKind, title: String) -> some View {
        let templates = viewModel.templates(ofKind: kind)
        let latest = viewModel.latestOutput(ofKind: kind, for: meeting)

        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .font(.subheadline.bold())
                Spacer()
                generateMenu(kind: kind, templates: templates, hasExisting: latest != nil)
            }

            if let latest {
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
                Text(String(localized: "meetings.output.none"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func generateMenu(kind: MeetingOutputKind, templates: [MeetingTemplate], hasExisting: Bool) -> some View {
        let label = hasExisting
            ? String(localized: "meetings.output.regenerate")
            : String(localized: "meetings.output.generate")

        if templates.isEmpty {
            Text(String(localized: "meetings.output.noTemplates"))
                .font(.caption2)
                .foregroundStyle(.secondary)
        } else if viewModel.isGeneratingOutput {
            ProgressView()
                .controlSize(.small)
        } else {
            Menu(label) {
                ForEach(templates, id: \.id) { template in
                    Button(template.name) {
                        Task { await viewModel.generateOutput(for: meeting, using: template) }
                    }
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(meeting.segments.isEmpty)
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
