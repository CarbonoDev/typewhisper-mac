import SwiftUI

/// The `.spaceFolder` route body (Track E, ME-1): a **folder index** rendered in the redesign's
/// document shell — the same measure-limited column as `MeetingFolderDetailView`, on the **window
/// ground (no paper)**, deliberately withholding the meeting document's private signature (plan
/// D4/V10). Masthead: `MeetingKicker(["SPACE", "<N items>"])` + serif `pageTitle` folder name.
/// Children are `MeetingQuietRow`s (folders navigate deeper, notes open); an in-document item count
/// on folders is unambiguous (unlike a sidebar badge, plan D7). ME-1 is browse-only — note reading
/// and quick-note creation arrive in ME-2/ME-3.
struct SpaceFolderView: View {
    let path: String

    @ObservedObject private var viewModel = SpaceViewModel.shared
    @ObservedObject private var coordinator = MainWindowCoordinator.shared

    private var folderName: String {
        SpaceTreeModel.normalize(path).split(separator: "/").last.map(String.init)
            ?? (viewModel.vaultName ?? path)
    }

    var body: some View {
        // Build the child list **once** per body pass (a single recursive rebuild over the cached
        // snapshot), then read it three times below — count, emptiness, rows — instead of
        // recomputing the derived tree on each access (plan D6 / ME-1 review).
        let children = viewModel.children(of: path)
        return ScrollView {
            VStack(alignment: .leading, spacing: MeetingTheme.sectionGap) {
                if viewModel.isConnected {
                    header(children: children)
                    childrenSection(children: children)
                } else {
                    disconnectedState
                }
            }
            .padding(MeetingTheme.pagePadding)
            .frame(maxWidth: MeetingTheme.contentMaxWidth, alignment: .topLeading)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .navigationTitle(folderName)
        .toolbar {
            ToolbarItem {
                Button {
                    viewModel.refresh()
                } label: {
                    Label(String(localized: "space.refresh"), systemImage: "arrow.clockwise")
                }
            }
            if viewModel.isConnected {
                ToolbarItem {
                    Button {
                        viewModel.revealInFinder(path)
                    } label: {
                        // A reveal-oriented glyph, not the plain `folder` used for folder *objects* in
                        // the tree, so the toolbar action reads distinctly from tree content (ME-1
                        // design review). `arrow.up.forward.app` is reserved for the ME-2 "Open in
                        // Obsidian" family, so Reveal-in-Finder takes the search/locate glyph.
                        Label(String(localized: "space.reveal.finder"), systemImage: "magnifyingglass")
                    }
                }
            }
        }
        .onAppear { viewModel.refresh() }
    }

    // MARK: - Masthead

    private func header(children: [SpaceNode]) -> some View {
        VStack(alignment: .leading, spacing: MeetingTheme.s2) {
            MeetingKicker(parts: [
                String(localized: "space.kicker.space"),
                String(format: String(localized: "space.itemCount"), children.count),
            ])
            Text(folderName)
                .font(MeetingTheme.pageTitle)
        }
    }

    // MARK: - Children

    @ViewBuilder
    private func childrenSection(children: [SpaceNode]) -> some View {
        if children.isEmpty {
            MeetingEmptyStateCard(
                icon: "tray",
                title: String(localized: "space.folder.empty.title"),
                message: String(localized: "space.folder.empty.message")
            ) {
                EmptyView()
            }
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(children) { child in
                    MeetingQuietRow(
                        icon: child.isDirectory ? "folder" : "doc.text",
                        title: child.name,
                        detail: child.isDirectory
                            ? String(format: String(localized: "space.itemCount"), child.children.count)
                            : nil
                    ) {
                        if child.isDirectory {
                            coordinator.show(.spaceFolder(child.relativePath))
                        } else {
                            coordinator.show(.spaceNote(child.relativePath))
                        }
                    }
                }
            }
        }

        // Truncation is a **vault-index** fact, not a per-folder one: the cap bounds the whole cached
        // snapshot, so the footnote reports the snapshot size and renders even for an empty folder —
        // it no longer claims "showing the first N" of a fully-listed 3-item folder (ME-1 review).
        if viewModel.didTruncate {
            Text(String(format: String(localized: "space.truncated"), viewModel.entries.count))
                .font(MeetingTheme.footnote)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Disconnected (gated, plan D8)

    private var disconnectedState: some View {
        MeetingEmptyStateCard(
            icon: "externaldrive",
            title: String(localized: "space.disconnected.title"),
            message: String(localized: "space.disconnected.message")
        ) {
            Button(String(localized: "mainwindow.space.connect")) {
                viewModel.chooseVault()
            }
            .buttonStyle(.bordered)
        }
    }
}
