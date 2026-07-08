import SwiftUI

/// The full meetings list shown for `MainWindowRoute.meetings` (UI Step 0, D3). Re-expresses the
/// row rendering and the New/Import toolbar menu of today's `MeetingsWindowView` sidebar, but routes
/// selections through `MainWindowCoordinator.shared` instead of a local `@State` selection.
///
/// Owner discoverability: the New Meeting menu carries a labeled "Import transcript or audio…" item
/// alongside Start recording / Create empty, and there is a dedicated Import toolbar button.
struct MeetingsListView: View {
    @ObservedObject private var viewModel = MeetingsViewModel.shared
    @ObservedObject private var coordinator = MainWindowCoordinator.shared
    @State private var isPresentingImport = false

    /// The meetings shown after applying the coordinator's active folder + tag filters, which
    /// compose (AND) (plan D8). No active filters = the full list.
    private var displayedMeetings: [Meeting] {
        MeetingsViewModel.filteredMeetings(
            viewModel.meetings,
            folder: coordinator.activeFolder,
            tag: coordinator.activeTag
        )
    }

    /// True while either filter is active (drives the combined header + filter-specific empty state).
    private var isFiltered: Bool {
        coordinator.activeFolder != nil || coordinator.activeTag != nil
    }

    var body: some View {
        List {
            if let error = viewModel.captureErrorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            if isFiltered {
                filterHeader
            }
            if displayedMeetings.isEmpty {
                if isFiltered {
                    filteredEmptyState
                } else {
                    emptyState
                }
            } else {
                ForEach(displayedMeetings, id: \.id) { meeting in
                    Button {
                        coordinator.openMeeting(id: meeting.id)
                    } label: {
                        row(meeting)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .navigationTitle(String(localized: "mainwindow.meetings.title"))
        .toolbar {
            ToolbarItem {
                newMeetingMenu
            }
            ToolbarItem {
                Button {
                    isPresentingImport = true
                } label: {
                    Label(String(localized: "meetings.import.toolbar"), systemImage: "square.and.arrow.down")
                }
            }
        }
        .sheet(isPresented: $isPresentingImport) {
            MeetingImportView(mergeTarget: nil) { meeting in
                coordinator.openMeeting(id: meeting.id)
            }
        }
    }

    private var newMeetingMenu: some View {
        Menu {
            Button {
                Task {
                    // Guarded create+start so a rapid double-click can't leave a stray empty meeting.
                    if let meeting = await viewModel.createAndStartAdHocCapture() {
                        coordinator.openMeeting(id: meeting.id)
                    }
                }
            } label: {
                Label(String(localized: "meetings.newMeeting.startRecording"), systemImage: "record.circle")
            }
            .disabled(!viewModel.canStartCapture)

            Button {
                let meeting = viewModel.createAdHocMeeting()
                coordinator.openMeeting(id: meeting.id)
            } label: {
                Label(String(localized: "meetings.newMeeting.createEmpty"), systemImage: "doc.badge.plus")
            }

            Divider()

            Button {
                isPresentingImport = true
            } label: {
                Label(String(localized: "mainwindow.newMeeting.import"), systemImage: "square.and.arrow.down")
            }
        } label: {
            Label(String(localized: "meetings.newMeeting"), systemImage: "plus")
        }
    }

    /// The "Filtered by 📁 path · #tag ✕ Clear" header shown above the list when either filter is
    /// active (plan D8). Each active facet is individually clearable; Clear resets both.
    private var filterHeader: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Text(String(localized: "mainwindow.meetings.filteredBy"))
                    .font(.callout)
                if let folder = coordinator.activeFolder {
                    facet(icon: "folder", text: folder) { coordinator.clearFolderFilter() }
                }
                if let tag = coordinator.activeTag {
                    facet(icon: "tag", text: "#\(tag)") { coordinator.clearTagFilter() }
                }
            }
            Spacer()
            Button {
                coordinator.clearAllFilters()
            } label: {
                Label(String(localized: "mainwindow.meetings.filter.clear"), systemImage: "xmark.circle.fill")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    /// One clearable filter facet capsule (folder or tag).
    private func facet(icon: String, text: String, onClear: @escaping () -> Void) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
            Text(text).fontWeight(.semibold)
            Button(action: onClear) {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .font(.callout)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(.secondary.opacity(0.12), in: Capsule())
    }

    /// Filter-specific empty state (M3 minor 4): a tag/folder filter that matches nothing must not
    /// show the generic "record your first meeting" prompt.
    private var filteredEmptyState: some View {
        ContentUnavailableView {
            Label(String(localized: "mainwindow.meetings.empty.filtered.title"), systemImage: "line.3.horizontal.decrease.circle")
        } description: {
            Text(String(localized: "mainwindow.meetings.empty.filtered.message"))
        } actions: {
            Button {
                coordinator.clearAllFilters()
            } label: {
                Text(String(localized: "mainwindow.meetings.filter.clear"))
            }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label(String(localized: "mainwindow.meetings.empty.title"), systemImage: "person.2.wave.2")
        } description: {
            Text(String(localized: "mainwindow.meetings.empty.message"))
        } actions: {
            Button {
                isPresentingImport = true
            } label: {
                Text(String(localized: "mainwindow.newMeeting.import"))
            }
        }
    }

    private func row(_ meeting: Meeting) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(meeting.title)
                .lineLimit(1)
            HStack(spacing: 6) {
                if meeting.id == viewModel.activeMeeting?.id, viewModel.isCapturing {
                    Image(systemName: "record.circle")
                        .foregroundStyle(.red)
                }
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
    }
}
