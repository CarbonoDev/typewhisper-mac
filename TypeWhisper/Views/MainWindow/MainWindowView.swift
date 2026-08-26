import SwiftUI

/// Root of the meetings-first main window (UI Step 0, D3). A `NavigationSplitView` with the
/// persistent `MainWindowSidebar` and a detail pane driven by `MainWindowCoordinator.shared.route`.
///
/// The shell bridges the **existing** focus mechanism (`MeetingsViewModel.pendingFocusMeetingID` /
/// `consumeFocusRequest()`) exactly as `MeetingsWindowView` does today, so the menu-bar
/// "Start Meeting Recording" and the meeting-start notification path need zero changes beyond
/// retargeting the window id.
struct MainWindowView: View {
    @ObservedObject private var coordinator = MainWindowCoordinator.shared
    @ObservedObject private var viewModel = MeetingsViewModel.shared

    var body: some View {
        NavigationSplitView {
            MainWindowSidebar()
        } detail: {
            detail
        }
        .onAppear {
            viewModel.startCalendarPolling()
            // A focus request may have been queued before the window existed.
            bridgeFocus(viewModel.pendingFocusMeetingID)
        }
        .onDisappear { viewModel.stopCalendarPolling() }
        .onChange(of: viewModel.activeMeeting?.id) { _, newValue in
            if let newValue { coordinator.route = .meeting(newValue) }
        }
        .onChange(of: viewModel.pendingFocusMeetingID) { _, newValue in
            // Honour an external navigation request (menu-bar "Start Meeting Recording", opening a
            // past meeting), then clear it.
            bridgeFocus(newValue)
        }
        .onChange(of: routedMeetingID) { _, _ in
            // Per-meeting error/status banners are shared singleton state; clear them on switch so
            // one meeting's transient message doesn't render under another.
            viewModel.clearTransientMessages()
        }
    }

    private func bridgeFocus(_ pendingID: UUID?) {
        guard let route = MainWindowCoordinator.focusRoute(forPendingMeetingID: pendingID) else {
            return
        }
        coordinator.route = route
        viewModel.consumeFocusRequest()
    }

    private var routedMeetingID: UUID? {
        if case let .meeting(id) = coordinator.route { return id }
        return nil
    }

    @ViewBuilder
    private var detail: some View {
        switch coordinator.route {
        case .home:
            HomeFeedView()
        case .meetings, .tag, .unfiled:
            // All render the same list; `MeetingsListView` applies the coordinator's `activeFolder`,
            // `unfiledOnly`, and `activeTag` filters (which compose AND) and shows the combined Clear
            // header (D8). `.unfiled` scopes to meetings with no folder so they can be organized.
            MeetingsListView()
        case let .folder(path):
            // M7 (Amendment 1, DA7): the `.folder` route re-targets a Granola-style detail view —
            // description, the folder's meetings, and the attached vault-context section.
            MeetingFolderDetailView(folderPath: path)
        case let .meeting(id):
            if let meeting = viewModel.meetings.first(where: { $0.id == id }) {
                MeetingDocumentView(meeting: meeting)
            } else {
                unavailable
            }
        case let .spaceFolder(path):
            // Track E (ME-1): the vault folder index in the document shell.
            SpaceFolderView(path: path)
        case let .spaceNote(path):
            // Track E: the vault note. ME-1 stub (document-shell placeholder); reader lands in ME-2.
            SpaceNoteView(path: path)
        }
    }

    private var unavailable: some View {
        ContentUnavailableView {
            Label(String(localized: "mainwindow.selectPrompt.title"), systemImage: "person.2.wave.2")
        } description: {
            Text(String(localized: "mainwindow.selectPrompt.message"))
        }
    }
}
