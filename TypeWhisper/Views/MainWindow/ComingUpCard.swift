import SwiftUI

/// [Sprint 2] The "what's next" block of Home: a hero card for the next upcoming or in-progress
/// calendar event — countdown, participants, brief-readiness with its CTA — followed by the rest of
/// the upcoming schedule as quiet time-gutter rows. Replaces the old boxed "Coming up" card.
/// Calendar states (unauthorized / error / nothing upcoming) render here too, so Home never shows a
/// bare error label or an empty shell.
struct HomeNextSection: View {
    @ObservedObject private var viewModel = MeetingsViewModel.shared
    @ObservedObject private var coordinator = MainWindowCoordinator.shared
    @ObservedObject private var homeViewModel = HomeFeedViewModel.shared

    var body: some View {
        VStack(alignment: .leading, spacing: MeetingTheme.s2) {
            MeetingSectionLabel(String(localized: "home.next.section"))

            if viewModel.calendarAuthorizationStatus != .authorized {
                connectCalendarCard
            } else if let error = viewModel.calendarErrorMessage {
                calendarErrorRow(error)
            } else {
                let items = upcomingItems
                if let hero = items.first {
                    TimelineView(.everyMinute) { context in
                        HomeNextHeroCard(item: hero, now: context.date)
                    }
                    ForEach(items.dropFirst()) { item in
                        scheduleRow(item)
                    }
                } else {
                    nothingUpcomingRow
                }
            }
        }
    }

    /// Events still worth planning around: upcoming, in progress, or running long. Ended events
    /// drop out (their meeting docs live in the feed).
    private var upcomingItems: [ComingUpItem] {
        homeViewModel.comingUp(
            from: viewModel.upcomingEvents,
            existingMeeting: { viewModel.existingMeeting(for: $0) }
        )
        .filter { $0.isRunningLong || $0.timeStatus == .inProgress || $0.timeStatus == .upcoming }
    }

    // MARK: - Schedule rows (after the hero)

    private func scheduleRow(_ item: ComingUpItem) -> some View {
        HomeScheduleRow(item: item) {
            let meeting = viewModel.createMeeting(from: item.event)
            coordinator.openMeeting(id: meeting.id)
        }
    }

    // MARK: - Calendar states

    private var connectCalendarCard: some View {
        MeetingEmptyStateCard(
            icon: "calendar.badge.exclamationmark",
            title: String(localized: "home.empty.calendar.title"),
            message: String(localized: "home.empty.calendar.message")
        ) {
            Button(String(localized: "home.empty.calendar.openSettings")) {
                ManagedAppWindowOpener.shared.open(id: AppWindowID.settings)
            }
            .buttonStyle(.bordered)
        }
    }

    private func calendarErrorRow(_ error: String) -> some View {
        Label(error, systemImage: "exclamationmark.triangle")
            .font(MeetingTheme.meta)
            .foregroundStyle(.orange)
            .padding(.horizontal, MeetingTheme.s2)
    }

    private var nothingUpcomingRow: some View {
        HStack(spacing: MeetingTheme.s2) {
            Image(systemName: "moon.zzz")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            Text(String(localized: "home.next.none"))
                .font(MeetingTheme.meta)
                .foregroundStyle(.secondary)
            Button(String(localized: "home.next.startAdHoc")) {
                let meeting = viewModel.createAdHocMeeting()
                coordinator.openMeeting(id: meeting.id)
            }
            .buttonStyle(.link)
            .font(MeetingTheme.meta)
        }
        .padding(.horizontal, MeetingTheme.s2)
        .padding(.vertical, MeetingTheme.s2)
    }
}

/// The hero card for the next meeting: status/countdown line, serif title, participant byline, and
/// the readiness row (brief ready → Review brief; otherwise Generate brief). In-progress and
/// running-long events swap the countdown for a stateful line and offer a prominent open action.
private struct HomeNextHeroCard: View {
    let item: ComingUpItem
    let now: Date

    @ObservedObject private var viewModel = MeetingsViewModel.shared
    @ObservedObject private var coordinator = MainWindowCoordinator.shared

    private var existingMeeting: Meeting? {
        viewModel.existingMeeting(for: item.event)
    }

    private var hasBrief: Bool {
        guard let meeting = existingMeeting else { return false }
        return viewModel.latestOutput(ofKind: .brief, for: meeting) != nil
    }

