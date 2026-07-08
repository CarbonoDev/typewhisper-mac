import SwiftUI

/// Granola-style folder detail view (Amendment 1, DA7, M7). The `.folder` route re-targets here: a
/// header + editable description, the folder's meetings, and a Context section listing the vault
/// notes/folders attached as brief/Q&A scope (add via `VaultContextPickerView`, remove inline, or
/// toggle "No vault context"). No new `MainWindowRoute` case — additive-safe.
struct MeetingFolderDetailView: View {
    let folderPath: String

    @ObservedObject private var viewModel = MeetingsViewModel.shared
    @ObservedObject private var coordinator = MainWindowCoordinator.shared
    /// Observe the metadata store directly so the description + Context section react to writes
    /// (mirrors how the sidebar observes `MeetingOrganizationIndex.shared`).
    @ObservedObject private var metadataStore = MeetingFolderMetadataStore.shared

    @State private var descriptionText = ""
    @State private var isPresentingPicker = false

    private var config: FolderContextConfig {
        metadataStore.config(for: folderPath)
    }

    private var folderName: String {
        MeetingService.folderComponents(folderPath).last ?? folderPath
    }

    private var folderMeetings: [Meeting] {
        viewModel.meetings(inFolder: folderPath)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                meetingsSection
                Divider()
                contextSection
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(folderName)
        .onAppear { descriptionText = config.description }
        .onChange(of: folderPath) { _, _ in descriptionText = config.description }
        .sheet(isPresented: $isPresentingPicker) {
            VaultContextPickerView { entries in
                viewModel.attachVaultEntries(entries, to: folderPath)
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "folder")
                    .foregroundStyle(.secondary)
                Text(folderName)
                    .font(.largeTitle.bold())
            }
            TextField(
                String(localized: "meetingfolder.detail.description.placeholder"),
                text: $descriptionText,
                axis: .vertical
            )
            .textFieldStyle(.plain)
            .lineLimit(1...5)
            .font(.body)
            .onChange(of: descriptionText) { _, newValue in
                viewModel.setFolderDescription(newValue, for: folderPath)
            }
        }
    }

    // MARK: - Meetings

    private var meetingsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "meetingfolder.detail.meetings.header"))
                .font(.headline)
            if folderMeetings.isEmpty {
                Text(String(localized: "meetingfolder.detail.meetings.empty"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(folderMeetings, id: \.id) { meeting in
                    Button {
                        coordinator.openMeeting(id: meeting.id)
                    } label: {
                        meetingRow(meeting)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func meetingRow(_ meeting: Meeting) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(meeting.title)
                .lineLimit(1)
            HStack(spacing: 6) {
                if let start = meeting.startDate {
                    Text(start, style: .date)
                }
                Text(meeting.state.displayName)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .padding(.vertical, 2)
    }

    // MARK: - Context

    private var contextSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(String(localized: "meetingfolder.context.header"))
                    .font(.headline)
                Spacer()
                if viewModel.isVaultConnected {
                    Button {
                        isPresentingPicker = true
                    } label: {
                        Label(String(localized: "meetingfolder.context.add"), systemImage: "plus")
                    }
                    .disabled(config.noVaultContext)
                }
            }
            Text(String(localized: "meetingfolder.context.subtitle"))
                .font(.caption)
                .foregroundStyle(.secondary)

            if !viewModel.isVaultConnected {
                Text(String(localized: "meetingfolder.context.notConnected"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            } else {
                Toggle(isOn: Binding(
                    get: { config.noVaultContext },
                    set: { viewModel.setFolderNoVaultContext($0, for: folderPath) }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(String(localized: "meetingfolder.context.noVaultToggle"))
                        Text(String(localized: "meetingfolder.context.noVaultCaption"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if !config.noVaultContext {
                    attachmentList
                }
            }
        }
    }

    @ViewBuilder
    private var attachmentList: some View {
        if config.attachedFolderPaths.isEmpty && config.attachedNotePaths.isEmpty {
            Text(String(localized: "meetingfolder.context.empty"))
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.vertical, 4)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(config.attachedFolderPaths, id: \.self) { path in
                    attachmentRow(path: path, isDirectory: true) {
                        viewModel.removeAttachedFolder(path, from: folderPath)
                    }
                }
                ForEach(config.attachedNotePaths, id: \.self) { path in
                    attachmentRow(path: path, isDirectory: false) {
                        viewModel.removeAttachedNote(path, from: folderPath)
                    }
                }
            }
        }
    }

    private func attachmentRow(path: String, isDirectory: Bool, onRemove: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Image(systemName: isDirectory ? "folder" : "doc.text")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text((path as NSString).lastPathComponent)
                    .lineLimit(1)
                Text(path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(String(localized: "meetingfolder.context.remove"))
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 8)
        .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
    }
}
