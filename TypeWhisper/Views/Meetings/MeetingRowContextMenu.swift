import SwiftUI

/// The shared right-click menu for a meeting row (plan LX-2, D4). Attached to BOTH the reusable
/// `MeetingTimelineList` row (used by the folder detail page) and the `MeetingsListView` row, so the
/// identical actions appear on the Meetings list and the folder detail page — the single place row
/// treatment lives. Branches single-vs-multi exactly like `HistoryView.recordContextMenu(for:)`
/// through the pure `MeetingsViewModel.contextMenuMode`: a right-click inside a multi-selection shows
/// count-aware bulk actions over the selection; otherwise the single-row menu.
///
/// Rename reuses the identity milestone's title editing (`MeetingsViewModel.renameMeeting` →
/// `MeetingService.setTitle`) via an alert; delete uses a count-aware confirmation; folder/tag
/// submenus are built from `MeetingOrganizationIndex`; "Link to calendar event…" reuses the identity
/// milestone's `MeetingLinkEventView` picker. Long-running actions (generate / export) enqueue jobs;
/// instant mutations (folder / tag) are synchronous single-saves.
struct MeetingRowContextMenu: ViewModifier {
    let meeting: Meeting

    @ObservedObject private var viewModel = MeetingsViewModel.shared
    @ObservedObject private var coordinator = MainWindowCoordinator.shared
    @ObservedObject private var organizationIndex = MeetingOrganizationIndex.shared

    @State private var isRenaming = false
    @State private var renameText = ""
    @State private var isConfirmingDelete = false
    @State private var isPresentingNewFolder = false
    @State private var newFolderText = ""
    @State private var isPresentingLinkEvent = false

    private var mode: MeetingsViewModel.RowContextMenuMode {
        MeetingsViewModel.contextMenuMode(rightClicked: meeting.id, selection: viewModel.selectedMeetingIDs)
    }

    /// The meetings a menu action targets: the whole selection in bulk mode, else the right-clicked
    /// row. Using the `[Meeting]` service overloads for both keeps single + bulk one code path.
    private var targets: [Meeting] {
        if case .bulk = mode { return viewModel.selectedMeetings() }
        return [meeting]
    }

    func body(content: Content) -> some View {
        content
            .contextMenu { menu }
            .alert(String(localized: "meetings.menu.rename.title"), isPresented: $isRenaming) {
                TextField(String(localized: "meetings.menu.rename.placeholder"), text: $renameText)
                Button(String(localized: "meetings.menu.rename.confirm")) {
                    viewModel.renameMeeting(meeting, to: renameText)
                }
                Button(String(localized: "Cancel"), role: .cancel) {}
            }
            .confirmationDialog(deleteTitle, isPresented: $isConfirmingDelete, titleVisibility: .visible) {
                Button(deleteConfirmLabel, role: .destructive) {
                    viewModel.deleteMeetings(targets)
                }
                Button(String(localized: "Cancel"), role: .cancel) {}
            } message: {
                Text(deleteMessage)
            }
            .alert(String(localized: "meetings.menu.newFolder.title"), isPresented: $isPresentingNewFolder) {
                TextField(String(localized: "meetings.menu.newFolder.placeholder"), text: $newFolderText)
                Button(String(localized: "meetings.menu.newFolder.confirm")) {
                    let trimmed = newFolderText.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty { viewModel.setMeetingFolder(trimmed, for: targets) }
                    newFolderText = ""
                }
                Button(String(localized: "Cancel"), role: .cancel) { newFolderText = "" }
            }
            .sheet(isPresented: $isPresentingLinkEvent) {
                MeetingLinkEventView(meeting: meeting, isPresented: $isPresentingLinkEvent)
            }
    }

    // MARK: - Menu content

    @ViewBuilder
    private var menu: some View {
        switch mode {
        case .single:
            singleMenu
        case let .bulk(count):
            bulkMenu(count: count)
        }
    }

    @ViewBuilder
    private var singleMenu: some View {
        Button(String(localized: "meetings.menu.open")) {
            coordinator.openMeeting(id: meeting.id)
        }
        Button(String(localized: "meetings.menu.rename")) {
            renameText = meeting.title
            isRenaming = true
        }
        Divider()
        setFolderMenu(title: String(localized: "meetings.menu.setFolder"))
        addTagMenu
        removeTagMenu
        Divider()
        Button(String(localized: "meetings.menu.generateSummary")) {
            viewModel.generateSummaries(for: targets)
        }
        Button(String(localized: "meetings.menu.generateBrief")) {
            viewModel.generateBriefs(for: targets)
        }
        Button(String(localized: "meetings.menu.export")) {
            viewModel.exportToVault(targets)
        }
        Divider()
        Button(String(localized: "meetings.menu.linkEvent")) {
            isPresentingLinkEvent = true
        }
        Divider()
        Button(String(localized: "meetings.menu.delete"), role: .destructive) {
            isConfirmingDelete = true
        }
    }

