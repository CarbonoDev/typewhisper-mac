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
        .onAppear {
            viewModel.startCalendarPolling()
            // [M10] A focus request may have been queued before the window existed.
            if let pending = viewModel.pendingFocusMeetingID {
                selectedMeetingID = pending
                viewModel.consumeFocusRequest()
            }
        }
        .onDisappear { viewModel.stopCalendarPolling() }
        .onChange(of: viewModel.activeMeeting?.id) { _, newValue in
            if let newValue { selectedMeetingID = newValue }
        }
        .onChange(of: viewModel.pendingFocusMeetingID) { _, newValue in
            // [M10] Honour an external navigation request (e.g. "Start Meeting Recording" from the
            // menu bar, or opening a past meeting from the Earlier section), then clear it.
            guard let newValue else { return }
            selectedMeetingID = newValue
            viewModel.consumeFocusRequest()
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
                // [M10] Secondary ad-hoc affordance: start recording now, or create an empty meeting
                // (no capture) to attach imports/notes to later.
                Menu {
                    Button {
                        Task {
                            // Guarded create+start so a rapid double-click can't leave a stray empty
                            // meeting (M3 review finding 2).
                            if let meeting = await viewModel.createAndStartAdHocCapture() {
                                selectedMeetingID = meeting.id
                            }
                        }
                    } label: {
                        Label(String(localized: "meetings.newMeeting.startRecording"), systemImage: "record.circle")
                    }
                    .disabled(!viewModel.canStartCapture)

                    Button {
                        // Create without capturing; leaves the meeting `.scheduled` with no audio.
                        let meeting = viewModel.createAdHocMeeting()
                        selectedMeetingID = meeting.id
                    } label: {
                        Label(String(localized: "meetings.newMeeting.createEmpty"), systemImage: "doc.badge.plus")
                    }
                } label: {
                    Label(String(localized: "meetings.newMeeting"), systemImage: "plus")
                }
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
            // [Track B] The old detail/live split was retired into the single lifecycle document.
            // This legacy window (deleted by Track A at Step 2) now hosts the same document view.
            MeetingDocumentView(meeting: meeting)
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
