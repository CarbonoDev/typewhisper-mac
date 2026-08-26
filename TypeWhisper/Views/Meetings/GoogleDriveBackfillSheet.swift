import SwiftUI

/// Per-account "Import past transcripts" sheet ([Google Phase 2 · M4], D-D7): scan the account's
/// Drive for Gemini notes docs (the normative query, no watermark bound), preview them as
/// planner rows (clean title · real date · disposition), then batch-import the selection under
/// one `.driveBackfill` job — serial with the rate-limit pause, cancellable between files, with
/// a final summary. All decisions live off the view: rows come from
/// `GoogleDriveBackfillPlanner` (pure, tested) and the batch from
/// `GoogleDriveTranscriptImporter.runBackfill` (F4 execution-time re-check per file), so a
/// preview gone stale mid-batch can never double-import.
struct GoogleDriveBackfillSheet: View {
    let account: GoogleAccount

    @Environment(\.dismiss) private var dismiss

    private enum Phase: Equatable {
        case scanning
        case empty
        case scanFailed(String)
        case preview
        case importing(current: Int, total: Int)
        case summary(GoogleDriveTranscriptImporter.BackfillSummary)
    }

    @State private var phase: Phase = .scanning
    @State private var rows: [GoogleDriveBackfillPlanner.Row] = []
    @State private var selection: Set<String> = []
    @State private var jobID: UUID?
    /// The scan hit `GoogleDriveAPI.maxListPages` — the preview below is a partial view of the
    /// account's history and must say so (review fix), never look like the complete answer.
    @State private var isPreviewTruncated = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(String(localized: "google.drive.backfill.title"))
                .font(.headline)
            Text(account.email)
                .font(.caption)
                .foregroundStyle(.secondary)
            content
        }
        .padding(20)
        .frame(width: 520, height: 440, alignment: .topLeading)
        .task { await scan() }
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .scanning:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(String(localized: "google.drive.backfill.scanning"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            closeButtonRow

        case .empty:
            Text(String(localized: "google.drive.backfill.empty"))
                .font(.callout)
                .foregroundStyle(.secondary)
            truncationNotice
            Spacer()
            closeButtonRow

        case .scanFailed(let message):
            Text(message)
                .font(.caption)
                .foregroundStyle(.red)
            Spacer()
            closeButtonRow

        case .preview:
            previewList

        case .importing(let current, let total):
            VStack(alignment: .leading, spacing: 8) {
                ProgressView(value: Double(current), total: Double(max(total, 1)))
                Text(String(format: String(localized: "google.drive.backfill.progress"), current, total))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            HStack {
                Spacer()
                Button(String(localized: "google.drive.backfill.cancel")) {
                    // Cancel stops after the in-flight file; completed files stay imported
                    // (ledgered) — the summary then reports the partial tally.
                    if let jobID {
                        JobQueueService.shared.cancel(jobID)
                    }
                }
            }

        case .summary(let summary):
            Text(String(
                format: String(localized: "google.drive.backfill.summary"),
                summary.imported + summary.merged,
                summary.merged,
                summary.skipped,
                summary.failed
            ))
            .font(.callout)
            Spacer()
            closeButtonRow
        }
    }

    private var closeButtonRow: some View {
        HStack {
            Spacer()
            Button(String(localized: "meetings.import.close")) { dismiss() }
        }
    }

    // MARK: - Preview

    private var selectableRows: [GoogleDriveBackfillPlanner.Row] {
        rows.filter(\.isSelectable)
    }

    /// Rendered whenever the page guard cut the scan short: the list is a partial view, and the
    /// remedy (run the backfill again once these are imported) has to be said out loud.
    @ViewBuilder
    private var truncationNotice: some View {
        if isPreviewTruncated {
            Label(String(localized: "google.drive.backfill.truncated"), systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var previewList: some View {
        VStack(alignment: .leading, spacing: 8) {
            truncationNotice
            Toggle(
                String(localized: "google.drive.backfill.selectAll"),
                isOn: Binding(
                    get: { !selectableRows.isEmpty && selection.count == selectableRows.count },
                    set: { all in
                        selection = all ? Set(selectableRows.map(\.id)) : []
                    }
                )
            )
            .controlSize(.small)
            .disabled(selectableRows.isEmpty)

            List(rows) { row in
                previewRow(row)
            }
            .listStyle(.inset)

            HStack {
                Spacer()
                Button(String(localized: "google.drive.backfill.cancel")) { dismiss() }
                Button(String(
                    format: String(localized: "google.drive.backfill.importCount"),
                    selection.count
                )) {
                    startImport()
                }
                .buttonStyle(.borderedProminent)
                .disabled(selection.isEmpty)
            }
        }
    }

    private func previewRow(_ row: GoogleDriveBackfillPlanner.Row) -> some View {
        HStack(spacing: 8) {
            Toggle(
                "",
                isOn: Binding(
                    get: { selection.contains(row.id) },
                    set: { on in
                        if on { selection.insert(row.id) } else { selection.remove(row.id) }
                    }
                )
            )
            .labelsHidden()
            .disabled(!row.isSelectable)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.title)
                    .font(.callout)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    if let date = row.date {
                        Text(date.formatted(date: .abbreviated, time: .shortened))
                    }
                    Text(dispositionLabel(row.disposition))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .opacity(row.isSelectable ? 1 : 0.5)
    }

    private func dispositionLabel(_ disposition: GoogleDriveBackfillPlanner.Disposition) -> String {
        switch disposition {
        case .merge(_, let meetingTitle):
            String(format: String(localized: "google.drive.backfill.mergeInto"), meetingTitle)
        case .create:
            String(localized: "google.drive.backfill.newMeeting")
        case .alreadyImported:
            String(localized: "google.drive.backfill.alreadyImported")
        }
    }

    // MARK: - Scan / batch

    private func scan() async {
        let container = ServiceContainer.shared
        do {
            let listing = try await container.googleDriveSyncEngine.scanAllFiles(sub: account.id)
            isPreviewTruncated = listing.isTruncated
            let planned = GoogleDriveBackfillPlanner.rows(
                files: listing.files,
                sub: account.id,
                ledger: container.googleDriveImportLedger,
                candidates: GoogleDriveBackfillPlanner.candidates(of: container.meetingService.meetings)
            )
            rows = planned
            selection = Set(planned.filter(\.isSelectable).map(\.id))
            phase = planned.isEmpty ? .empty : .preview
        } catch {
            phase = .scanFailed(error.localizedDescription)
        }
    }

    /// One `.driveBackfill` job for the whole selection (D-D6): user-initiated, cancellable, the
    /// io lane. The operation walks the selection serially (`runBackfill` — 250 ms pause, F4
    /// re-check per file) publishing `(current, total)` into the sheet.
    private func startImport() {
        let files = rows.filter { selection.contains($0.id) && $0.isSelectable }.map(\.file)
        guard !files.isEmpty else { return }
        phase = .importing(current: 0, total: files.count)

        let importer = ServiceContainer.shared.googleDriveTranscriptImporter
        let sub = account.id
        jobID = JobQueueService.shared.enqueue(
            kind: .driveBackfill,
            meetingID: nil,
            priority: .userInitiated,
            progressLabel: account.email
        ) {
            let summary = await importer.runBackfill(
                files: files,
                sub: sub,
                onProgress: { current, total in
                    phase = .importing(current: current, total: total)
                }
            )
            phase = .summary(summary)
        }
    }
}
