import SwiftUI

/// Calendar-driven section of the Meetings settings tab (M2). Surfaces the current/upcoming
/// events and lets the user create a `.scheduled` meeting from one. Shows a permission prompt
/// when access is not yet granted, and a clear message when it has been denied.
struct UpcomingMeetingsSection: View {
    @ObservedObject private var viewModel = MeetingsViewModel.shared
    /// [M10] The "Earlier" (past events, lookback) section is collapsed by default so the primary
    /// visual focus stays on current + upcoming.
    @State private var isEarlierExpanded = false

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
        // [Track D] Surface the auto-brief scheduler's coarse status (plan AD9): a neutral caption
        // while a pre-meeting brief is being prepared, nothing when idle.
        if let status = viewModel.autoBriefStatusMessage {
            Label(status, systemImage: "sparkles")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        // [M10] Collapsible "Earlier" section: past events from today's lookback window, scrollable,
        // so the user can still create a meeting or open the linked one from a past event.
        earlierSection
    }

    // MARK: - Upcoming / current / overrunning row

    private func eventRow(_ event: CalendarEventDTO) -> some View {
        HStack(alignment: .center, spacing: 12) {
            // [M11] Color bar in the owning calendar's color, matching macOS Calendar.
            calendarColorBar(for: event)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(event.title.isEmpty ? String(localized: "meetings.calendar.untitledEvent") : event.title)
                        .font(.body)
                    statusBadge(for: event)
                }
                Text(event.startDate, format: .dateTime.weekday().hour().minute())
                    .font(.caption)
                    .foregroundStyle(.secondary)
                // [M11] Small calendar-name label so the source is visible like in macOS Calendar.
                calendarLabel(for: event)
                // [Track D] Surface a ready auto-generated pre-meeting brief (plan AD9).
                if viewModel.hasFreshBrief(for: event) {
                    Label(
                        String(localized: "meetings.brief.auto.briefReadyBadge"),
                        systemImage: "doc.text.magnifyingglass"
                    )
                    .font(.caption2)
                    .foregroundStyle(.green)
                }
            }
            Spacer()
            // [M10] Let the user dismiss an overrunning (recently-ended) event that they don't want
            // to record, without waiting out the grace window.
            if viewModel.timeStatus(for: event) == .endedRecently {
                Button {
                    viewModel.dismissEvent(event)
                } label: {
                    Image(systemName: "xmark.circle")
                }
                .buttonStyle(.borderless)
                .help(String(localized: "meetings.calendar.dismiss"))
            }
            Button(String(localized: "meetings.calendar.createMeeting")) {
                viewModel.createMeeting(from: event)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
    }

    /// [M10] "In progress" for a running event; "ended" (badged) for an overrunning/recently-ended
    /// one that is still shown so a meeting the user is on that ran long doesn't vanish.
    @ViewBuilder
    private func statusBadge(for event: CalendarEventDTO) -> some View {
        switch viewModel.timeStatus(for: event) {
        case .inProgress:
            badge(String(localized: "meetings.calendar.inProgress"), tint: .accentColor)
        case .endedRecently:
            badge(String(localized: "meetings.calendar.ended"), tint: .secondary)
        case .upcoming, .ended:
            EmptyView()
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

    // MARK: - [M11] Calendar color coding + label

    /// A vertical bar in the owning calendar's color (matching macOS Calendar's event coloring).
    /// A fixed-size clear bar keeps row heights aligned when the color is unknown.
    @ViewBuilder
    private func calendarColorBar(for event: CalendarEventDTO) -> some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(event.calendarColor?.swiftUIColor ?? .clear)
            .frame(width: 4, height: 32)
    }

    /// A small dot + calendar-name label so the event's source calendar is visible, like macOS
    /// Calendar. Renders nothing when the calendar name is unknown.
    @ViewBuilder
    private func calendarLabel(for event: CalendarEventDTO) -> some View {
        if let name = event.calendarTitle, !name.isEmpty {
            HStack(spacing: 4) {
                if let color = event.calendarColor {
                    Circle()
                        .fill(color.swiftUIColor)
                        .frame(width: 6, height: 6)
                }
                Text(name)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Earlier (past events) section

    @ViewBuilder
    private var earlierSection: some View {
        if !viewModel.earlierEvents.isEmpty {
            DisclosureGroup(isExpanded: $isEarlierExpanded) {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(viewModel.earlierEvents) { event in
                            earlierRow(event)
                        }
                    }
                    .padding(.top, 4)
                }
                .frame(maxHeight: 240)
            } label: {
                Text(String(localized: "meetings.calendar.earlierSection"))
                    .font(.subheadline)
            }
            .padding(.top, 4)
        }
    }

    private func earlierRow(_ event: CalendarEventDTO) -> some View {
        let existing = viewModel.existingMeeting(for: event)
        return HStack(alignment: .center, spacing: 12) {
            // [M11] Color bar in the owning calendar's color, matching macOS Calendar.
            calendarColorBar(for: event)
            VStack(alignment: .leading, spacing: 2) {
                Text(event.title.isEmpty ? String(localized: "meetings.calendar.untitledEvent") : event.title)
                    .font(.body)
                Text(event.startDate, format: .dateTime.weekday().hour().minute())
                    .font(.caption)
                    .foregroundStyle(.secondary)
                // [M11] Small calendar-name label so the source is visible like in macOS Calendar.
                calendarLabel(for: event)
            }
            Spacer()
            Button(
                existing == nil
                    ? String(localized: "meetings.calendar.createMeeting")
                    : String(localized: "meetings.calendar.openMeeting")
            ) {
                openEarlierEvent(event)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
    }

    /// [M10] Open (or create then open) the meeting for a past event, focusing it in the main
    /// window (UI Step 2: retargeted from the retired `meetings` window to `AppWindowID.main`; the
    /// focus request is bridged to `.meeting(id)` by `MainWindowView`). `createMeeting(from:)`
    /// returns the existing meeting when one already backs the event, so this never duplicates.
    private func openEarlierEvent(_ event: CalendarEventDTO) {
        let meeting = viewModel.createMeeting(from: event)
        viewModel.requestFocus(on: meeting)
        ManagedAppWindowOpener.shared.open(id: AppWindowID.main)
    }
}
