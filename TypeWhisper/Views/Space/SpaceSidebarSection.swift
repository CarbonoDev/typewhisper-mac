import SwiftUI

/// The reserved `SPACE · OBSIDIAN` sidebar section (Track E, ME-1), injected at the sanctioned
/// `spaceSection` slot below the first-party Folders/Tags. It **mirrors `foldersSection`
/// structurally** — a `Section` of recursive `DisclosureGroup` rows — but **diverges behaviorally**:
/// first-party rows *filter* the meetings list, Space rows *navigate* the detail pane to a vault
/// projection. The two hierarchies are told apart by a system, not a label (plan D7): a separate
/// section, and — the cheap disambiguator — **no count badges** (the grey number means *meetings*).
///
/// Gated on a connected vault (plan §2.3, D8): disconnected, the section stays present but shows one
/// inert "Connect a vault…" row so the feature is discoverable.
struct SpaceSidebarSection: View {
    @ObservedObject private var viewModel = SpaceViewModel.shared
    @ObservedObject private var coordinator = MainWindowCoordinator.shared

    var body: some View {
        Section(String(localized: "mainwindow.space.section")) {
            if viewModel.isConnected {
                ForEach(viewModel.tree) { node in
                    spaceRow(node)
                }
            } else {
                connectRow
            }
        }
    }

    /// One vault node: a plain navigate button, nesting children in a `DisclosureGroup` when the
    /// folder has any. Returns `AnyView` because the tree renders recursively (an opaque `some View`
    /// cannot be defined in terms of itself) — same shape as `MainWindowSidebar.folderRow`.
    private func spaceRow(_ node: SpaceNode) -> AnyView {
        if node.isDirectory, !node.children.isEmpty {
            return AnyView(
                DisclosureGroup {
                    ForEach(node.children) { child in
                        spaceRow(child)
                    }
                } label: {
                    spaceLabel(node)
                }
            )
        }
        return AnyView(spaceLabel(node))
    }

    /// A single Space row: icon + display name, **no trailing count** (plan D7). Folders navigate to
    /// `.spaceFolder`, notes to `.spaceNote`; highlight is pure route equality (`SpaceSelection`).
    private func spaceLabel(_ node: SpaceNode) -> some View {
        let isSelected = node.isDirectory
            ? SpaceSelection.isSpaceFolderSelected(node.relativePath, route: coordinator.route)
            : SpaceSelection.isSpaceNoteSelected(node.relativePath, route: coordinator.route)
        return Button {
            if node.isDirectory {
                coordinator.show(.spaceFolder(node.relativePath))
            } else {
                coordinator.show(.spaceNote(node.relativePath))
            }
        } label: {
            Label(node.name, systemImage: node.isDirectory ? "folder" : "doc.text")
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .fontWeight(isSelected ? .semibold : .regular)
    }

    /// The inert disconnected affordance: connect the single shared vault (no second picker).
    private var connectRow: some View {
        Button {
            viewModel.chooseVault()
        } label: {
            Label(
                String(localized: "mainwindow.space.connect"),
                systemImage: "externaldrive.badge.plus"
            )
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
    }
}
