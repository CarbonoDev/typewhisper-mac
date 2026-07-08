import SwiftUI

/// The persistent sidebar of the main window (UI Step 0, D3): a disabled search placeholder (P1),
/// Home + Meetings destinations, a reserved Space section slot (filled by Track E), a spacer, the
/// live-recording band, and a Settings gear that opens the Settings scene.
struct MainWindowSidebar: View {
    @ObservedObject private var coordinator = MainWindowCoordinator.shared
    @ObservedObject private var organizationIndex = MeetingOrganizationIndex.shared
    @ObservedObject private var viewModel = MeetingsViewModel.shared

    /// Non-nil while the rename sheet is up for a tag (its case-folded key), driving the text field.
    @State private var renamingTag: MeetingTagCount?
    @State private var renameText = ""

    /// Non-nil while the rename sheet is up for a folder node (M4), driving the folder-name field.
    @State private var renamingFolder: MeetingFolderNode?
    @State private var folderRenameText = ""

    var body: some View {
        VStack(spacing: 0) {
            List {
                Section {
                    // Search is a Phase-1 placeholder (disabled), reserved for ⌘K / ask-across later.
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(.tertiary)
                        Text(String(localized: "mainwindow.search.placeholder"))
                            .foregroundStyle(.tertiary)
                    }
                    .font(.callout)

                    destinationButton(
                        title: String(localized: "mainwindow.sidebar.home"),
                        systemImage: "house",
                        isSelected: coordinator.route == .home
                    ) { coordinator.show(.home) }

                    destinationButton(
                        title: String(localized: "mainwindow.sidebar.meetings"),
                        systemImage: "person.2.wave.2",
                        isSelected: isMeetingsRoute
                    ) { coordinator.show(.meetings) }
                }

                // First-party FOLDERS (plan D9/M4): a DisclosureGroup tree derived in
                // `MeetingOrganizationIndex`; rows filter the meetings list (AND with tags), context
                // menus rename/delete in bulk.
                foldersSection

                // First-party TAGS (plan D9/M3): a flat, count-annotated list derived in
                // `MeetingOrganizationIndex`; rows filter the meetings list, context menus rename/delete
                // in bulk.
                tagsSection

                // Phase 2 — Track E injects the `SPACE · OBSIDIAN` section here (hidden until then).
                spaceSection
            }
            .listStyle(.sidebar)
            .alert(String(localized: "mainwindow.tags.rename.title"), isPresented: isRenamingTagBinding) {
                TextField(String(localized: "mainwindow.tags.rename.placeholder"), text: $renameText)
                Button(String(localized: "mainwindow.tags.rename.cancel"), role: .cancel) {
                    renamingTag = nil
                }
                Button(String(localized: "mainwindow.tags.rename.confirm")) {
                    commitTagRename()
                }
            } message: {
                Text(String(localized: "mainwindow.tags.rename.message"))
            }
            .alert(String(localized: "mainwindow.folders.rename.title"), isPresented: isRenamingFolderBinding) {
                TextField(String(localized: "mainwindow.folders.rename.placeholder"), text: $folderRenameText)
                Button(String(localized: "mainwindow.folders.rename.cancel"), role: .cancel) {
                    renamingFolder = nil
                }
                Button(String(localized: "mainwindow.folders.rename.confirm")) {
                    commitFolderRename()
                }
            } message: {
                Text(String(localized: "mainwindow.folders.rename.message"))
            }

            Spacer(minLength: 0)

            // [Track J] Count-only background-activity pill (plan J1); renders nothing when idle.
            MeetingActivityIndicator()

            LiveRecordingBand()

            Divider()

            Button {
                ManagedAppWindowOpener.shared.open(id: AppWindowID.settings)
            } label: {
                Label(String(localized: "mainwindow.sidebar.settings"), systemImage: "gearshape")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        .frame(minWidth: 220)
    }

    /// True for the meetings list and any single meeting document (both live under "Meetings"), but
    /// **not** the tag-filtered list — a tag route highlights its own sidebar row instead.
    private var isMeetingsRoute: Bool {
        switch coordinator.route {
        case .meetings, .meeting:
            return true
        default:
            return false
        }
    }

    /// Bridges the optional `renamingTag` to the `.alert(isPresented:)` API.
    private var isRenamingTagBinding: Binding<Bool> {
        Binding(
            get: { renamingTag != nil },
            set: { if !$0 { renamingTag = nil } }
        )
    }

    /// Bridges the optional `renamingFolder` to the `.alert(isPresented:)` API.
    private var isRenamingFolderBinding: Binding<Bool> {
        Binding(
            get: { renamingFolder != nil },
            set: { if !$0 { renamingFolder = nil } }
        )
    }

    /// Rename the tag, then re-point the filter if it was the active one so the route never strands
    /// over `.tag(oldKey)` and an empty list (M3 minor 2).
    private func commitTagRename() {
        guard let renamingTag else { return }
        let trimmedNew = renameText.trimmingCharacters(in: .whitespaces)
        viewModel.renameTag(renamingTag.name, to: renameText)
        if coordinator.activeTag?.lowercased() == renamingTag.key {
            if trimmedNew.isEmpty {
                coordinator.clearTagFilter()
            } else {
                coordinator.showTag(trimmedNew)
            }
        }
        self.renamingTag = nil
    }

    /// Rename a folder node (change its leaf name, rewriting the whole subtree), then re-point the
    /// folder filter if it pointed at or under the renamed path (M4; mirrors the tag minor).
    private func commitFolderRename() {
        guard let renamingFolder else { return }
        let parent = MeetingService.folderComponents(renamingFolder.path).dropLast()
        let newLeaf = folderRenameText.trimmingCharacters(in: .whitespaces)
        guard !newLeaf.isEmpty else { self.renamingFolder = nil; return }
        let newComponents = Array(parent) + MeetingService.folderComponents(newLeaf)
        let newPath = newComponents.joined(separator: "/")

        viewModel.renameFolder(renamingFolder.path, to: newPath)

        // If the active folder was at or under the renamed subtree, rewrite it to follow the path.
        if let active = coordinator.activeFolder {
            let oldComps = MeetingService.folderComponents(renamingFolder.path)
            let activeComps = MeetingService.folderComponents(active)
            if activeComps.count >= oldComps.count, Array(activeComps.prefix(oldComps.count)) == oldComps {
                let rewritten = (newComponents + activeComps.dropFirst(oldComps.count)).joined(separator: "/")
                coordinator.showFolder(rewritten)
            }
        }
        self.renamingFolder = nil
    }

    /// The flat TAGS section (plan D9/M3). Hidden entirely when no meeting carries a tag, so the
    /// sidebar stays clean on a fresh install.
    @ViewBuilder
    private var tagsSection: some View {
        let tags = organizationIndex.tagCounts
        if !tags.isEmpty {
            Section(String(localized: "mainwindow.tags.section")) {
                ForEach(tags) { tag in
                    tagRow(tag)
                }
            }
        }
    }

    private func tagRow(_ tag: MeetingTagCount) -> some View {
        // Highlight from the coordinator's `activeTag` (not the route), so the row stays selected even
        // when the current route is `.folder` under folder+tag AND composition (plan D8).
        let isSelected = coordinator.activeTag?.lowercased() == tag.key
        return Button {
            // Pass the display name (not the case-folded key) so the filter header reads "#Hiring"
            // with the sidebar's casing, not a lowercased twin (M3 minor 1).
            coordinator.showTag(tag.name)
        } label: {
            HStack(spacing: 6) {
                Label("#\(tag.name)", systemImage: "tag")
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("\(tag.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .fontWeight(isSelected ? .semibold : .regular)
        .contextMenu {
            Button {
                renameText = tag.name
                renamingTag = tag
            } label: {
                Label(String(localized: "mainwindow.tags.rename"), systemImage: "pencil")
            }
            Button(role: .destructive) {
                viewModel.deleteTag(tag.name)
                // Deleting the currently-filtered tag would strand the route on an empty list
                // (M3 minor 2) — drop the filter.
                if coordinator.activeTag?.lowercased() == tag.key {
                    coordinator.clearTagFilter()
                }
            } label: {
                Label(String(localized: "mainwindow.tags.delete"), systemImage: "trash")
            }
        }
    }

    // MARK: - Folders (plan D9/M4)

    /// The FOLDERS tree section. Hidden entirely when there are no folders and nothing is Unfiled,
    /// so the sidebar stays clean on a fresh install.
    @ViewBuilder
    private var foldersSection: some View {
        let tree = organizationIndex.folderTree
        let unfiled = organizationIndex.unfiledCount
        if !tree.isEmpty || unfiled > 0 {
            Section(String(localized: "mainwindow.folders.section")) {
                ForEach(tree) { node in
                    folderRow(node)
                }
                if unfiled > 0 {
                    unfiledRow(count: unfiled)
                }
            }
        }
    }

    /// One folder node: a filter button with its descendant-inclusive count, nesting children in a
    /// `DisclosureGroup` when present. Returns `AnyView` because the tree is rendered recursively and
    /// an opaque `some View` cannot be defined in terms of itself.
    private func folderRow(_ node: MeetingFolderNode) -> AnyView {
        if node.children.isEmpty {
            return AnyView(folderLabel(node))
        }
        return AnyView(
            DisclosureGroup {
                ForEach(node.children) { child in
                    folderRow(child)
                }
            } label: {
                folderLabel(node)
            }
        )
    }

    private func folderLabel(_ node: MeetingFolderNode) -> some View {
        let isSelected = coordinator.activeFolder.map { MeetingService.normalizedFolderPath($0) == node.path } ?? false
        return Button {
            coordinator.showFolder(node.path)
        } label: {
            HStack(spacing: 6) {
                Label(node.name, systemImage: "folder")
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("\(node.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .fontWeight(isSelected ? .semibold : .regular)
        .contextMenu {
            Button {
                folderRenameText = node.name
                renamingFolder = node
            } label: {
                Label(String(localized: "mainwindow.folders.rename"), systemImage: "pencil")
            }
            Button(role: .destructive) {
                viewModel.deleteFolder(node.path)
                // Deleting the currently-filtered folder (or an ancestor of it) strands the route —
                // drop the folder filter.
                if let active = coordinator.activeFolder {
                    let activeComps = MeetingService.folderComponents(active)
                    let comps = MeetingService.folderComponents(node.path)
                    if activeComps.count >= comps.count, Array(activeComps.prefix(comps.count)) == comps {
                        coordinator.clearFolderFilter()
                    }
                }
            } label: {
                Label(String(localized: "mainwindow.folders.delete"), systemImage: "trash")
            }
        }
    }

    private func unfiledRow(count: Int) -> some View {
        HStack(spacing: 6) {
            Label(String(localized: "mainwindow.folders.unfiled"), systemImage: "tray")
                .frame(maxWidth: .infinity, alignment: .leading)
                .foregroundStyle(.secondary)
            Text("\(count)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func destinationButton(
        title: String,
        systemImage: String,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .fontWeight(isSelected ? .semibold : .regular)
    }

    /// Reserved injection point for Track E's Space section. Empty (and hidden) in Phase 1.
    @ViewBuilder
    private var spaceSection: some View {
        EmptyView()
    }
}
