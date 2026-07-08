import SwiftUI

/// Minimal main-window sidebar activity pill (job-queue plan J1): a count-only summary of background
/// jobs, shown directly above the live-recording band. Renders nothing when the queue is idle. The
/// full popover (cancel / retry / per-job errors) arrives in J3.
struct MeetingActivityIndicator: View {
    @ObservedObject private var jobQueue = JobQueueService.shared

    var body: some View {
        let running = jobQueue.runningCount
        let queued = jobQueue.queuedCount
        if running + queued > 0 {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                VStack(alignment: .leading, spacing: 1) {
                    if running > 0 {
                        Text(String(format: String(localized: "meetings.jobs.indicator.running"), running))
                            .font(.callout)
                    }
                    if queued > 0 {
                        Text(String(format: String(localized: "meetings.jobs.indicator.queued"), queued))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text(String(localized: "meetings.jobs.indicator.accessibility")))
        }
    }
}
