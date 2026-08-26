import SwiftUI

/// The per-meeting "Related documents" section (Amendment 2, DB8, M8). Rendered in
/// `MeetingDocumentBody` alongside `MeetingBriefView`: a Find-related / refresh action, the resolved
/// union of folder-attached + discovered + manual notes (each removable), and a manual add via the
/// shared `VaultContextPickerView`. Shown only when a vault is connected; otherwise a friendly inert
/// state (mirrors the folder detail view's Context section). The *folder-level* attached scope stays in
/// the folder detail view — this is the complementary per-meeting tier (DB5).
struct MeetingRelatedDocsSection: View {
    @ObservedObject private var viewModel = MeetingsViewModel.shared
    // Observe the queue directly so the working badge / failed hint react to `.relatedDiscovery` job
    // state (the VM does not republish on queue mutations — plan J2 §CC7).
    @ObservedObject private var jobQueue = JobQueueService.shared
    let meeting: Meeting

    @State private var isPresentingPicker = false

    private var rows: [MeetingsViewModel.RelatedDocRow] {
        viewModel.relatedDocuments(for: meeting)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header

            if !viewModel.isVaultConnected {
                Text(String(localized: "meetingdoc.related.notConnected"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                connectedBody
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        MeetingSectionLabel(String(localized: "meetingdoc.related.title")) {
            if viewModel.isVaultConnected {
                findButton
            }
        }
    }

    @ViewBuilder
    private var findButton: some View {
        if viewModel.isDiscoveringRelated(for: meeting) {
            ProgressView()
                .controlSize(.small)
        } else {
            let hasExisting = !rows.isEmpty
            Button {
                viewModel.findRelatedDocuments(for: meeting)
            } label: {
                Label(
                    String(localized: hasExisting ? "meetingdoc.related.refresh" : "meetingdoc.related.find"),
                    systemImage: "doc.text.magnifyingglass"
                )
            }
        }
    }

    // MARK: - Connected body

    @ViewBuilder
    private var connectedBody: some View {
        if viewModel.lastRelatedDiscoveryFailed(for: meeting) {
            Label {
                Text(relatedFailureText)
                    .lineLimit(1)
                    .truncationMode(.tail)
            } icon: {
                Image(systemName: "exclamationmark.triangle")
            }
            .font(.caption)
            .foregroundStyle(.orange)
            // The banner truncates to one line; the full reason stays available on hover for diagnosis.
            .help(relatedFailureText)
        }

        if viewModel.relatedDocsNoVaultContext(for: meeting) {
            Text(String(localized: "meetingdoc.related.noVaultContextHint"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        if rows.isEmpty {
            Text(String(localized: "meetingdoc.related.empty"))
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

        Button {
            isPresentingPicker = true
        } label: {
            Label(String(localized: "meetingdoc.related.add"), systemImage: "plus")
        }
        .sheet(isPresented: $isPresentingPicker) {
            VaultContextPickerView(
                onSelect: { entries in
                    viewModel.addManualRelatedNotes(entries, for: meeting)
                },
                notesOnly: true
            )
        }
    }

    private func rowView(_ row: MeetingsViewModel.RelatedDocRow) -> some View {
        HStack(spacing: 8) {
            Image(systemName: row.isDirectory ? "folder" : "doc.text")
                .foregroundStyle(row.isMissing ? Color.secondary : .secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.displayName)
                    .lineLimit(1)
                    .foregroundStyle(row.isMissing ? Color.secondary : .primary)
                Text(row.folderCaption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Text(provenanceCaption(for: row))
                .font(.caption2)
                .foregroundStyle(.secondary)
            if row.isRemovable {
                Button {
                    viewModel.removeRelatedNote(row.path, for: meeting)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(String(localized: "meetingdoc.related.remove"))
            } else {
                // Folder-prefix rows expand live to every note under them — removing one here would
                // record a directory-path exclusion the consumption scope can't honor (it matches note
                // paths exactly). Folder-level scope is edited in the folder detail view instead, so the
                // row shows a hint rather than an ineffective ✕ (Amendment 2, DB4/DB5).
                Image(systemName: "folder.badge.gearshape")
                    .foregroundStyle(.secondary)
                    .help(String(localized: "meetingdoc.related.folderScopeHint"))
            }
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 8)
        .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
    }

    /// The failure banner text: the generic "last search couldn't complete" hint followed by the
    /// specific localized reason from the failed job when one is present, so diagnosis doesn't require
    /// opening the activity popover. Falls back to the generic hint alone when no reason is recorded.
    private var relatedFailureText: String {
        let generic = String(localized: "meetingdoc.related.failedHint")
        guard let reason = viewModel.lastRelatedDiscoveryFailureReason(for: meeting)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !reason.isEmpty else {
            return generic
        }
        return "\(generic) \(reason)"
    }

    private func provenanceCaption(for row: MeetingsViewModel.RelatedDocRow) -> String {
        if row.isMissing {
            return String(localized: "meetingdoc.related.provenance.missing")
        }
        switch row.provenance {
        case .folder:
            return String(localized: "meetingdoc.related.provenance.folder")
        case .suggested:
            return String(localized: "meetingdoc.related.provenance.suggested")
        case .manual:
            return String(localized: "meetingdoc.related.provenance.manual")
        }
    }
}
