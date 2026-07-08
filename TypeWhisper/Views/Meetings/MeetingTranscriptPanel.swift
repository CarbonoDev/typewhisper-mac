import SwiftUI
import AppKit

/// [Track B] The meeting transcript panel (plan D4): speaker-attributed bubbles with mapped names,
/// `SPEAKER_ME` → "(Me)" right-alignment, timestamp separators at silence gaps, in-panel search,
/// copy, source tags on imported/merged segments, and a minimize control that folds it back into
/// the bottom bar's waveform button.
///
/// This type also owns the transcript display helpers `speakerName` / `timestamp` (moved here when
/// the old `MeetingDetailView` was retired, per plan D4).
struct MeetingTranscriptPanel: View {
    @ObservedObject private var viewModel = MeetingsViewModel.shared
    @ObservedObject var model: MeetingDocumentModel
    let meeting: Meeting

    private var bubbles: [MeetingsViewModel.TranscriptBubble] {
        // Speaker-recognition amendment, Fix A: while THIS meeting is capturing, suppress all speaker
        // attribution at the render choke point so stale labels on preserved/restarted segments never
        // appear on the live transcript.
        let suppressSpeakers = viewModel.isCapturing && viewModel.activeMeeting?.id == meeting.id
        let all = MeetingsViewModel.transcriptBubbles(
            segments: meeting.segments,
            speakerMap: meeting.speakerMap,
            suppressSpeakers: suppressSpeakers
        )
        return MeetingsViewModel.filterTranscriptBubbles(all, query: model.transcriptSearch)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            searchField
            Divider()
            content
        }
        .frame(width: 380)
        .background(.regularMaterial)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(String(localized: "meetingdoc.transcript.title"))
                .font(.headline)
            Spacer()
            Button {
                copyTranscript()
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .help(String(localized: "meetingdoc.transcript.copyAll"))
            .disabled(meeting.segments.isEmpty)

            Button {
                model.isTranscriptPanelOpen = false
            } label: {
                Image(systemName: "chevron.down.circle")
            }
            .buttonStyle(.borderless)
            .help(String(localized: "meetingdoc.transcript.minimize"))
        }
        .padding(12)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField(String(localized: "meetingdoc.transcript.searchPlaceholder"), text: $model.transcriptSearch)
                .textFieldStyle(.plain)
            if !model.transcriptSearch.isEmpty {
                Button {
                    model.transcriptSearch = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var content: some View {
        if meeting.segments.isEmpty {
            emptyState
        } else if bubbles.isEmpty {
            noMatches
        } else {
            ScrollView {
                // Virtualized for large / growing transcripts (D4).
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(bubbles) { bubble in
                        row(for: bubble)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            if viewModel.isCapturing, viewModel.activeMeeting?.id == meeting.id {
                ProgressView().controlSize(.small)
                Text(String(localized: "meetingdoc.transcript.listening"))
                    .foregroundStyle(.secondary)
            } else {
                Text(String(localized: "meetingdoc.transcript.empty"))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var noMatches: some View {
        Text(String(localized: "meetingdoc.transcript.noMatches"))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding()
    }

    @ViewBuilder
    private func row(for bubble: MeetingsViewModel.TranscriptBubble) -> some View {
        switch bubble.kind {
        case .gap:
            HStack {
                Spacer()
                Text(bubble.timestamp)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(.secondary.opacity(0.12), in: Capsule())
                Spacer()
            }
        case .speech:
            speechBubble(bubble)
        }
    }

    private func speechBubble(_ bubble: MeetingsViewModel.TranscriptBubble) -> some View {
        // "Me" segments render right-aligned; everyone else left-aligned (D4).
        HStack {
            if bubble.isMe { Spacer(minLength: 40) }
            VStack(alignment: bubble.isMe ? .trailing : .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if let name = bubble.displayName {
                        Text(bubble.isMe ? String(format: String(localized: "meetingdoc.transcript.meLabel"), name) : name)
                            .font(.caption.bold())
                            .foregroundStyle(.secondary)
                    }
                    Text(bubble.timestamp)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                    if bubble.isImported {
                        Text(String(localized: "meetingdoc.transcript.importedTag"))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.secondary.opacity(0.15), in: Capsule())
                    }
                }
                Text(bubble.text)
                    .font(.callout)
                    .textSelection(.enabled)
                    .multilineTextAlignment(bubble.isMe ? .trailing : .leading)
                    .padding(9)
                    .background(
                        (bubble.isMe ? Color.accentColor.opacity(0.14) : Color.secondary.opacity(0.10)),
                        in: RoundedRectangle(cornerRadius: 10)
                    )
            }
            if !bubble.isMe { Spacer(minLength: 40) }
        }
    }

    private func copyTranscript() {
        let text = MeetingTranscriptPanel.plainText(for: meeting)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: - Transcript display helpers (moved from the retired MeetingDetailView, plan D4)

    /// `mm:ss` timestamp string for an elapsed offset in seconds.
    nonisolated static func timestamp(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    /// The display speaker for a segment: its raw `SPEAKER_xx` label resolved through the meeting's
    /// speaker map (plan M9), the raw label when unmapped, or nil when the segment is unlabeled.
    nonisolated static func speakerName(for segment: MeetingSegment, speakerMap: [String: String]) -> String? {
        guard let label = segment.speakerLabel?.trimmingCharacters(in: .whitespacesAndNewlines),
              !label.isEmpty else { return nil }
        if let mapped = speakerMap[label]?.trimmingCharacters(in: .whitespacesAndNewlines), !mapped.isEmpty {
            return mapped
        }
        return label
    }

    /// A plain-text rendering of the whole transcript for the copy action.
    nonisolated static func plainText(for meeting: Meeting) -> String {
        let map = meeting.speakerMap
        return meeting.segments
            .sorted { $0.order < $1.order }
            .map { segment in
                let name = speakerName(for: segment, speakerMap: map)
                let prefix = name.map { "\($0): " } ?? ""
                return "[\(timestamp(segment.start))] \(prefix)\(segment.text)"
            }
            .joined(separator: "\n")
    }
}
