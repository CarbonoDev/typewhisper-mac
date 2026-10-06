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
            // Lazy (as is the Home feed's outer stack) so only on-screen rows are built and measured.
            LazyVStack(alignment: .leading, spacing: MeetingTheme.s3) {
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
    // Observed at list level (not per row) so checking items off in a document updates the rows'
    // open-action counts live.
    @ObservedObject private var checklistStore = MeetingChecklistStore.shared
    /// The last replace/toggle target — the origin a ⇧-click range extends from.
    @State private var selectionAnchor: UUID?
    /// Whether the list region holds keyboard focus. The ⌘-A key equivalent is installed ONLY while this
    /// is true, so a focused TextField (e.g. the folder-detail description field) keeps native ⌘-A for
    /// text editing instead of selecting every row (LX-1 finding #2).
    @FocusState private var isListFocused: Bool

    var body: some View {
        let groups = homeViewModel.timelineGroups(from: meetings)
        let orderedIDs = groups.flatMap { $0.meetings.map(\.id) }
        let rowContext = MeetingRowModelStore.Context(
            actionFacts: homeViewModel.actionFacts(for:),
            runningJobKinds: { [jobQueue] id in
                jobQueue.jobs(for: id).filter { $0.state == .running }.map(\.kind)
            }
        )
        // Lazy at both levels (day groups and rows within a day): with hundreds of meetings a plain
        // VStack built and measured every row on each invalidation. Headers are not pinned.
        LazyVStack(alignment: .leading, spacing: 20) {
            ForEach(groups) { group in
                VStack(alignment: .leading, spacing: 8) {
                    Text(homeViewModel.groupTitle(for: group))
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundStyle(.secondary)

                    LazyVStack(spacing: 6) {
                        ForEach(group.meetings, id: \.id) { meeting in
                            if let model = MeetingRowModelStore.shared.row(for: meeting, context: rowContext) {
                                row(meeting, model: model, orderedIDs: orderedIDs)
                            }
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
    private func row(_ meeting: Meeting, model: MeetingRowModel, orderedIDs: [UUID]) -> some View {
        let isLive = viewModel.isCapturing && viewModel.activeMeeting?.id == meeting.id
        let isSelected = selection?.wrappedValue.contains(meeting.id) ?? false
        let content = MeetingRowView(model: model, style: .timeline, isLive: isLive, isSelected: isSelected)
            .equatable()
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
}
