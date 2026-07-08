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

                // First-party TAGS (plan D9/M3): a flat, count-annotated list derived in
                // `MeetingOrganizationIndex`; rows filter the meetings list, context menus rename/delete
                // in bulk.
                tagsSection

                // Phase 2 — Track E injects the `SPACE · OBSIDIAN` section here (hidden until then).
                spaceSection
            }
            .listStyle(.sidebar)
            .alert(String(localized: "mainwindow.tags.rename.title"), isPresented: isRenamingBinding) {
                TextField(String(localized: "mainwindow.tags.rename.placeholder"), text: $renameText)
                Button(String(localized: "mainwindow.tags.rename.cancel"), role: .cancel) {
                    renamingTag = nil
                }
                Button(String(localized: "mainwindow.tags.rename.confirm")) {
                    if let renamingTag {
                        viewModel.renameTag(renamingTag.name, to: renameText)
                    }
                    renamingTag = nil
                }
            } message: {
                Text(String(localized: "mainwindow.tags.rename.message"))
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
    private var isRenamingBinding: Binding<Bool> {
        Binding(
            get: { renamingTag != nil },
            set: { if !$0 { renamingTag = nil } }
        )
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
        let isSelected: Bool = {
            if case let .tag(active) = coordinator.route { return active.lowercased() == tag.key }
            return false
        }()
        return Button {
            coordinator.showTag(tag.key)
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
            } label: {
                Label(String(localized: "mainwindow.tags.delete"), systemImage: "trash")
            }
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
