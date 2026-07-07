import SwiftUI

/// Management UI for meeting output templates (plan M4): list the seeded/custom templates and
/// add, edit, or delete them. Presets are editable (edits persist) but flagged. Shown inside the
/// Meetings settings tab.
struct MeetingTemplateEditorView: View {
    @ObservedObject private var viewModel = MeetingsViewModel.shared
    @State private var editingDraft: TemplateDraft?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(String(localized: "meetings.templates.title"))
                    .font(.headline)
                Spacer()
                Button {
                    editingDraft = TemplateDraft()
                } label: {
                    Label(String(localized: "meetings.templates.add"), systemImage: "plus")
                }
            }

            if viewModel.templates.isEmpty {
                Text(String(localized: "meetings.templates.empty"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(viewModel.templates, id: \.id) { template in
                    templateRow(template)
                }
            }
        }
        .sheet(item: $editingDraft) { draft in
            MeetingTemplateEditSheet(draft: draft) { result in
                apply(result)
                editingDraft = nil
            } onCancel: {
                editingDraft = nil
            }
        }
    }

    private func templateRow(_ template: MeetingTemplate) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(template.name)
                        .font(.subheadline.bold())
                    Text(kindLabel(template.kind))
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                    if template.isPreset {
                        Text(String(localized: "meetings.templates.presetBadge"))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Text(template.prompt)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            Button(String(localized: "meetings.templates.edit")) {
                editingDraft = TemplateDraft(template: template)
            }
            .buttonStyle(.borderless)
            Button(role: .destructive) {
                viewModel.deleteTemplate(template)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 4)
    }

    private func apply(_ draft: TemplateDraft) {
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let prompt = draft.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !prompt.isEmpty else { return }

        if let existing = draft.existing {
            existing.name = name
            existing.kind = draft.kind
            existing.prompt = prompt
            viewModel.updateTemplate(existing)
        } else {
            viewModel.addTemplate(name: name, kind: draft.kind, prompt: prompt)
        }
    }

    private func kindLabel(_ kind: MeetingOutputKind) -> String {
        switch kind {
        case .summary: return String(localized: "meetings.output.kind.summary")
        case .extended: return String(localized: "meetings.output.kind.extended")
        case .brief: return String(localized: "meetings.output.kind.brief")
        }
    }
}

/// Editable draft backing the add/edit sheet.
struct TemplateDraft: Identifiable {
    let id = UUID()
    var existing: MeetingTemplate?
    var name: String
    var kind: MeetingOutputKind
    var prompt: String

    init() {
        self.existing = nil
        self.name = ""
        self.kind = .summary
        self.prompt = ""
    }

    init(template: MeetingTemplate) {
        self.existing = template
        self.name = template.name
        self.kind = template.kind
        self.prompt = template.prompt
    }
}

private struct MeetingTemplateEditSheet: View {
    @State var draft: TemplateDraft
    let onSave: (TemplateDraft) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(draft.existing == nil
                 ? String(localized: "meetings.templates.add")
                 : String(localized: "meetings.templates.edit"))
                .font(.headline)

            TextField(String(localized: "meetings.templates.field.name"), text: $draft.name)

            Picker(String(localized: "meetings.templates.field.kind"), selection: $draft.kind) {
                Text(String(localized: "meetings.output.kind.summary")).tag(MeetingOutputKind.summary)
                Text(String(localized: "meetings.output.kind.extended")).tag(MeetingOutputKind.extended)
            }
            .pickerStyle(.segmented)

            Text(String(localized: "meetings.templates.field.prompt"))
                .font(.caption)
                .foregroundStyle(.secondary)
            TextEditor(text: $draft.prompt)
                .font(.body)
                .frame(minHeight: 140)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))

            HStack {
                Spacer()
                Button(String(localized: "meetings.templates.cancel"), role: .cancel, action: onCancel)
                Button(String(localized: "meetings.templates.save")) {
                    onSave(draft)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(
                    draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || draft.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )
            }
        }
        .padding()
        .frame(width: 460)
    }
}
