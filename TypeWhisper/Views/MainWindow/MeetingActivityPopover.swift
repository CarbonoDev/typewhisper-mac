import SwiftUI

/// The background-activity popover (job-queue plan J3): the full affordance behind the sidebar
/// activity indicator. Lists the queue's running and queued jobs (each with its kind label, the
/// meeting it belongs to, and a Cancel button) and recently-failed jobs (with their error message,
/// Retry, and Dismiss). Everything is sourced from the shared `JobQueueService` snapshot via the pure
/// `MeetingJobPresentation` sectioning, so it reflects real queue state regardless of navigation.
struct MeetingActivityPopover: View {
    @ObservedObject private var jobQueue = JobQueueService.shared
    @ObservedObject private var viewModel = MeetingsViewModel.shared

    var body: some View {
        let sections = MeetingJobPresentation.sections(from: jobQueue.jobs)
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if sections.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if !sections.running.isEmpty {
                            section(String(localized: "meetings.jobs.section.running"), jobs: sections.running)
                        }
                        if !sections.queued.isEmpty {
                            section(String(localized: "meetings.jobs.section.queued"), jobs: sections.queued)
                        }
                        if !sections.failed.isEmpty {
                            section(String(localized: "meetings.jobs.section.failed"), jobs: sections.failed)
                        }
                    }
                    .padding(12)
                }
            }
        }
        .frame(width: 320)
        .frame(maxHeight: 420)
    }

    private var header: some View {
        Text(String(localized: "meetings.jobs.popover.title"))
            .font(.headline)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
    }

    private var emptyState: some View {
        Text(String(localized: "meetings.jobs.popover.empty"))
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(24)
    }

    private func section(_ title: String, jobs: [MeetingJob]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
            ForEach(jobs) { job in
                row(job)
            }
        }
    }

    @ViewBuilder
    private func row(_ job: MeetingJob) -> some View {
        HStack(alignment: .top, spacing: 8) {
            if job.state == .running {
                ProgressView().controlSize(.small)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(job.kind.displayName)
                    .font(.callout)
                if let title = meetingTitle(for: job.meetingID) {
                    Text(title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if case .failed(let message) = job.state {
                    Text(message)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 4)
            actions(for: job)
        }
    }

    @ViewBuilder
    private func actions(for job: MeetingJob) -> some View {
        if case .failed = job.state {
            HStack(spacing: 8) {
                Button(String(localized: "meetings.jobs.retry")) { jobQueue.retry(job.id) }
                    .buttonStyle(.borderless)
                Button(String(localized: "meetings.jobs.dismiss")) { jobQueue.dismiss(job.id) }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
            }
        } else if MeetingJobPresentation.canCancel(job) {
            Button(String(localized: "meetings.jobs.cancel")) { jobQueue.cancel(job.id) }
                .buttonStyle(.borderless)
        } else if job.kind == .finalTranscription && job.state == .queued {
            // Cancel is withheld while a final pass is queued (finding 1); explain why so the row is
            // not silently missing an affordance.
            Text(String(localized: "meetings.jobs.finalTranscription.queuedHint"))
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: 120, alignment: .trailing)
        }
    }

    /// Resolve a meeting's title for a row (mirrors the auto-brief status lookup). `nil` for a
    /// new-meeting `audioImport` that has no meeting yet.
    private func meetingTitle(for meetingID: UUID?) -> String? {
        guard let meetingID else { return nil }
        return viewModel.meetings.first { $0.id == meetingID }?.title
    }
}
