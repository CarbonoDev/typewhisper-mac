import SwiftUI

/// Meetings settings tab. Shows the calendar-driven upcoming-meetings section (M2) above the
/// list of stored meetings, or an empty state when none exist yet. Capture, outputs, and the
/// standalone window arrive in later milestones.
struct MeetingsSettingsView: View {
    @ObservedObject private var viewModel = MeetingsViewModel.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                UpcomingMeetingsSection()

                Divider()

                if viewModel.hasMeetings {
                    meetingsList
                } else {
                    emptyState
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .navigationTitle(String(localized: "settings.tab.meetings"))
        .onAppear { viewModel.startCalendarPolling() }
        .onDisappear { viewModel.stopCalendarPolling() }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            ContentUnavailableView {
                Label(String(localized: "meetings.emptyState.title"), systemImage: "person.2.wave.2")
            } description: {
                Text(String(localized: "meetings.emptyState.message"))
            }

            #if DEBUG
            Button("Seed Demo Meeting") {
                viewModel.seedDemoMeeting()
            }
            .buttonStyle(.plain)
            .foregroundStyle(.orange)
            .font(.caption)
            #endif
        }
        .frame(maxWidth: .infinity)
    }

    private var meetingsList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "meetings.list.title"))
                .font(.headline)
            ForEach(viewModel.meetings, id: \.id) { meeting in
                VStack(alignment: .leading, spacing: 4) {
                    Text(meeting.title)
                        .font(.headline)
                    HStack(spacing: 8) {
                        if let start = meeting.startDate {
                            Text(start, style: .date)
                        }
                        Text(meeting.state.displayName)
                            .foregroundStyle(.secondary)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 2)
            }
        }
    }
}
