import SwiftUI

/// Granola-style folder detail view (Amendment 1, DA7, M7; redesigned M12). Owner direction: opening a
/// folder puts its **meeting notes** front and center — a serif title, an inline-editable description
/// right under it, then the folder's meetings as a day-grouped list (reusing the Home
/// `MeetingTimelineList` rows) filling the rest of the page. Folder *configuration* (the vault-context
/// attachments) is secondary and lives behind a "Context" affordance that opens `FolderContextSheet`;
/// a small caption summarizes its state on the primary page. The `.folder` route targets this view —
/// no new `MainWindowRoute` case, additive-safe.
struct MeetingFolderDetailView: View {
    let folderPath: String

    @ObservedObject private var viewModel = MeetingsViewModel.shared
    @ObservedObject private var coordinator = MainWindowCoordinator.shared
    /// Observe the metadata store directly so the description + Context caption react to writes
    /// (mirrors how the sidebar observes `MeetingOrganizationIndex.shared`).
    @ObservedObject private var metadataStore = MeetingFolderMetadataStore.shared

    @State private var descriptionText = ""
    @State private var isPresentingContext = false

    private var config: FolderContextConfig {
        metadataStore.config(for: folderPath)
    }

    private var folderName: String {
        MeetingService.folderComponents(folderPath).last ?? folderPath
    }

    /// The folder's meetings, honoring the coordinator's active **tag** filter (M8): the sidebar keeps
    /// the tag row highlighted while this view is open, so the rendered list composes the same
    /// folder + tag AND filter (plan D8) rather than ignoring the active tag.
    private var folderMeetings: [Meeting] {
        MeetingsViewModel.filteredMeetings(
            viewModel.meetings,
            folder: folderPath,
            tag: coordinator.activeTag
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                meetingsSection
            }
            .padding(24)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(folderName)
        .toolbar {
            ToolbarItem {
                Button {
                    isPresentingContext = true
                } label: {
                    Label(String(localized: "meetingfolder.context.header"), systemImage: "text.book.closed")
                }
            }
        }
        .onAppear { descriptionText = config.description }
        .onChange(of: folderPath) { _, _ in descriptionText = config.description }
        .sheet(isPresented: $isPresentingContext) {
            FolderContextSheet(folderPath: folderPath)
        }
    }

