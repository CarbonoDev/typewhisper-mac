import SwiftUI

/// Placeholder Meetings settings tab (M1). Shows an empty state until meetings exist; when
/// meetings are present (e.g. a debug-seeded one) it lists them. Capture, calendar, outputs,
/// and the standalone window arrive in later milestones.
struct MeetingsSettingsView: View {
    @ObservedObject private var viewModel = MeetingsViewModel.shared

    var body: some View {
        Group {
            if viewModel.hasMeetings {
                meetingsList
            } else {
                emptyState
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .navigationTitle(String(localized: "settings.tab.meetings"))
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label(String(localized: "meetings.emptyState.title"), systemImage: "person.2.wave.2")
        } description: {
            Text(String(localized: "meetings.emptyState.message"))
        }
    }

    private var meetingsList: some View {
        List(viewModel.meetings, id: \.id) { meeting in
            VStack(alignment: .leading, spacing: 4) {
                Text(meeting.title)
                    .font(.headline)
                HStack(spacing: 8) {
                    if let start = meeting.startDate {
                        Text(start, style: .date)
                    }
                    Text(meeting.state.rawValue)
                        .foregroundStyle(.secondary)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(.vertical, 2)
        }
    }
}
