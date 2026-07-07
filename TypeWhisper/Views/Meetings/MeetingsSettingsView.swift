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

                vaultSection

                Divider()

                if viewModel.hasMeetings {
                    meetingsList
                } else {
                    emptyState
                }

                Divider()

                MeetingTemplateEditorView()
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .navigationTitle(String(localized: "settings.tab.meetings"))
        .onAppear { viewModel.startCalendarPolling() }
        .onDisappear { viewModel.stopCalendarPolling() }
    }

    /// Obsidian knowledge-base connection (M5): connection state plus auto-detect / pick / forget.
    private var vaultSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "meetings.vault.sectionTitle"))
                .font(.headline)

            if viewModel.isVaultConnected {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text(String(
                        format: String(localized: "meetings.vault.connected"),
                        viewModel.vaultName ?? ""
                    ))
                    Spacer()
                    Button(String(localized: "meetings.vault.disconnect")) {
                        viewModel.disconnectVault()
                    }
                }
                .font(.callout)
            } else {
                Text(String(localized: "meetings.vault.notConnected"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Button(String(localized: "meetings.vault.autoDetect")) {
                        _ = viewModel.autoConnectVault()
                    }
                    Button(String(localized: "meetings.vault.chooseButton")) {
                        viewModel.chooseVault()
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
