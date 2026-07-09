import SwiftUI

/// The day-grouped meeting timeline on the Home feed (plan Track C / D6). A thin wrapper over the
/// reusable `MeetingTimelineList`: it feeds the full `MeetingsViewModel.meetings` snapshot and owns
/// only the Home-specific empty state. The row treatment (state badges, working badge, attendees,
/// tags) lives in `MeetingTimelineList` so the folder detail page (M12) reuses the identical rows
/// instead of a second lightweight list. Clicking any row routes to that meeting's document via the
/// shared coordinator — the single navigation channel.
struct MeetingTimeline: View {
    @ObservedObject private var viewModel = MeetingsViewModel.shared

    var body: some View {
        if viewModel.meetings.isEmpty {
            emptyState
        } else {
            MeetingTimelineList(meetings: viewModel.meetings)
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label(String(localized: "home.timeline.empty.title"), systemImage: "calendar")
        } description: {
            Text(String(localized: "home.timeline.empty.message"))
        }
    }
}

/// The reusable day-grouped meeting list (M12): meetings are bucketed by day (Today / Yesterday /
/// weekday / date) newest-first, each row carrying its state badges (Running long / Brief ready /
/// Summary / Extended / In vault), a transient working badge, attendee count, and first-party tag
/// capsules. Takes an explicit `meetings` snapshot so both the Home feed and the folder detail page
/// render the same rows over their own (unfiltered / folder+tag-filtered) sets. Renders nothing when
/// empty — the caller owns its empty state. Clicking any row routes to that meeting's document via
/// the shared coordinator.
struct MeetingTimelineList: View {
    let meetings: [Meeting]

    @ObservedObject private var viewModel = MeetingsViewModel.shared
    @ObservedObject private var coordinator = MainWindowCoordinator.shared
    @ObservedObject private var homeViewModel = HomeFeedViewModel.shared
    @ObservedObject private var jobQueue = JobQueueService.shared

    var body: some View {
        let groups = homeViewModel.timelineGroups(from: meetings)
        VStack(alignment: .leading, spacing: 20) {
            ForEach(groups) { group in
                VStack(alignment: .leading, spacing: 8) {
                    Text(homeViewModel.groupTitle(for: group))
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundStyle(.secondary)

                    VStack(spacing: 6) {
                        ForEach(group.meetings, id: \.id) { meeting in
                            row(meeting)
                        }
                    }
                }
            }
        }
    }

    private func row(_ meeting: Meeting) -> some View {
        let isLive = viewModel.isCapturing && viewModel.activeMeeting?.id == meeting.id
        return Button {
            coordinator.openMeeting(id: meeting.id)
        } label: {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        if isLive {
                            Image(systemName: "record.circle.fill")
                                .foregroundStyle(.red)
                        }
                        Text(meeting.title)
                            .font(.body)
                            .lineLimit(1)
                    }
                    HStack(spacing: 8) {
                        if let start = meeting.startDate {
                            Text(start, format: .dateTime.hour().minute())
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        attendeeCount(for: meeting)
                        badges(for: meeting, isLive: isLive)
                    }
                    tagCapsules(for: meeting)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 10))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// A compact attendee count (people icon + number), shown only when the meeting has attendees, so
    /// ad-hoc/attendee-less meetings stay clean. Placed with the time in the metadata line.
    @ViewBuilder
    private func attendeeCount(for meeting: Meeting) -> some View {
        let count = meeting.attendees.count
        if count > 0 {
            Label("\(count)", systemImage: "person.2")
                .labelStyle(.titleAndIcon)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func badges(for meeting: Meeting, isLive: Bool) -> some View {
        HStack(spacing: 6) {
            if isLive {
                badgeCapsule(
                    text: String(localized: "meetings.state.live"),
                    systemImage: "waveform",
                    tint: .red
                )
            }
            // Transient "working" badge derived from the queue's *running* jobs for this meeting (plan
            // J3). Leading (before the persisted-fact badges) and reflecting the correct meeting no
            // matter which document is open, since it is sourced from `jobs(for:)`.
            if let badge = workingBadge(for: meeting) {
                workingBadgeCapsule(text: badge.text)
            }
            ForEach(homeViewModel.badges(for: meeting), id: \.self) { badge in
                badgeCapsule(text: badge.displayName, systemImage: badge.systemImage, tint: badge.tint)
            }
        }
    }

    /// First-party tag capsules on a timeline row (plan D9/M3), capped so a heavily-tagged meeting
    /// can't blow out the row; the remainder collapses into a "+N" capsule. Display-only — the whole
    /// row is already a navigation Button (filtering lives on the sidebar TAGS section), so nested
    /// interactive capsules are deliberately avoided.
    @ViewBuilder
    private func tagCapsules(for meeting: Meeting) -> some View {
        let tags = meeting.tags
        if !tags.isEmpty {
            let maxVisible = 4
            let visible = tags.prefix(maxVisible)
            HStack(spacing: 6) {
                ForEach(Array(visible), id: \.self) { tag in
                    tagCapsule("#\(tag)")
                }
                if tags.count > maxVisible {
                    tagCapsule("+\(tags.count - maxVisible)")
                }
            }
        }
    }

    private func tagCapsule(_ text: String) -> some View {
        Text(text)
            .font(.caption2)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.secondary.opacity(0.15), in: Capsule())
            .foregroundStyle(.secondary)
    }

    private func workingBadge(for meeting: Meeting) -> MeetingActivityBadge? {
        let runningKinds = jobQueue.jobs(for: meeting.id)
            .filter { $0.state == .running }
            .map(\.kind)
        return MeetingsViewModel.homeActivityBadge(runningKinds: runningKinds)
    }

    private func workingBadgeCapsule(text: String) -> some View {
        HStack(spacing: 4) {
            ProgressView()
                .controlSize(.mini)
            Text(text)
        }
        .font(.caption2)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Color.accentColor.opacity(0.15), in: Capsule())
        .foregroundStyle(Color.accentColor)
        .accessibilityLabel(Text(String(localized: "meetings.jobs.badge.working")))
    }

    private func badgeCapsule(text: String, systemImage: String, tint: Color) -> some View {
        Label(text, systemImage: systemImage)
            .labelStyle(.titleAndIcon)
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(tint.opacity(0.15), in: Capsule())
            .foregroundStyle(tint)
    }
}
