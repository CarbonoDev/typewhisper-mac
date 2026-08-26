import SwiftUI

// [Sprint 1] Shared building blocks of the redesigned meeting document. Each component encodes one
// blessed recipe from `MeetingTheme` so the document surfaces stop re-deriving their own styling.

/// Uppercase section label (`ACTION ITEMS`, `APPENDIX`) with an optional trailing accessory.
struct MeetingSectionLabel<Trailing: View>: View {
    let text: String
    @ViewBuilder var trailing: Trailing

    init(_ text: String, @ViewBuilder trailing: () -> Trailing = { EmptyView() }) {
        self.text = text
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: MeetingTheme.s2) {
            Text(text)
                .font(MeetingTheme.sectionLabel)
                .tracking(MeetingTheme.sectionLabelTracking)
                .textCase(.uppercase)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            trailing
        }
    }
}

/// The dot-joined uppercase kicker line above the document title.
struct MeetingKicker: View {
    let parts: [String]

    var body: some View {
        Text(parts.filter { !$0.isEmpty }.joined(separator: " · "))
            .font(MeetingTheme.kicker)
            .tracking(MeetingTheme.kickerTracking)
            .textCase(.uppercase)
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }
}

/// Overlapping initials circles for the byline; deterministic hue per attendee name.
struct MeetingAvatarStack: View {
    let names: [String]
    var maxShown: Int = 4
    var diameter: CGFloat = 24

    var body: some View {
        HStack(spacing: -diameter * 0.25) {
            ForEach(Array(names.prefix(maxShown).enumerated()), id: \.offset) { _, name in
                avatar(for: name)
            }
            if names.count > maxShown {
                Text("+\(names.count - maxShown)")
                    .font(.system(size: diameter * 0.38, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: diameter, height: diameter)
                    .background(MeetingTheme.chipFill, in: Circle())
                    .overlay(Circle().strokeBorder(Color(nsColor: .windowBackgroundColor), lineWidth: 1.5))
            }
        }
    }

    private func avatar(for name: String) -> some View {
        Text(Self.initials(for: name))
            .font(.system(size: diameter * 0.38, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: diameter, height: diameter)
            .background(MeetingTheme.avatarColor(for: name), in: Circle())
            .overlay(Circle().strokeBorder(Color(nsColor: .windowBackgroundColor), lineWidth: 1.5))
    }

    static func initials(for name: String) -> String {
        let words = name.split(separator: " ").prefix(2)
        let letters = words.compactMap { $0.first.map(String.init) }
        return letters.isEmpty ? "?" : letters.joined().uppercased()
    }
}

/// A quiet inline metadata trigger for the byline (`Binnacle · #ti · Spanish`): plain secondary
/// text, underline on hover — an editable value that doesn't dress up as a control.
struct MeetingMetaLink: View {
    let text: String
    var systemImage: String?
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 10))
                }
                Text(text)
                    .underline(isHovering)
            }
            .font(MeetingTheme.meta)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

/// Generated prose (brief / summary) rendered as an article: a thin accent rule in the left margin
/// marks it as model-written, and the provenance sits under the last paragraph as a footnote.
struct MeetingProse<Footer: View>: View {
    let markdown: String
    @ViewBuilder var footer: Footer

    init(markdown: String, @ViewBuilder footer: () -> Footer = { EmptyView() }) {
        self.markdown = markdown
        self.footer = footer()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: MeetingTheme.s3) {
            MarkdownDocumentView(markdown: markdown, style: .article)
            HStack {
                Spacer()
                footer
            }
        }
        .padding(.leading, MeetingTheme.s4)
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: MeetingTheme.proseRuleWidth / 2)
                .fill(MeetingTheme.proseRule)
                .frame(width: MeetingTheme.proseRuleWidth)
        }
    }
}

/// Text tabs for the rendered output (`Summary · Extended · Brief`): sans 13, selected = primary
/// with a 2pt underline, others secondary. Replaces the header's output-selector chip menu.
struct MeetingOutputTabs: View {
    struct Tab: Identifiable, Equatable {
        var id: String
        var label: String
        var kind: MeetingOutputKind
    }

    let tabs: [Tab]
    @Binding var selection: MeetingOutputKind

