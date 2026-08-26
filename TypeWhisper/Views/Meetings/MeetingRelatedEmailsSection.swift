import SwiftUI

/// The per-meeting "Related emails" section ([Google Phase 3 · M5], D-M6), modeled on
/// `MeetingRelatedDocsSection`: header + refresh affordance, metadata-only rows (no body fetch),
/// and an account-correct "Open in Gmail" click-through via `GmailWebURL` + the join launcher.
/// Two styles: `.standard` (briefing page + appendix) and `.live` — a collapsed-by-default
/// disclosure under the notes pane so the capture page stays notes-first; the live style also
/// auto-refreshes on the cache-TTL cadence (5 min) so mid-meeting arrivals surface without
/// interaction, the timer living in the view's `.task` so it tears down with the live surface.
///
/// Gating (D-M6): rows render only while `viewModel.isGmailConnected`; when not connected the
/// section shows the enable hint — except that a Gmail-enabled account in `.needsReauth` shows
/// the reconnect hint instead (it must not masquerade as "Gmail not enabled") — and with no
/// Google account at all the section renders nothing. The spinner reads the per-meeting fetch
/// state, never `MeetingLLMService.searchingEmailsMeetingIDs` (M4 review note: that set spans
/// all of Q&A pass 2).
struct MeetingRelatedEmailsSection: View {
    enum Style {
        case standard
        case live
    }

    @ObservedObject private var viewModel = MeetingsViewModel.shared
    @ObservedObject private var emailsModel = MeetingsViewModel.shared.relatedEmailsModel
    let meeting: Meeting
    var style: Style = .standard

    /// The live disclosure starts collapsed (D-M6 — the transcript pane keeps its primacy).
    @State private var isLiveExpanded = false

    private var rows: [MeetingsViewModel.EmailRow] {
        emailsModel.rows(for: meeting)
    }

    var body: some View {
        Group {
            if !viewModel.hasGoogleAccounts && rows.isEmpty {
                // No account at all — never advertise unconfigured plumbing (D-M6).
                EmptyView()
            } else {
                switch style {
                case .standard:
                    standardBody
                case .live:
                    liveBody
                }
            }
        }
        .task(id: meeting.id) {
            await viewModel.fetchRelatedEmails(for: meeting)
            // Live only: auto-refresh at the cache-TTL cadence (never per-minute polling). The
            // loop dies with the `.task` when the view leaves the hierarchy or the meeting swaps.
            guard style == .live else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(GmailContextService.defaultCacheTTL * 1_000_000_000))
                guard !Task.isCancelled else { return }
                await viewModel.refreshRelatedEmails(for: meeting)
            }
        }
    }

    // MARK: - Styles

    private var standardBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            MeetingSectionLabel(String(localized: "meetingdoc.emails.title")) {
                if viewModel.isGmailConnected {
                    refreshAffordance
                }
            }
            content
        }
    }

    private var liveBody: some View {
        DisclosureGroup(isExpanded: $isLiveExpanded) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Spacer()
                    if viewModel.isGmailConnected {
                        refreshAffordance
                    }
                }
                content
            }
            .padding(.top, 4)
        } label: {
            Text(String(format: String(localized: "meetingdoc.emails.liveTitle"), rows.count))
                .font(.callout.weight(.medium))
        }
    }

    // MARK: - Shared content

    @ViewBuilder
    private var content: some View {
        if !viewModel.isGmailConnected {
            if let email = viewModel.gmailNeedsReauthAccountEmail {
                // D-M6: an owning account needing reauth is a reconnect problem, not an
                // enablement problem.
                Text(String(format: String(localized: "meetingdoc.emails.needsReauth"), email))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Text(String(localized: "meetingdoc.emails.notConnected"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        } else {
            if let failure = viewModel.lastEmailFetchError(for: meeting) {
                Label {
                    Text(String(format: String(localized: "meetingdoc.emails.fetchFailed"), failure))
                        .lineLimit(1)
                        .truncationMode(.tail)
                } icon: {
                    Image(systemName: "exclamationmark.triangle")
                }
                .font(.caption)
                .foregroundStyle(.orange)
                .help(failure)
            }

            if rows.isEmpty {
                Text(String(localized: "meetingdoc.emails.empty"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 2)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(rows) { row in
                        rowView(row)
                    }
                }
            }

            if let updatedAt = viewModel.relatedEmailsUpdatedAt(for: meeting) {
                Text(String(
                    format: String(localized: "meetingdoc.emails.updatedAt"),
                    updatedAt.formatted(date: .omitted, time: .shortened)
                ))
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var refreshAffordance: some View {
        if viewModel.isFetchingRelatedEmails(for: meeting) {
            ProgressView()
                .controlSize(.small)
        } else {
            Button {
                Task { await viewModel.refreshRelatedEmails(for: meeting) }
            } label: {
                Label(String(localized: "meetingdoc.emails.refresh"), systemImage: "arrow.clockwise")
            }
        }
    }

    // MARK: - Rows

    private func rowView(_ row: MeetingsViewModel.EmailRow) -> some View {
        Button {
            open(row)
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "envelope")
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.subject)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                        .foregroundStyle(.primary)
                    HStack(spacing: 6) {
                        Text(row.sender)
                            .lineLimit(1)
                        Text(row.dateLabel)
                        if let caption = row.accountCaption {
                            Text(caption)
                                .lineLimit(1)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    if !row.snippet.isEmpty {
                        Text(row.snippet)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 3)
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .help(String(localized: "meetingdoc.emails.open"))
    }

    /// D-M6 open-in-Gmail: `authuser`-pinned thread deep link (`GmailWebURL`, raw `messageID` +
    /// `accountEmail` straight off the row — no parsing), launched through the join launcher so
    /// the account's Chrome-profile preference is honored too.
    private func open(_ row: MeetingsViewModel.EmailRow) {
        guard let url = GmailWebURL.messageURL(messageID: row.messageID, accountEmail: row.accountEmail) else {
            return
        }
        MeetingJoinLauncher.open(url: url, accountSub: row.accountSub)
    }
}
