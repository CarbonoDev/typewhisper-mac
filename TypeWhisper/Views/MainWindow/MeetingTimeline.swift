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
            VStack(alignment: .leading, spacing: MeetingTheme.s3) {
                MeetingSectionLabel(String(localized: "home.recent.section"))
                MeetingTimelineList(meetings: viewModel.meetings)
            }
        }
    }

    private var emptyState: some View {
        MeetingEmptyStateCard(
            icon: "waveform",
            title: String(localized: "home.timeline.empty.title"),
            message: String(localized: "home.timeline.empty.message")
        ) {
            EmptyView()
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
    /// Optional multi-select binding (plan LX-1, D3). `nil` (Home) → plain nav rows, no selection
    /// affordance. Non-nil (Meetings-list folder detail) → selectable rows driven by the pure
    /// `MeetingsViewModel.SelectionGesture` (⌘-toggle / ⇧-range) plus ⌘-A, with a subtle highlight.
    var selection: Binding<Set<UUID>>? = nil

    @ObservedObject private var viewModel = MeetingsViewModel.shared
    @ObservedObject private var coordinator = MainWindowCoordinator.shared
    @ObservedObject private var homeViewModel = HomeFeedViewModel.shared
    @ObservedObject private var jobQueue = JobQueueService.shared
    /// The last replace/toggle target — the origin a ⇧-click range extends from.
    @State private var selectionAnchor: UUID?
    /// Whether the list region holds keyboard focus. The ⌘-A key equivalent is installed ONLY while this
    /// is true, so a focused TextField (e.g. the folder-detail description field) keeps native ⌘-A for
    /// text editing instead of selecting every row (LX-1 finding #2).
    @FocusState private var isListFocused: Bool

    var body: some View {
        let groups = homeViewModel.timelineGroups(from: meetings)
        let orderedIDs = groups.flatMap { $0.meetings.map(\.id) }
        VStack(alignment: .leading, spacing: 20) {
            ForEach(groups) { group in
                VStack(alignment: .leading, spacing: 8) {
                    Text(homeViewModel.groupTitle(for: group))
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundStyle(.secondary)

                    VStack(spacing: 6) {
                        ForEach(group.meetings, id: \.id) { meeting in
                            row(meeting, orderedIDs: orderedIDs)
                        }
                    }
                }
            }
        }
        // Make the selectable list a focus target so ⌘-A can be scoped to it (Home passes nil → not
        // focusable, no selection, no ⌘-A). `focusEffectDisabled` keeps the container from drawing a
        // focus ring around the whole list.
        .focusable(selection != nil)
        .focusEffectDisabled()
        .focused($isListFocused)
        // ⌘-A selects every visible row (plan LX-1 D3), but ONLY while the list holds focus — so a
        // focused TextField keeps native ⌘-A for text (LX-1 finding #2).
        .background {
            if let selection, isListFocused {
                Button("") { selection.wrappedValue = MeetingsViewModel.SelectionGesture.selectAll(orderedIDs) }
                    .keyboardShortcut("a", modifiers: .command)
                    .opacity(0)
            }
        }
    }

    @ViewBuilder
    private func row(_ meeting: Meeting, orderedIDs: [UUID]) -> some View {
        let isLive = viewModel.isCapturing && viewModel.activeMeeting?.id == meeting.id
        let isSelected = selection?.wrappedValue.contains(meeting.id) ?? false
        let content = rowContent(meeting, isLive: isLive, isSelected: isSelected)
        if let selection {
            content
                .contentShape(Rectangle())
                // Plain click opens; ⌘/⇧-click drive selection through the pure helper and win via
                // high priority. Home (nil binding) keeps the plain nav Button below.
                .onTapGesture { coordinator.openMeeting(id: meeting.id) }
                .highPriorityGesture(
                    TapGesture().modifiers(.command).onEnded {
                        applyClick(.toggle, meeting.id, orderedIDs, selection)
                    }
                )
                .highPriorityGesture(
                    TapGesture().modifiers(.shift).onEnded {
                        applyClick(.range, meeting.id, orderedIDs, selection)
                    }
                )
                // Shared row right-click menu (plan LX-2, D4) — selectable surfaces only (folder
                // detail). Home (nil binding) stays a pure nav row with no context menu.
                .meetingRowContextMenu(for: meeting)
        } else {
            Button {
                coordinator.openMeeting(id: meeting.id)
            } label: {
                content
            }
            .buttonStyle(.plain)
        }
    }

    private func applyClick(
        _ click: MeetingsViewModel.SelectionGesture.Click,
        _ id: UUID,
        _ orderedIDs: [UUID],
        _ binding: Binding<Set<UUID>>
    ) {
        let result = MeetingsViewModel.SelectionGesture.apply(
            click: click,
            on: id,
            selection: binding.wrappedValue,
            anchor: selectionAnchor,
            orderedIDs: orderedIDs
        )
        binding.wrappedValue = result.selection
        selectionAnchor = result.anchor
        // A ⌘/⇧-click is an explicit "I'm working in this list" signal — take focus so ⌘-A applies here.
        isListFocused = true
    }

    private func rowContent(_ meeting: Meeting, isLive: Bool, isSelected: Bool) -> some View {
        TimelineRowContent(meeting: meeting, isLive: isLive, isSelected: isSelected) {
            HStack(spacing: 8) {
                attendeeCount(for: meeting)
                badges(for: meeting, isLive: isLive)
            }
        }
    }

    /// [Sprint 2] The quiet row treatment: transparent until hover, selection keeps its accent
    /// highlight (folder detail), metadata in a mono time gutter, and an honest open-action count
    /// instead of artifact badges.
    private struct TimelineRowContent<Accessory: View>: View {
        let meeting: Meeting
        let isLive: Bool
        let isSelected: Bool
        @ViewBuilder var accessory: Accessory

        @ObservedObject private var homeViewModel = HomeFeedViewModel.shared
        // Observed so checking items off in a document updates the trailing count live.
        @ObservedObject private var checklistStore = MeetingChecklistStore.shared
        @State private var isHovering = false

        var body: some View {
            HStack(alignment: .firstTextBaseline, spacing: MeetingTheme.s3) {
                Text(gutterText)
                    .font(MeetingTheme.mono)
                    .foregroundStyle(.secondary)
                    .frame(width: 56, alignment: .leading)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        if isLive {
                            Image(systemName: "record.circle.fill")
                                .foregroundStyle(.red)
                        }
                        // [Sprint 3] Imported export filenames display as the meetings they are.
                        Text(ImportedMeetingTitle.displayTitle(for: meeting.title))
                            .font(MeetingTheme.meta)
                            .lineLimit(1)
                        accessory
                    }
                    tagRow
                }
                Spacer(minLength: 8)
                trailingFacts
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .opacity(isHovering || isSelected ? 1 : 0)
            }
            .padding(.vertical, MeetingTheme.s2)
            .padding(.horizontal, MeetingTheme.s3)
            .frame(maxWidth: .infinity, alignment: .leading)
            // [Sprint 5] A quiet card fill separates rows from the page ground — fully transparent
            // rows read flat (owner feedback).
            .background(
                isSelected
                    ? Color.accentColor.opacity(0.16)
                    : (isHovering ? Color.primary.opacity(0.06) : Color.primary.opacity(0.035)),
                in: RoundedRectangle(cornerRadius: MeetingTheme.rowRadius)
            )
            .contentShape(Rectangle())
            .onHover { isHovering = $0 }
        }

        private var gutterText: String {
            // Imported meetings without a stored date still carry one in their export filename.
            guard let start = meeting.startDate ?? ImportedMeetingTitle.parse(meeting.title).date else {
                return ""
            }
            return start.formatted(.dateTime.hour().minute())
        }

        @ViewBuilder
        private var tagRow: some View {
            let tags = meeting.tags
            let folder = meeting.folderPath?.trimmingCharacters(in: .whitespaces)
            if folder?.isEmpty == false || !tags.isEmpty {
                let maxVisible = 3
                HStack(spacing: 6) {
                    // [Sprint 5] Name the folder on the row (owner feedback) — quiet, before tags.
                    if let folder, !folder.isEmpty {
                        Label(folder, systemImage: "folder")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    ForEach(Array(tags.prefix(maxVisible)), id: \.self) { tag in
                        chip("#\(tag)")
                    }
                    if tags.count > maxVisible {
                        chip("+\(tags.count - maxVisible)")
                    }
                }
            }
        }

        private func chip(_ text: String) -> some View {
            Text(text)
                .font(.caption)
                .lineLimit(1)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(MeetingTheme.chipFill, in: Capsule())
                .foregroundStyle(.secondary)
        }

        /// `N open` while action items remain; a quiet check when they're all done.
        @ViewBuilder
        private var trailingFacts: some View {
            if meeting.state == .completed,
               let facts = homeViewModel.actionFacts(for: meeting),
               facts.totalCount > 0 {
                if facts.openCount > 0 {
                    Text(String(format: String(localized: "home.recent.open"), facts.openCount))
                        .font(.caption)
                        .foregroundStyle(.tint)
                } else {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 11))
                        .foregroundStyle(.green)
                        .help(String(localized: "home.recent.allDone"))
                }
            }
        }
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
            // [Sprint 2] Badge diet: only state that needs the user survives. Summary/Extended/In
            // vault described artifacts (the normal resting state) and are gone — the trailing
            // open-action count and the needs-attention section carry that load. Brief-ready only
            // matters before the meeting happens.
            ForEach(dietBadges(for: meeting), id: \.self) { badge in
                badgeCapsule(text: badge.displayName, systemImage: badge.systemImage, tint: badge.tint)
            }
        }
    }

    private func dietBadges(for meeting: Meeting) -> [MeetingBadge] {
        homeViewModel.badges(for: meeting).filter { badge in
            switch badge {
            case .runningLong: return true
            case .briefReady: return meeting.state == .scheduled
            case .summary, .extended, .inVault: return false
            }
        }
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