    var body: some View {
        HStack(spacing: MeetingTheme.s4) {
            ForEach(tabs) { tab in
                Button {
                    selection = tab.kind
                } label: {
                    Text(tab.label)
                        .font(.system(size: 13, weight: tab.kind == selection ? .semibold : .regular))
                        .foregroundStyle(tab.kind == selection ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                        .padding(.bottom, 6)
                        .overlay(alignment: .bottom) {
                            if tab.kind == selection {
                                Rectangle()
                                    .fill(Color.accentColor)
                                    .frame(height: 2)
                            }
                        }
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
    }
}

/// One appendix row: a disclosure whose *closed* state carries a one-line summary so collapsed
/// content never feels hidden. All appendix rows start closed.
struct MeetingAppendixRow<Content: View>: View {
    let title: String
    var summary: String?
    @ViewBuilder var content: Content

    @State private var isExpanded = false
    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: MeetingTheme.s2) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    Text(title)
                        .font(MeetingTheme.meta.weight(.medium))
                    if let summary, !summary.isEmpty, !isExpanded {
                        Text(summary)
                            .font(MeetingTheme.meta)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
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

            if isExpanded {
                content
                    .padding(.leading, MeetingTheme.s5)
                    .padding(.top, MeetingTheme.s2)
                    .padding(.bottom, MeetingTheme.s3)
            }
        }
    }
}

/// A quiet one-line action row (`Transcript · 42 min · 7 speakers`) — plain until hover.
struct MeetingQuietRow: View {
    let icon: String
    let title: String
    var detail: String?
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: MeetingTheme.s2) {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                Text(title)
                    .font(MeetingTheme.meta.weight(.medium))
                if let detail, !detail.isEmpty {
                    Text(detail)
                        .font(MeetingTheme.meta)
                        .foregroundStyle(.secondary)
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
}

/// The brief's talking points as a checkable agenda (follow-up feature): rendered on the briefing
/// page and carried into the live view so points can be ticked off as they're covered. Done-state
/// persists per meeting via `MeetingChecklistStore` (same store as action items), so checks made
/// while preparing survive into the meeting.
struct MeetingAgendaSection: View {
    let meetingID: UUID
    let items: [MeetingOutputParser.ActionItem]

    @ObservedObject private var store = MeetingChecklistStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: MeetingTheme.s2) {
            MeetingSectionLabel(String(localized: "meetingdoc.agenda.title")) {
                let done = store.doneCount(meetingID: meetingID, itemIDs: items.map(\.stableID))
                if done > 0 {
                    Text("\(done)/\(items.count)")
                        .font(MeetingTheme.mono)
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 0) {
                ForEach(items, id: \.stableID) { item in
                    row(for: item)
                }
            }
            .padding(MeetingTheme.s3)
            .background(MeetingTheme.cardFill, in: RoundedRectangle(cornerRadius: MeetingTheme.cardRadius))
            .overlay(
                RoundedRectangle(cornerRadius: MeetingTheme.cardRadius)
                    .strokeBorder(MeetingTheme.cardStroke, lineWidth: 0.5)
            )
        }
    }

    private func row(for item: MeetingOutputParser.ActionItem) -> some View {
        let isDone = store.isDone(meetingID: meetingID, itemID: item.stableID)
        return Button {
            store.setDone(!isDone, meetingID: meetingID, itemID: item.stableID)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: MeetingTheme.s2) {
                Image(systemName: isDone ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 13))
                    .foregroundStyle(isDone ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                Text(item.text)
                    .font(MeetingTheme.meta)
                    .strikethrough(isDone)
                    .foregroundStyle(isDone ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .multilineTextAlignment(.leading)
            }
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// The document's empty-state hero card (no brief yet / transcript captured but nothing generated):
/// a glyph, one line of intent, one primary action — never a stack of empty sections.
struct MeetingEmptyStateCard<Actions: View>: View {
    let icon: String
    let title: String
    var message: String?
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(spacing: MeetingTheme.s3) {
            Image(systemName: icon)
                .font(.system(size: 24))
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.title3.weight(.semibold))
            if let message {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            actions
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, MeetingTheme.s6)
        .padding(.horizontal, MeetingTheme.s5)
        .background(MeetingTheme.cardFill, in: RoundedRectangle(cornerRadius: MeetingTheme.cardRadius))
        .overlay(
            RoundedRectangle(cornerRadius: MeetingTheme.cardRadius)
                .strokeBorder(MeetingTheme.cardStroke, lineWidth: 0.5)
        )
    }
}
