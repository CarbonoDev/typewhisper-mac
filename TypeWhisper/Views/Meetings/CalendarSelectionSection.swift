import SwiftUI

/// Settings › Meetings › Calendars (M11). Lists every calendar from the user's macOS Calendar
/// accounts with its color dot, title and account name, and a per-calendar checkbox. Deselecting a
/// calendar hides its events everywhere in the feature (upcoming list, Earlier section, auto
/// briefs, start notifications, capture-context rules) because `CalendarService` filters at a
/// single choke point. New calendars default to selected.
struct CalendarSelectionSection: View {
    @ObservedObject private var viewModel = MeetingsViewModel.shared
    /// Local snapshot of the rows; reloaded from the view model on appear, when access is granted,
    /// and after each toggle (selection state is read from the service, not a `@Published`).
    @State private var rows: [CalendarSelectionRow] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(String(localized: "meetings.calendar.calendarsSection"))
                .font(.headline)

            if viewModel.isCalendarAuthorized {
                Text(String(localized: "meetings.calendar.calendarsExplanation"))
                    .font(.callout)
                    .foregroundStyle(.secondary)

                if rows.isEmpty {
                    Text(String(localized: "meetings.calendar.noCalendars"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    VStack(spacing: 4) {
                        ForEach(rows) { row in
                            calendarRow(row)
                        }
                    }
                }
            } else {
                Text(String(localized: "meetings.calendar.calendarsNeedsAccess"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear(perform: reload)
        .onChange(of: viewModel.calendarAuthorizationStatus) { _, _ in reload() }
    }

    private func calendarRow(_ row: CalendarSelectionRow) -> some View {
        Toggle(isOn: Binding(
            get: { row.isSelected },
            set: { newValue in
                viewModel.setCalendarSelected(newValue, for: row.calendar.id)
                reload()
            }
        )) {
            HStack(spacing: 8) {
                Circle()
                    .fill(row.calendar.color.swiftUIColor)
                    .frame(width: 10, height: 10)
                Text(row.calendar.title)
                if !row.calendar.sourceName.isEmpty {
                    Text(row.calendar.sourceName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .toggleStyle(.checkbox)
    }

    private func reload() {
        rows = viewModel.calendarSelectionRows()
    }
}
