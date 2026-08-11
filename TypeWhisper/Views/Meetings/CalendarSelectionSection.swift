import SwiftUI

/// Settings › Meetings › Calendars (M11, [Google Phase 1 · M4]). Lists every calendar from the
/// fanned-in providers with its color dot and a per-calendar checkbox, grouped by source: one
/// group per macOS Calendar source (EventKit keeps its current source labels) plus one group per
/// connected Google account (headed by the account email — the "split by account" attribution,
/// D-G4). Deselecting a calendar hides its events everywhere in the feature (upcoming list,
/// Earlier section, auto briefs, start notifications, capture-context rules) because
/// `CalendarService` filters at a single choke point. New calendars default to selected.
///
/// The section always renders its per-source groups — a Google-only user (EventKit denied) still
/// manages per-account selection here; the needs-access hint is scoped to the macOS group only.
struct CalendarSelectionSection: View {
    @ObservedObject private var viewModel = MeetingsViewModel.shared
    /// Local snapshot of the rows; reloaded from the view model on appear, on authorization
    /// changes, on Google snapshot changes, and after each toggle (selection state is read from
    /// the service, not a `@Published`).
    @State private var rows: [CalendarSelectionRow] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(String(localized: "meetings.calendar.calendarsSection"))
                .font(.headline)

            Text(String(localized: "meetings.calendar.calendarsExplanation"))
                .font(.callout)
                .foregroundStyle(.secondary)

            let groups = CalendarSelectionGrouping.groups(from: rows)
            let macGroups = groups.filter { !$0.isGoogle }
            let googleGroups = groups.filter(\.isGoogle)

            // macOS side first: the real per-source groups when EventKit is authorized, otherwise
            // a single macOS-labeled group carrying the needs-access hint ([Google Phase 1 · M4]:
            // the hint is scoped here so per-account Google selection below stays usable for
            // Google-only users).
            if viewModel.isCalendarAuthorized {
                if macGroups.isEmpty && googleGroups.isEmpty {
                    Text(String(localized: "meetings.calendar.noCalendars"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(macGroups) { group in
                        groupView(group)
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    groupHeader(String(localized: "meetings.calendar.macosGroup"))
                    Text(String(localized: "meetings.calendar.calendarsNeedsAccess"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            ForEach(googleGroups) { group in
                groupView(group)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear(perform: reload)
        .onChange(of: viewModel.calendarAuthorizationStatus) { _, _ in reload() }
        // A freshly connected account's calendars appear as soon as its first sync lands (D-G7);
        // a disconnect empties its group the same way.
        .onReceive(NotificationCenter.default.publisher(for: .googleCalendarSnapshotDidChange)) { _ in
            reload()
        }
    }

    // MARK: - Groups

    private func groupView(_ group: CalendarSelectionGroup) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            groupHeader(
                group.sourceName.isEmpty
                    ? String(localized: "meetings.calendar.macosGroup")
                    : group.sourceName
            )
            ForEach(group.rows) { row in
                calendarRow(row)
            }
        }
    }

    private func groupHeader(_ title: String) -> some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.top, 2)
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
            }
        }
        .toggleStyle(.checkbox)
    }

    private func reload() {
        rows = viewModel.calendarSelectionRows()
    }
}

/// One rendered group of the Calendars list: a source (macOS Calendar account or Google account
/// email) with its calendars. Pure value type so the grouping is unit-testable without SwiftUI
/// (`CalendarSelectionGroupingTests`).
struct CalendarSelectionGroup: Identifiable, Equatable {
    /// `CalendarInfo.sourceName`: the EventKit `EKSource.title`, or the Google account email.
    let sourceName: String
    /// Whether this group's calendars came from the Google provider (D-G3 namespaced IDs).
    let isGoogle: Bool
    let rows: [CalendarSelectionRow]
    /// Disambiguated by side, so an EventKit CalDAV source literally titled with the account
    /// email never collides with the Google account's own group.
    var id: String { (isGoogle ? "google|" : "macos|") + sourceName }
}

/// Pure grouping of the flat selection rows by source ([Google Phase 1 · M4]). Rows arrive sorted
/// by source then title (`MeetingsViewModel.makeCalendarRows`); groups preserve that order within
/// each side and list every macOS source before the Google accounts.
enum CalendarSelectionGrouping {
    static func groups(from rows: [CalendarSelectionRow]) -> [CalendarSelectionGroup] {
        var order: [String] = []
        var sides: [String: Bool] = [:]
        var names: [String: String] = [:]
        var buckets: [String: [CalendarSelectionRow]] = [:]
        for row in rows {
            let isGoogle = GoogleCalendarID.accountSub(fromNamespacedID: row.calendar.id) != nil
            let key = (isGoogle ? "google|" : "macos|") + row.calendar.sourceName
            if buckets[key] == nil {
                order.append(key)
                sides[key] = isGoogle
                names[key] = row.calendar.sourceName
            }
            buckets[key, default: []].append(row)
        }
        let all = order.map { key in
            CalendarSelectionGroup(
                sourceName: names[key] ?? "",
                isGoogle: sides[key] ?? false,
                rows: buckets[key] ?? []
            )
        }
        return all.filter { !$0.isGoogle } + all.filter(\.isGoogle)
    }
}
