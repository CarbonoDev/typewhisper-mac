import SwiftUI

/// The persistent sidebar of the main window (UI Step 0, D3): a disabled search placeholder (P1),
/// Home + Meetings destinations, a reserved Space section slot (filled by Track E), a spacer, the
/// live-recording band, and a Settings gear that opens the Settings scene.
struct MainWindowSidebar: View {
    @ObservedObject private var coordinator = MainWindowCoordinator.shared

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

                // Phase 2 — Track E injects the `SPACE · OBSIDIAN` section here (hidden until then).
                spaceSection
            }
            .listStyle(.sidebar)

            Spacer(minLength: 0)

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

    /// True for the meetings list and any single meeting document (both live under "Meetings").
    private var isMeetingsRoute: Bool {
        switch coordinator.route {
        case .meetings, .meeting:
            return true
        default:
            return false
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
