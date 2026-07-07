import SwiftUI

/// The serif "Coming up" card at the top of the Home feed (plan Track C / D6). Lists the calendar's
/// current + upcoming events, each with a slim per-calendar **color bar** and a colored **dot +
/// calendar-name label** (color is never the row background — D6). Tapping a row opens that event's
/// meeting document (creating a `.scheduled` meeting if one doesn't exist yet), where the primary
/// "Start recording" button lives.
struct ComingUpCard: View {
    @ObservedObject private var viewModel = MeetingsViewModel.shared
    @ObservedObject private var coordinator = MainWindowCoordinator.shared
    @ObservedObject private var homeViewModel = HomeFeedViewModel.shared

    var body: some View {
        if viewModel.calendarAuthorizationStatus == .authorized, !viewModel.upcomingEvents.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text(String(localized: "home.comingUp.title"))
                    .font(.title2)
                    .fontDesign(.serif)
                    .fontWeight(.semibold)

                VStack(spacing: 6) {
                    ForEach(items) { item in
                        row(item)
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 14))
        }
    }

    private var items: [ComingUpItem] {
        homeViewModel.comingUp(
            from: viewModel.upcomingEvents,
            existingMeeting: { viewModel.existingMeeting(for: $0) }
        )
    }

    private func row(_ item: ComingUpItem) -> some View {
        Button {
            let meeting = viewModel.createMeeting(from: item.event)
            coordinator.openMeeting(id: meeting.id)
        } label: {
            HStack(alignment: .center, spacing: 12) {
                // Slim color bar in the calendar's color — never the row background (D6).
                RoundedRectangle(cornerRadius: 2)
                    .fill(item.color.swiftUIColor)
                    .frame(width: 3, height: 34)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(title(for: item.event))
                            .font(.body)
                            .fontDesign(.serif)
                            .lineLimit(1)
                        statusBadge(for: item)
                    }
                    HStack(spacing: 8) {
                        Text(item.event.startDate, format: .dateTime.weekday().hour().minute())
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        calendarLabel(for: item)
                    }
                }
                Spacer(minLength: 8)
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func title(for event: CalendarEventDTO) -> String {
        event.title.isEmpty ? String(localized: "meetings.calendar.untitledEvent") : event.title
    }

    /// Colored dot + calendar-name label (color as a small accent, never a fill behind the text).
    @ViewBuilder
    private func calendarLabel(for item: ComingUpItem) -> some View {
        if let name = item.event.calendarTitle, !name.isEmpty {
            HStack(spacing: 4) {
                Circle()
                    .fill(item.color.swiftUIColor)
                    .frame(width: 6, height: 6)
                Text(name)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func statusBadge(for item: ComingUpItem) -> some View {
        if item.isRunningLong {
            badge(String(localized: "home.badge.runningLong"), tint: .orange)
        } else {
            switch item.timeStatus {
            case .inProgress:
                badge(String(localized: "meetings.calendar.inProgress"), tint: .accentColor)
            case .endedRecently:
                badge(String(localized: "meetings.calendar.ended"), tint: .secondary)
            case .upcoming, .ended:
                EmptyView()
            }
        }
    }

    private func badge(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(tint.opacity(0.15), in: Capsule())
            .foregroundStyle(tint)
    }
}
