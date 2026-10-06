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
///
/// [Perf Phase 2] Only the menu *content* lives on the row. Actions that need a dialog (rename,
/// delete, merge, new folder, link event) record a `MeetingRowPendingAction` on the list's
/// `MeetingRowActions`, and the list presents that one dialog — rows no longer mount their own
/// presenters, `@State`s, or observe `MeetingsViewModel` / `MainWindowCoordinator`.
struct MeetingRowContextMenu: View {
    let meetingID: UUID
    let actions: MeetingRowActions

    // Observed so the menu content tracks the selection (single vs bulk) and the folder / tag
    // index while it is mounted; the row it is attached to observes neither.
    @ObservedObject private var selection = MeetingSelectionModel.shared
    @ObservedObject private var organizationIndex = MeetingOrganizationIndex.shared

    private var viewModel: MeetingsViewModel { MeetingsViewModel.shared }

    private var mode: MeetingsViewModel.RowContextMenuMode {
        MeetingsViewModel.contextMenuMode(rightClicked: meetingID, selection: selection.ids)
    }

    /// The ids a menu action targets: the whole selection in bulk mode (in list order), else the
    /// right-clicked row.
    private var targetIDs: [UUID] {
        if case .bulk = mode { return selection.selectedMeetings(in: viewModel.meetings).map(\.id) }
        return [meetingID]
    }

    /// The live target meetings, resolved when an action runs.
    private var targets: [Meeting] { actions.meetings(for: targetIDs) }

    var body: some View {
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
            MainWindowCoordinator.shared.openMeeting(id: meetingID)
        }
        Button(String(localized: "meetings.menu.rename")) {
            actions.beginRename(meetingID)
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
            actions.pending = .linkEvent(meetingID)
        }
        Divider()
        Button(String(localized: "meetings.menu.delete"), role: .destructive) {
            actions.pending = .delete(targetIDs)
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
        // Merge duplicates (a caption-bridge meeting + its calendar twin, re-joins, overlapping
        // imports) into one. Disabled while any target is live/processing — stop the capture first.
        Button(String(format: String(localized: "meetings.menu.mergeCount"), count)) {
            actions.pending = .merge(targetIDs)
        }
        .disabled(!MeetingMergeService.canMerge(targets))
        Divider()
        Button(String(format: String(localized: "meetings.menu.deleteCount"), count), role: .destructive) {
            actions.pending = .delete(targetIDs)
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
                actions.beginNewFolder(targetIDs)
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
}

extension View {
    /// Attach the shared meeting-row right-click menu (plan LX-2, D4) for `meetingID`. Its dialogs are
    /// presented by the list that owns `actions` (`meetingRowActionPresenters`).
    func meetingRowContextMenu(for meetingID: UUID, actions: MeetingRowActions) -> some View {
        contextMenu { MeetingRowContextMenu(meetingID: meetingID, actions: actions) }
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