    private var isNow: Bool {
        item.isRunningLong || item.timeStatus == .inProgress
    }

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: MeetingTheme.s2) {
                statusLine
                Text(title)
                    .font(MeetingTheme.liveTitle)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                byline
                readinessRow
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(MeetingTheme.s5)
            .background(MeetingTheme.cardFill, in: RoundedRectangle(cornerRadius: MeetingTheme.cardRadius))
            .overlay(
                RoundedRectangle(cornerRadius: MeetingTheme.cardRadius)
                    .strokeBorder(MeetingTheme.cardStroke, lineWidth: 0.5)
            )
            .overlay(alignment: .leading) {
                // Slim calendar-color bar — color is an accent, never a background (D6).
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(item.color.swiftUIColor)
                    .frame(width: 3)
                    .padding(.vertical, MeetingTheme.s3)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var title: String {
        item.event.title.isEmpty
            ? String(localized: "meetings.calendar.untitledEvent")
            : item.event.title
    }

    private func open() {
        let meeting = viewModel.createMeeting(from: item.event)
        coordinator.openMeeting(id: meeting.id)
    }

    // MARK: - Status line

    private var statusLine: some View {
        HStack(spacing: MeetingTheme.s2) {
            if item.isRunningLong {
                statusText(
                    String(format: String(localized: "home.next.runningLongSince"), startTimeText),
                    color: .orange, dot: true
                )
            } else if item.timeStatus == .inProgress {
                statusText(
                    String(format: String(localized: "home.next.nowSince"), startTimeText),
                    color: .accentColor, dot: true
                )
            } else {
                Text("\(countdownText) · \(timeRangeText)")
                    .font(MeetingTheme.meta)
                    .foregroundStyle(.secondary)
            }
            if let name = item.event.calendarTitle, !name.isEmpty {
                HStack(spacing: 4) {
                    Circle()
                        .fill(item.color.swiftUIColor)
                        .frame(width: 6, height: 6)
                    Text(name)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func statusText(_ text: String, color: Color, dot: Bool) -> some View {
        HStack(spacing: 5) {
            if dot {
                Circle().fill(color).frame(width: 7, height: 7)
            }
            Text(text)
                .font(MeetingTheme.meta.weight(.medium))
                .foregroundStyle(color)
        }
    }

    private var startTimeText: String {
        item.event.startDate.formatted(.dateTime.hour().minute())
    }

    private var timeRangeText: String {
        "\(item.event.startDate.formatted(.dateTime.hour().minute()))–\(item.event.endDate.formatted(.dateTime.hour().minute()))"
    }

    private var countdownText: String {
        let interval = item.event.startDate.timeIntervalSince(now)
        guard interval > 0 else { return startTimeText }
        if interval > 8 * 3600 {
            // Far-off meetings state their day instead of shouting a countdown.
            return item.event.startDate.formatted(.dateTime.weekday(.wide))
        }
        let duration = Duration.seconds(interval)
            .formatted(.units(allowed: [.hours, .minutes], width: .narrow))
        return String(format: String(localized: "home.next.in"), duration)
    }

    // MARK: - Byline

    @ViewBuilder
    private var byline: some View {
        let others = item.event.attendees.filter { $0.isSelf != true }
        if !others.isEmpty {
            HStack(spacing: MeetingTheme.s2) {
                MeetingAvatarStack(names: others.map(\.displayName))
                Text(bylineText(others))
                    .font(MeetingTheme.meta)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private func bylineText(_ others: [Attendee]) -> String {
        var list = others.prefix(3).map(\.shortDisplayName).formatted(.list(type: .and, width: .short))
        if others.count > 3 {
            list += " +\(others.count - 3)"
        }
        return String(format: String(localized: "meetingdoc.byline.with"), list)
    }

    // MARK: - Readiness

    private var readinessRow: some View {
        HStack(spacing: MeetingTheme.s3) {
            if hasBrief {
                Label(String(localized: "home.badge.briefReady"), systemImage: "checkmark.circle.fill")
                    .font(MeetingTheme.meta)
                    .foregroundStyle(.green)
                Button(String(localized: "home.next.reviewBrief"), action: open)
                    .buttonStyle(.bordered)
            } else if isNow {
                Button {
                    open()
                } label: {
                    Label(String(localized: "home.next.open"), systemImage: "record.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
            } else {
                Text(String(localized: "home.next.noBrief"))
                    .font(MeetingTheme.meta)
                    .foregroundStyle(.secondary)
                Button(String(localized: "meetings.brief.generate")) {
                    let meeting = viewModel.createMeeting(from: item.event)
                    viewModel.generateBrief(for: meeting)
                    coordinator.openMeeting(id: meeting.id)
                }
                .buttonStyle(.bordered)
            }
            Spacer(minLength: 0)
        }
        .padding(.top, MeetingTheme.s1)
    }
}

/// One quiet schedule row after the hero: mono start-time gutter, calendar color bar, title, and a
/// green brief-ready glyph when that event's meeting already carries a brief.
private struct HomeScheduleRow: View {
    let item: ComingUpItem
    let action: () -> Void

    @ObservedObject private var viewModel = MeetingsViewModel.shared
    @State private var isHovering = false

    private var hasBrief: Bool {
        guard let meeting = viewModel.existingMeeting(for: item.event) else { return false }
        return viewModel.latestOutput(ofKind: .brief, for: meeting) != nil
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: MeetingTheme.s3) {
                Text(gutterText)
                    .font(MeetingTheme.mono)
                    .foregroundStyle(.secondary)
                    .frame(width: 56, alignment: .leading)
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(item.color.swiftUIColor)
                    .frame(width: 3, height: 18)
                Text(item.event.title.isEmpty
                    ? String(localized: "meetings.calendar.untitledEvent")
                    : item.event.title)
                    .font(MeetingTheme.meta)
                    .lineLimit(1)
                if item.event.attendees.count > 1 {
                    Label("\(item.event.attendees.count)", systemImage: "person.2")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if hasBrief {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.green)
                        .help(String(localized: "home.badge.briefReady"))
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .opacity(isHovering ? 1 : 0)
            }
            .padding(.vertical, MeetingTheme.s2)
            .padding(.horizontal, MeetingTheme.s2)
            .contentShape(Rectangle())
            .background(
                isHovering ? MeetingTheme.rowHoverFill : .clear,
                in: RoundedRectangle(cornerRadius: MeetingTheme.rowRadius)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }

    private var gutterText: String {
        let isToday = Calendar.current.isDateInToday(item.event.startDate)
        if isToday {
            return item.event.startDate.formatted(.dateTime.hour().minute())
        }
        return item.event.startDate.formatted(.dateTime.weekday(.abbreviated))
    }
}
