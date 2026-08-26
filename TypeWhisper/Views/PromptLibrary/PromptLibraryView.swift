import SwiftUI

/// The unified prompt/template library (plan AD6): one surface listing both dictation quick-actions
/// and meeting output templates. Meeting templates are fully editable here through the shared
/// `PromptTemplateEditor` (re-hosted via `MeetingTemplateEditorView`); dictation actions are shown
/// read-only with a pointer to the dedicated Prompt Actions settings for their hotkey/target-action
/// editing, keeping the two surfaces visibly one library while preserving the specialized dictation
/// editor.
struct PromptLibraryView: View {
    @ObservedObject private var viewModel = MeetingsViewModel.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(String(localized: "promptLibrary.title"))
                .font(.title3.bold())

            // Meeting templates — full CRUD via the shared editor.
            MeetingTemplateEditorView()

            Divider()

            dictationSection
        }
    }

    private var dictationSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "promptLibrary.dictation.title"))
                .font(.headline)
            Text(String(localized: "promptLibrary.dictation.subtitle"))
                .font(.caption)
                .foregroundStyle(.secondary)

            let actions = viewModel.dictationActions
            if actions.isEmpty {
                Text(String(localized: "promptLibrary.dictation.empty"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(actions, id: \.id) { action in
                    HStack(spacing: 6) {
                        Image(systemName: action.icon)
                            .foregroundStyle(.secondary)
                            .frame(width: 18)
                        Text(action.name)
                            .font(.subheadline)
                        if !action.isEnabled {
                            Text(String(localized: "promptLibrary.dictation.disabled"))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }
}
