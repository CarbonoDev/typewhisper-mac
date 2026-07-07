import SwiftUI

/// Calendar-driven section of the Meetings settings tab (M2). Surfaces the current/upcoming
/// events and lets the user create a `.scheduled` meeting from one. Shows a permission prompt
/// when access is not yet granted, and a clear message when it has been denied.
struct UpcomingMeetingsSection: View {
    @ObservedObject private var viewModel = MeetingsViewModel.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(String(localized: "meetings.calendar.sectionTitle"))
                .font(.headline)

            switch viewModel.calendarAuthorizationStatus {
            case .notDetermined:
                permissionPrompt
            case .denied, .restricted:
                deniedState
            case .authorized:
                authorizedContent
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var permissionPrompt: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "meetings.calendar.accessExplanation"))
                .font(.callout)
                .foregroundStyle(.secondary)
            Button(String(localized: "meetings.calendar.grantAccess")) {
                Task { await viewModel.requestCalendarAccess() }
            }
        }
    }

    private var deniedState: some View {
        Label(
            viewModel.calendarErrorMessage ?? String(localized: "meetings.calendar.accessDenied"),
            systemImage: "exclamationmark.triangle"
        )
        .font(.callout)
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var authorizedContent: some View {
        if viewModel.upcomingEvents.isEmpty {
            Text(String(localized: "meetings.calendar.noUpcoming"))
                .font(.callout)
                .foregroundStyle(.secondary)
        } else {
            VStack(spacing: 8) {
                ForEach(viewModel.upcomingEvents) { event in
                    eventRow(event)
                }
            }
        }
    }

    private func eventRow(_ event: CalendarEventDTO) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(event.title.isEmpty ? String(localized: "meetings.calendar.untitledEvent") : event.title)
                        .font(.body)
                    if viewModel.isCurrent(event) {
                        Text(String(localized: "meetings.calendar.inProgress"))
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.accentColor.opacity(0.15), in: Capsule())
                            .foregroundStyle(Color.accentColor)
                    }
                }
                Text(event.startDate, format: .dateTime.weekday().hour().minute())
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(String(localized: "meetings.calendar.createMeeting")) {
                viewModel.createMeeting(from: event)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
    }
}
