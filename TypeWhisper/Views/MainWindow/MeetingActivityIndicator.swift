import SwiftUI

/// Main-window sidebar activity pill (job-queue plan J1, extended in J3): a count summary of
/// background jobs shown directly above the live-recording band. Renders nothing when the queue is
/// fully idle *and* has no retained failure. Tapping it opens the `MeetingActivityPopover` with the
/// per-job cancel / retry / error affordances. A red dot appears while any job has failed.
struct MeetingActivityIndicator: View {
    @ObservedObject private var jobQueue = JobQueueService.shared
    @State private var showingPopover = false

    var body: some View {
        let running = jobQueue.runningCount
        let queued = jobQueue.queuedCount
        let hasFailure = jobQueue.hasFailedJob
        if running + queued > 0 || hasFailure {
            Button {
                showingPopover.toggle()
            } label: {
                HStack(spacing: 8) {
                    if running + queued > 0 {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "exclamationmark.circle.fill")
                            .foregroundStyle(.red)
                    }
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
                        if running + queued == 0 && hasFailure {
                            Text(String(localized: "meetings.jobs.section.failed"))
                                .font(.callout)
                                .foregroundStyle(.red)
                        }
                    }
                    Spacer(minLength: 0)
                    if hasFailure && running + queued > 0 {
                        Circle()
                            .fill(.red)
                            .frame(width: 7, height: 7)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .accessibilityLabel(Text(String(localized: "meetings.jobs.indicator.accessibility")))
            .popover(isPresented: $showingPopover, arrowEdge: .trailing) {
                MeetingActivityPopover()
            }
        }
    }
}
