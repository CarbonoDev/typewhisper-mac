import SwiftUI

/// [Perf Phase 2] The one meeting row, drawn entirely from a `MeetingRowModel` value. Replaces the
/// former `MeetingsListView.ArchiveRow` and `MeetingTimelineList.TimelineRowContent`, which drew the
/// same row twice over a live `Meeting` and observed shared view models. It observes nothing: the
/// owning list builds the model, and SwiftUI skips the body while model + flags are unchanged
/// (`Equatable`). The two layouts are kept pixel-identical to the rows they replace.
struct MeetingRowView: View, Equatable {
    enum Style: Equatable {
        /// [Sprint 5] The archive list row: date gutter, title line with markers, organization line.
        case archive
        /// [Sprint 2] The Home / folder-detail timeline row: time gutter, badges, tag line.
        case timeline
    }

    let model: MeetingRowModel
    let style: Style
    let isLive: Bool
    let isSelected: Bool

    @State private var isHovering = false

    nonisolated static func == (lhs: MeetingRowView, rhs: MeetingRowView) -> Bool {
        lhs.model == rhs.model && lhs.style == rhs.style
            && lhs.isLive == rhs.isLive && lhs.isSelected == rhs.isSelected
    }

    var body: some View {
        switch style {
        case .archive: archiveBody
        case .timeline: timelineBody
        }
    }

    private var rowFill: Color {
        isSelected
            ? Color.accentColor.opacity(0.16)
            : (isHovering ? Color.primary.opacity(0.06) : Color.primary.opacity(0.035))
    }

    private var chevron: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.tertiary)
            .opacity(isHovering || isSelected ? 1 : 0)
    }

    // MARK: - Archive layout

    private var archiveBody: some View {
        HStack(alignment: .top, spacing: MeetingTheme.s3) {
            Text(archiveGutterText)
                .font(MeetingTheme.mono)
                .foregroundStyle(.secondary)
                .frame(width: 60, alignment: .leading)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: MeetingTheme.s2) {
                    if isLive {
                        Image(systemName: "record.circle.fill")
                            .foregroundStyle(.red)
                    }
                    Text(model.title)
                        .font(.system(size: 14, weight: .medium))
                        .lineLimit(1)
                    if model.isImported {
                        Image(systemName: "square.and.arrow.down")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                            .help(String(localized: "meetings.row.imported"))
                    }
                    if model.isDuplicate {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                            .help(String(localized: "meetings.row.duplicate"))
                    }
                    stateWord
                    Spacer(minLength: 8)
                    archiveTrailingFacts
                    chevron
                }
                organizationLine
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, MeetingTheme.s3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(rowFill, in: RoundedRectangle(cornerRadius: MeetingTheme.rowRadius))
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
    }

    private var archiveGutterText: String {
        let date = model.effectiveDate
        let sameYear = Calendar.current.isDate(date, equalTo: Date(), toGranularity: .year)
        return date.formatted(
            sameYear
                ? .dateTime.day(.twoDigits).month(.abbreviated)
                : .dateTime.day(.twoDigits).month(.abbreviated).year(.twoDigits)
        )
    }

    /// Line 2: where the meeting lives (folder) and how it's labeled (tags) — plus attendees.
    private var organizationLine: some View {
        HStack(spacing: MeetingTheme.s2) {
            if let folder = model.folder {
                Label(folder, systemImage: "folder")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                Label(String(localized: "mainwindow.folders.unfiled"), systemImage: "tray")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            if model.attendeeCount > 1 {
                Label("\(model.attendeeCount)", systemImage: "person.2")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(Array(model.tags.prefix(3)), id: \.self) { tag in
                Text("#\(tag)")
                    .font(.caption)
                    .lineLimit(1)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(MeetingTheme.chipFill, in: Capsule())
                    .foregroundStyle(.secondary)
            }
            if model.tags.count > 3 {
                Text("+\(model.tags.count - 3)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    /// The state renders only when it needs saying: completed is the normal resting state.
    @ViewBuilder
    private var stateWord: some View {
        switch model.state {
        case .scheduled:
            Text(model.state.displayName)
                .font(.caption)
                .foregroundStyle(.secondary)
        case .interrupted, .processing:
            Text(model.state.displayName)
                .font(.caption)
                .foregroundStyle(.orange)
        case .failed:
            Text(model.state.displayName)
                .font(.caption)
                .foregroundStyle(.red)
        case .completed, .live:
            EmptyView()
        }
    }

    @ViewBuilder
    private var archiveTrailingFacts: some View {
        if model.state == .scheduled, model.hasBrief {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 11))
                .foregroundStyle(.green)
                .help(String(localized: "home.badge.briefReady"))
        }
        transcriptMarker
        actionFactsMarker
    }

    // MARK: - Timeline layout

    private var timelineBody: some View {
        HStack(alignment: .firstTextBaseline, spacing: MeetingTheme.s3) {
            Text(timelineGutterText)
                .font(MeetingTheme.mono)
                .foregroundStyle(.secondary)
                .frame(width: 56, alignment: .leading)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    if isLive {
                        Image(systemName: "record.circle.fill")
                            .foregroundStyle(.red)
                    }
                    Text(model.title)
                        .font(MeetingTheme.meta)
                        .lineLimit(1)
                    HStack(spacing: 8) {
                        timelineAttendeeCount
                        timelineBadges
                    }
                }
                tagRow
            }
            Spacer(minLength: 8)
            transcriptMarker
            actionFactsMarker
            chevron
        }
        .padding(.vertical, MeetingTheme.s2)
        .padding(.horizontal, MeetingTheme.s3)
        .frame(maxWidth: .infinity, alignment: .leading)
        // [Sprint 5] A quiet card fill separates rows from the page ground.
        .background(rowFill, in: RoundedRectangle(cornerRadius: MeetingTheme.rowRadius))
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
    }

    private var timelineGutterText: String {
        model.startDate?.formatted(.dateTime.hour().minute()) ?? ""
    }

    @ViewBuilder
    private var tagRow: some View {
        let tags = model.tags
        if model.folder != nil || !tags.isEmpty {
            let maxVisible = 3
            HStack(spacing: 6) {
                // [Sprint 5] Name the folder on the row (owner feedback) — quiet, before tags.
                if let folder = model.folder {
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

    /// A compact attendee count, shown only when the meeting has attendees.
    @ViewBuilder
    private var timelineAttendeeCount: some View {
        if model.attendeeCount > 0 {
            Label("\(model.attendeeCount)", systemImage: "person.2")
                .labelStyle(.titleAndIcon)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var timelineBadges: some View {
        HStack(spacing: 6) {
            if isLive {
                badgeCapsule(
                    text: String(localized: "meetings.state.live"),
                    systemImage: "waveform",
                    tint: .red
                )
            }
            // Transient "working" badge from the queue's running jobs for this meeting (plan J3).
            if let badge = model.workingBadge {
                workingBadgeCapsule(text: badge.text)
            }
            ForEach(model.timelineBadges, id: \.self) { badge in
                badgeCapsule(text: badge.displayName, systemImage: badge.systemImage, tint: badge.tint)
            }
        }
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

    // MARK: - Shared trailing facts

    /// A quiet "there's a transcript here" marker.
    @ViewBuilder
    private var transcriptMarker: some View {
        if model.hasTranscript {
            Image(systemName: "text.quote")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .help(String(localized: "meetings.row.hasTranscript"))
        }
    }

    /// `N open` while action items remain; a quiet check when they're all done.
    @ViewBuilder
    private var actionFactsMarker: some View {
        if let facts = model.actionFacts, facts.totalCount > 0 {
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