    // MARK: - Header (serif title + inline description + Context affordance)

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "folder")
                    .foregroundStyle(.secondary)
                Text(folderName)
                    .font(.largeTitle)
                    .fontDesign(.serif)
                    .fontWeight(.bold)
            }

            // Inline, single-click-to-edit description with an "Add a description…" placeholder when
            // empty — matches the Granola reference.
            TextField(
                String(localized: "meetingfolder.detail.description.placeholder"),
                text: $descriptionText,
                axis: .vertical
            )
            .textFieldStyle(.plain)
            .lineLimit(1...5)
            .font(.body)
            .foregroundStyle(.secondary)
            .onChange(of: descriptionText) { _, newValue in
                viewModel.setFolderDescription(newValue, for: folderPath)
            }

            contextAffordance

            if let tag = coordinator.activeTag {
                activeTagChip(tag)
            }
        }
    }

    /// The clearly-labeled "Context" affordance and its state caption (e.g. "3 attached" /
    /// "Vault context off"). Opens the secondary configuration sheet.
    private var contextAffordance: some View {
        HStack(spacing: 8) {
            Button {
                isPresentingContext = true
            } label: {
                Label(String(localized: "meetingfolder.context.header"), systemImage: "text.book.closed")
            }
            Text(contextSummary)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 2)
    }

    /// A one-line summary of the folder's context configuration for the primary page (pure over the
    /// stored config + vault connectivity).
    private var contextSummary: String {
        guard viewModel.isVaultConnected else {
            return String(localized: "meetingfolder.context.summary.notConnected")
        }
        if config.noVaultContext {
            return String(localized: "meetingfolder.context.summary.off")
        }
        let count = config.attachedNotePaths.count + config.attachedFolderPaths.count
        if count == 0 {
            return String(localized: "meetingfolder.context.summary.wholeVault")
        }
        return String(format: String(localized: "meetingfolder.context.summary.attached"), count)
    }

    /// A clearable chip showing the active composed tag filter (M8): the folder list is already scoped
    /// to `folder AND #tag`, so the chip makes that composition visible and lets the user drop just the
    /// tag facet without leaving the folder.
    private func activeTagChip(_ tag: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "tag")
            Text("#\(tag)").fontWeight(.semibold)
            Button {
                coordinator.clearTagFilter()
            } label: {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .font(.caption)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(.secondary.opacity(0.12), in: Capsule())
    }

    // MARK: - Meetings (day-grouped, reusing the Home rows)

    @ViewBuilder
    private var meetingsSection: some View {
        if folderMeetings.isEmpty {
            if coordinator.activeTag != nil {
                filteredEmptyState
            } else {
                emptyState
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                if !viewModel.visibleSelection(in: folderMeetings.map(\.id)).isEmpty {
                    Label(
                        String(
                            format: String(localized: "meetings.selection.count"),
                            viewModel.visibleSelection(in: folderMeetings.map(\.id)).count
                        ),
                        systemImage: "checkmark.circle"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                // Folder detail is a selectable surface (plan LX-1, D3): pass a binding so the shared
                // timeline rows become selectable, and normalize the selection to the still-visible set
                // when the folder+tag filter changes.
                MeetingTimelineList(meetings: folderMeetings, selection: $viewModel.selectedMeetingIDs)
                    .onChange(of: folderMeetings.map(\.id)) { _, ids in
                        viewModel.selectedMeetingIDs = MeetingsViewModel.normalizedSelection(
                            viewModel.selectedMeetingIDs, toVisibleIDs: ids
                        )
                    }
            }
        }
    }

    private var emptyState: some View {
        Text(String(localized: "meetingfolder.detail.meetings.empty"))
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.vertical, 4)
    }

    /// A folder+tag composition that matches nothing shows a filter-specific empty state with a way to
    /// drop the tag, rather than the generic "no meetings in this folder yet" prompt.
    private var filteredEmptyState: some View {
        ContentUnavailableView {
            Label(
                String(localized: "mainwindow.meetings.empty.filtered.title"),
                systemImage: "line.3.horizontal.decrease.circle"
            )
        } description: {
            Text(String(localized: "mainwindow.meetings.empty.filtered.message"))
        } actions: {
            Button {
                coordinator.clearTagFilter()
            } label: {
                Text(String(localized: "mainwindow.meetings.filter.clear"))
            }
        }
    }
}

/// The secondary folder-context configuration surface (M12). The **entire** M7 Context section — the
/// attachment list with inline remove, the `VaultContextPickerView` add flow, the "No vault context"
/// toggle, and the vault-not-connected state — moved here **unchanged in behavior** from the folder
/// detail page. Presented as a sheet from the folder page's "Context" affordance. All existing
/// folder-context tests exercise the store/services beneath this and are unaffected by the move.
struct FolderContextSheet: View {
    let folderPath: String

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var viewModel = MeetingsViewModel.shared
    @ObservedObject private var metadataStore = MeetingFolderMetadataStore.shared

    @State private var isPresentingPicker = false

    private var config: FolderContextConfig {
        metadataStore.config(for: folderPath)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(String(localized: "meetingfolder.context.header"))
                    .font(.headline)
                Spacer()
                Button(String(localized: "meetingfolder.context.sheet.done")) { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding()
            Divider()
            ScrollView {
                contextSection
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: 460, height: 520)
        .sheet(isPresented: $isPresentingPicker) {
            VaultContextPickerView { entries in
                viewModel.attachVaultEntries(entries, to: folderPath)
            }
        }
    }

    // MARK: - Context (moved verbatim from M7 MeetingFolderDetailView)

    private var contextSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(String(localized: "meetingfolder.context.subtitle"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
