import Foundation
import TypeWhisperPluginSDK

/// Accumulation + rendering state for mirroring a live meeting into the LiveTranscript window
/// (addendum, Track A). Kept out of the big plugin file. Pure and testable: no UI, no timers.
///
/// Lifecycle: `.started` resets and binds to a meeting id; `.transcriptSegment` appends the
/// batch's stabilized segments in arrival order (only for the bound meeting, and only until
/// finished); `.transcriptReady` replaces the accumulated text with the authoritative final
/// transcript; `.ended` marks the mirror finished (no further appends accepted).
///
/// Not actor-isolated: a plain state holder touched only from the plugin's `@MainActor`
/// meeting-event handler (and unit tests on the main actor).
final class MeetingTranscriptMirror {
    private(set) var activeMeetingID: UUID?
    private(set) var isFinished = false
    private var lines: [String] = []

    /// The text to display: accumulated stabilized segments joined by spaces, or the final
    /// transcript verbatim once `.transcriptReady` has replaced it.
    private(set) var renderedText: String = ""

    init() {}

    /// Begin mirroring a meeting. Resets all prior state.
    func started(meetingID: UUID) {
        activeMeetingID = meetingID
        isFinished = false
        lines = []
        renderedText = ""
    }

    /// Append a batch of stabilized segments for the active meeting. Ignores batches for a
    /// different meeting or arriving after the mirror finished.
    func appendSegments(_ payload: MeetingTranscriptSegmentPayload) {
        guard let activeMeetingID, payload.meetingID == activeMeetingID, !isFinished else { return }
        for segment in payload.segments {
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            lines.append(text)
        }
        renderedText = lines.joined(separator: " ")
    }

    /// Replace the accumulated text with the authoritative final transcript.
    func transcriptReady(_ payload: MeetingTranscriptReadyPayload) {
        guard let activeMeetingID, payload.meetingID == activeMeetingID else { return }
        let full = payload.fullText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !full.isEmpty {
            renderedText = full
        }
    }

    /// Mark the mirror finished; subsequent segment batches are ignored.
    func ended(meetingID: UUID) {
        guard activeMeetingID == meetingID else { return }
        isFinished = true
    }

    /// Clear all state (e.g. on deactivate).
    func reset() {
        activeMeetingID = nil
        isFinished = false
        lines = []
        renderedText = ""
    }
}
