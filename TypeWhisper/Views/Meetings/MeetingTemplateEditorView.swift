import SwiftUI

/// Management UI for meeting output templates (plan M4/AD6): lists the seeded/custom meeting
/// templates — now unified `.meeting`-surface `PromptAction` rows — and adds, edits, or deletes
/// them through the shared `PromptTemplateEditor`. Used as the Meeting section of
/// `PromptLibraryView` and embeddable on its own.
struct MeetingTemplateEditorView: View {
    @ObservedObject private var viewModel = MeetingsViewModel.shared
    @State private var editingDraft: MeetingTemplateDraft?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(String(localized: "meetings.templates.title"))
                    .font(.headline)
                Spacer()
                Button {
                    editingDraft = MeetingTemplateDraft()
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

    private func templateRow(_ template: PromptAction) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(template.name)
                        .font(.subheadline.bold())
                    Text(kindLabel(template.meetingKind ?? .summary))
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
                editingDraft = MeetingTemplateDraft(template: template)
            }
            .buttonStyle(.borderless)
            Button(role: .destructive) {
                viewModel.deleteMeetingTemplate(template)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 4)
    }

    private func apply(_ draft: MeetingTemplateDraft) {
        guard draft.spec.isValid else { return }
        if let existing = draft.existing {
            viewModel.updateMeetingTemplate(existing, with: draft.spec)
        } else {
            viewModel.addMeetingTemplate(draft.spec)
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

/// Editable draft backing the add/edit sheet — wraps a `PromptTemplateSpec` and the row it edits.
struct MeetingTemplateDraft: Identifiable {
    let id = UUID()
    var existing: PromptAction?
    var spec: PromptTemplateSpec

    init() {
        self.existing = nil
        self.spec = PromptTemplateSpec(surface: .meeting)
    }

    init(template: PromptAction) {
        self.existing = template
        self.spec = PromptTemplateSpec(meetingAction: template)
    }
}

private struct MeetingTemplateEditSheet: View {
    @State var draft: MeetingTemplateDraft
    let onSave: (MeetingTemplateDraft) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(draft.existing == nil
                 ? String(localized: "meetings.templates.add")
                 : String(localized: "meetings.templates.edit"))
                .font(.headline)

            PromptTemplateEditor(spec: $draft.spec)

            HStack {
                Spacer()
                Button(String(localized: "meetings.templates.cancel"), role: .cancel, action: onCancel)
                Button(String(localized: "meetings.templates.save")) {
                    onSave(draft)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!draft.spec.isValid)
            }
        }
        .padding()
        .frame(width: 480)
    }
}
