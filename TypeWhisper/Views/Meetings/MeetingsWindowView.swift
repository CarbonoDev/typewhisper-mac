import SwiftUI

/// Standalone Meetings window (plan D16): a sidebar list of meetings plus a detail pane that shows
/// the live-capture surface for the active meeting or the read-only transcript for a stored one.
/// Opened via `ManagedAppWindowOpener.shared.open(id: "meetings")`.
struct MeetingsWindowView: View {
    @ObservedObject private var viewModel = MeetingsViewModel.shared
    @State private var selectedMeetingID: UUID?
    @State private var isPresentingImport = false

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        .onAppear { viewModel.startCalendarPolling() }
        .onDisappear { viewModel.stopCalendarPolling() }
        .onChange(of: viewModel.activeMeeting?.id) { _, newValue in
            if let newValue { selectedMeetingID = newValue }
        }
        .onChange(of: selectedMeetingID) { _, _ in
            // Per-meeting error/status banners are shared singleton state; clear them on switch so
            // one meeting's transient message doesn't render under another (finding 7).
            viewModel.clearTransientMessages()
        }
        .sheet(isPresented: $isPresentingImport) {
            MeetingImportView(mergeTarget: selectedMeeting) { meeting in
                selectedMeetingID = meeting.id
            }
        }
    }

    private var sidebar: some View {
        List(selection: $selectedMeetingID) {
            if let error = viewModel.captureErrorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            ForEach(viewModel.meetings, id: \.id) { meeting in
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
                .tag(meeting.id)
            }
        }
        .navigationTitle(String(localized: "meetings.window.title"))
        .toolbar {
            ToolbarItem {
                Button {
                    Task {
                        // Guarded create+start so a rapid double-click can't leave a stray empty
                        // meeting (M3 review finding 2).
                        if let meeting = await viewModel.createAndStartAdHocCapture() {
                            selectedMeetingID = meeting.id
                        }
                    }
                } label: {
                    Label(String(localized: "meetings.newMeeting"), systemImage: "plus")
                }
                .disabled(!viewModel.canStartCapture)
            }
            ToolbarItem {
                Button {
                    isPresentingImport = true
                } label: {
                    Label(String(localized: "meetings.import.toolbar"), systemImage: "square.and.arrow.down")
                }
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let meeting = selectedMeeting {
            if meeting.id == viewModel.activeMeeting?.id, viewModel.isCapturing {
                MeetingLiveCaptureView(meeting: meeting)
            } else {
                MeetingDetailView(meeting: meeting)
            }
        } else {
            ContentUnavailableView {
                Label(String(localized: "meetings.window.selectPrompt.title"), systemImage: "person.2.wave.2")
            } description: {
                Text(String(localized: "meetings.window.selectPrompt.message"))
            }
        }
    }

    private var selectedMeeting: Meeting? {
        guard let selectedMeetingID else { return nil }
        return viewModel.meetings.first { $0.id == selectedMeetingID }
    }
}
