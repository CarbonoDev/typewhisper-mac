import SwiftUI

/// The Obsidian export surface for a meeting (plan M7): a per-meeting folder + tags editor, a
/// section picker, a single-note vs separate-notes layout choice, and an export button. Embedded in
/// `MeetingDetailView`. The vault is the one connected in Meetings settings (no second picker).
struct MeetingExportView: View {
    @ObservedObject private var viewModel = MeetingsViewModel.shared
    let meeting: Meeting

    @State private var folder: String = ""
    @State private var tagsText: String = ""
    @State private var selectedSections: Set<MeetingExportSection> = [.summary, .transcript, .notes]
    @State private var combined = true
    @State private var exportedCount: Int?
    @State private var didLoad = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(String(localized: "meetings.export.sectionTitle"))
                .font(.headline)

            if !viewModel.isVaultConnected {
                Text(String(localized: "meetings.export.noVaultHint"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            LabeledContent(String(localized: "meetings.export.folderLabel")) {
                TextField(String(localized: "meetings.export.folderPlaceholder"), text: $folder)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { viewModel.setObsidianFolder(folder, for: meeting) }
            }

            LabeledContent(String(localized: "meetings.export.tagsLabel")) {
                TextField(String(localized: "meetings.export.tagsPlaceholder"), text: $tagsText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { viewModel.setObsidianTags(tagsText, for: meeting) }
            }

            VStack(alignment: .leading, spacing: 4) {
                ForEach(MeetingExportSection.allCases) { section in
                    Toggle(section.displayName, isOn: binding(for: section))
                }
            }

            Picker(String(localized: "meetings.export.layoutLabel"), selection: $combined) {
                Text(String(localized: "meetings.export.layoutCombined")).tag(true)
                Text(String(localized: "meetings.export.layoutSeparate")).tag(false)
            }
            .pickerStyle(.segmented)

            if let error = viewModel.exportErrorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack(spacing: 10) {
                Button(String(localized: "meetings.export.button")) { performExport() }
                    .disabled(!viewModel.isVaultConnected || selectedSections.isEmpty)

                if let exportedCount, viewModel.exportErrorMessage == nil {
                    Text(String(format: String(localized: "meetings.export.success"), exportedCount))
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            }
        }
        .onAppear {
            guard !didLoad else { return }
            folder = meeting.obsidianFolder ?? ""
            tagsText = meeting.obsidianTags.joined(separator: ", ")
            didLoad = true
        }
    }

    private func binding(for section: MeetingExportSection) -> Binding<Bool> {
        Binding(
            get: { selectedSections.contains(section) },
            set: { isOn in
                if isOn { selectedSections.insert(section) } else { selectedSections.remove(section) }
                exportedCount = nil
            }
        )
    }

    private func performExport() {
        // Persist the latest folder/tags edits (in case the fields were not submitted) before writing.
        viewModel.setObsidianFolder(folder, for: meeting)
        viewModel.setObsidianTags(tagsText, for: meeting)
        exportedCount = viewModel.export(meeting, sections: Array(selectedSections), combined: combined)
    }
}
