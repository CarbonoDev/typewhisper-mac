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
        .background(
            (isSelected ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.03)),
            in: RoundedRectangle(cornerRadius: 10)
        )
        .contentShape(Rectangle())
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