    @ViewBuilder
    private func bulkMenu(count: Int) -> some View {
        setFolderMenu(title: String(localized: "meetings.menu.moveToFolder"))
        addTagMenu
        removeTagMenu
        Divider()
        Button(String(format: String(localized: "meetings.menu.generateSummaries"), count)) {
            viewModel.generateSummaries(for: targets)
        }
        Button(String(format: String(localized: "meetings.menu.generateBriefs"), count)) {
            viewModel.generateBriefs(for: targets)
        }
        Button(String(format: String(localized: "meetings.menu.exportCount"), count)) {
            viewModel.exportToVault(targets)
        }
        Divider()
        Button(String(format: String(localized: "meetings.menu.deleteCount"), count), role: .destructive) {
            isConfirmingDelete = true
        }
    }

    // MARK: - Folder submenu (from the derived folder tree + Unfiled + New folder…)

    private func setFolderMenu(title: String) -> some View {
        Menu(title) {
            Button(String(localized: "mainwindow.folders.unfiled")) {
                viewModel.setMeetingFolder(nil, for: targets)
            }
            Divider()
            FolderSubmenuItems(nodes: organizationIndex.folderTree) { path in
                viewModel.setMeetingFolder(path, for: targets)
            }
            Divider()
            Button(String(localized: "meetings.menu.newFolder")) {
                newFolderText = ""
                isPresentingNewFolder = true
            }
        }
    }

    // MARK: - Tag submenus (from the derived tag index)

    @ViewBuilder
    private var addTagMenu: some View {
        Menu(String(localized: "meetings.menu.addTag")) {
            if organizationIndex.tagCounts.isEmpty {
                Text(String(localized: "meetings.menu.noTags"))
            } else {
                ForEach(organizationIndex.tagCounts) { tag in
                    Button("#\(tag.name)") { viewModel.addMeetingTag(tag.name, to: targets) }
                }
            }
        }
    }

    @ViewBuilder
    private var removeTagMenu: some View {
        let removable = removableTags
        Menu(String(localized: "meetings.menu.removeTag")) {
            if removable.isEmpty {
                Text(String(localized: "meetings.menu.noTags"))
            } else {
                ForEach(removable, id: \.self) { tag in
                    Button("#\(tag)") { viewModel.removeMeetingTag(tag, from: targets) }
                }
            }
        }
    }

    /// The tags offered for removal: the target meetings' own tags (the union across the selection in
    /// bulk mode), case-folded-deduped and sorted, so "Remove tag" only lists tags actually present.
    private var removableTags: [String] {
        var seen = Set<String>()
        var result: [String] = []
        for meeting in targets {
            for tag in meeting.tags {
                if seen.insert(tag.lowercased()).inserted { result.append(tag) }
            }
        }
        return result.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    // MARK: - Delete confirmation copy (count-aware)

    private var deleteTitle: String {
        if case .bulk = mode { return String(localized: "meetings.menu.delete.title.count") }
        return String(localized: "meetings.menu.delete.title")
    }

    private var deleteConfirmLabel: String {
        switch mode {
        case .single:
            return String(localized: "meetings.menu.delete")
        case let .bulk(count):
            return String(format: String(localized: "meetings.menu.deleteCount"), count)
        }
    }

    private var deleteMessage: String {
        switch mode {
        case .single:
            return String(format: String(localized: "meetings.menu.delete.message"), meeting.title)
        case let .bulk(count):
            return String(format: String(localized: "meetings.menu.delete.message.count"), count)
        }
    }
}

extension View {
    /// Attach the shared meeting-row right-click menu (plan LX-2, D4) for `meeting`.
    func meetingRowContextMenu(for meeting: Meeting) -> some View {
        modifier(MeetingRowContextMenu(meeting: meeting))
    }
}

/// Recursive folder-tree submenu (plan LX-2, D4). A named View type so the self-reference is through a
/// nominal type inside a `Menu`'s content builder — a plain recursive `@ViewBuilder func` would try to
/// define its opaque return type in terms of itself, which the compiler rejects. A folder with children
/// becomes a submenu whose own "This Folder" row sets that folder (so a parent path is itself
/// selectable); leaves are plain buttons.
private struct FolderSubmenuItems: View {
    let nodes: [MeetingFolderNode]
    let onPick: (String) -> Void

    var body: some View {
        ForEach(nodes) { node in
            if node.children.isEmpty {
                Button(node.name) { onPick(node.path) }
            } else {
                Menu(node.name) {
                    Button(String(localized: "meetings.menu.folder.thisFolder")) { onPick(node.path) }
                    Divider()
                    FolderSubmenuItems(nodes: node.children, onPick: onPick)
                }
            }
        }
    }
}
