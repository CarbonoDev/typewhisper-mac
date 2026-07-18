import SwiftUI

/// [Sprint 2] The meetings Home feed as a focus dashboard: a masthead (kicker date + serif
/// "Today"), the live-capture hero while recording, the next-meeting hero + today's remaining
/// schedule, a needs-attention triage section (open action items, missing summaries, interrupted
/// recordings), and the recent day-grouped feed. History and search live in the Meetings list —
/// Home answers "what's next, am I ready, what did I leave unfinished".
struct HomeFeedView: View {
    @ObservedObject private var viewModel = MeetingsViewModel.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: MeetingTheme.sectionGap) {
                masthead
                HomeLiveBanner()
                HomeNextSection()
                HomeAttentionSection()
                MeetingTimeline()
            }
            .frame(maxWidth: MeetingTheme.contentMaxWidth, alignment: .topLeading)
            .padding(MeetingTheme.pagePadding)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .navigationTitle(String(localized: "mainwindow.sidebar.home"))
    }

    private var masthead: some View {
        VStack(alignment: .leading, spacing: MeetingTheme.s2) {
            TimelineView(.everyMinute) { context in
                MeetingKicker(parts: [
                    context.date.formatted(.dateTime.weekday(.wide).day().month(.wide))
                ])
            }
            Text(String(localized: "home.timeline.today"))
                .font(MeetingTheme.pageTitle)
        }
    }
}

/// [Sprint 2] The needs-attention triage section: interrupted recordings, completed meetings whose
/// summaries were never generated, and meetings with open action items — the "act on them" loop.
/// Renders a quiet caught-up row when nothing needs the user; renders nothing for brand-new users
/// (the timeline empty state owns that moment).
struct HomeAttentionSection: View {
    @ObservedObject private var viewModel = MeetingsViewModel.shared
    @ObservedObject private var homeViewModel = HomeFeedViewModel.shared
    @ObservedObject private var coordinator = MainWindowCoordinator.shared
    // Observed so checking items off in a document updates the counts here live.
    @ObservedObject private var checklistStore = MeetingChecklistStore.shared

    @State private var isExpanded = false

    private struct Row: Identifiable {
        var id: String
        var dotColor: Color
        var title: String
        var detail: String
        var meetingID: UUID
    }

    private static let attentionWindow: TimeInterval = 14 * 24 * 3600
    private static let summaryWindow: TimeInterval = 7 * 24 * 3600
    private static let visibleCap = 4

    var body: some View {
        let rows = attentionRows()
        if !viewModel.meetings.isEmpty {
            VStack(alignment: .leading, spacing: MeetingTheme.s2) {
                MeetingSectionLabel(String(localized: "home.attention.section"))

                if rows.isEmpty {
                    caughtUpRow
                } else {
                    let visible = isExpanded ? rows : Array(rows.prefix(Self.visibleCap))
                    ForEach(visible) { row in
                        attentionRow(row)
                    }
                    if rows.count > Self.visibleCap, !isExpanded {
                        Button {
                            withAnimation(.easeInOut(duration: 0.15)) { isExpanded = true }
                        } label: {
                            Text(String(format: String(localized: "home.attention.more"), rows.count - Self.visibleCap))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.leading, MeetingTheme.s4)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var caughtUpRow: some View {
        HStack(spacing: MeetingTheme.s2) {
            Image(systemName: "checkmark.seal")
                .font(.system(size: 13))
                .foregroundStyle(.tint)
            Text(String(localized: "home.attention.caughtUp"))
                .font(MeetingTheme.meta.weight(.medium))
            Text(String(localized: "home.attention.caughtUp.sub"))
                .font(MeetingTheme.meta)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, MeetingTheme.s2)
        .padding(.horizontal, MeetingTheme.s2)
    }

    private func attentionRow(_ row: Row) -> some View {
        AttentionRowView(row: row) {
            coordinator.openMeeting(id: row.meetingID)
        }
    }

    private struct AttentionRowView: View {
        let row: Row
        let action: () -> Void
        @State private var isHovering = false

        var body: some View {
            Button(action: action) {
                HStack(spacing: MeetingTheme.s2) {
                    Circle()
                        .fill(row.dotColor)
                        .frame(width: 6, height: 6)
                        .padding(.horizontal, 5)
                    Text(row.title)
                        .font(MeetingTheme.meta.weight(.medium))
                    Text(row.detail)
                        .font(MeetingTheme.meta)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
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
    }

    private func attentionRows(now: Date = Date()) -> [Row] {
        var interrupted: [Row] = []
        var openActions: [(open: Int, row: Row)] = []
        var noSummary: [Row] = []

        for meeting in viewModel.meetings {
            let reference = meeting.startDate ?? meeting.createdAt
            guard now.timeIntervalSince(reference) < Self.attentionWindow else { continue }

            if meeting.state == .interrupted {
                interrupted.append(Row(
                    id: "interrupted-\(meeting.id)",
                    dotColor: .orange,
                    title: String(localized: "home.attention.interrupted"),
                    detail: meeting.title,
                    meetingID: meeting.id
                ))
                continue
            }
            guard meeting.state == .completed else { continue }

            if let facts = homeViewModel.actionFacts(for: meeting) {
                if facts.openCount > 0 {
                    openActions.append((facts.openCount, Row(
                        id: "actions-\(meeting.id)",
                        dotColor: .accentColor,
                        title: String(format: String(localized: "home.attention.openActions"), facts.openCount),
                        detail: meeting.title,
                        meetingID: meeting.id
                    )))
                }
            } else if !meeting.segments.isEmpty,
                      now.timeIntervalSince(reference) < Self.summaryWindow {
                noSummary.append(Row(
                    id: "nosummary-\(meeting.id)",
                    dotColor: Color.secondary,
                    title: String(localized: "home.attention.noSummary"),
                    detail: meeting.title,
                    meetingID: meeting.id
                ))
            }
        }

        let sortedActions = openActions.sorted { $0.open > $1.open }.map(\.row)
        return interrupted + sortedActions + noSummary
    }
}
