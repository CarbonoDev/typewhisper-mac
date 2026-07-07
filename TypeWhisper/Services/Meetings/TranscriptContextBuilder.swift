import Foundation

/// Pure, testable assembly of meeting transcript context for LLM prompts (plan D7).
///
/// It renders a meeting's ordered segments (and, optionally, in-meeting notes) into plain text,
/// then splits that text into character-budgeted chunks for a map/reduce strategy over long
/// (2-hour-scale) transcripts. There is no tokenizer and no embeddings — the budget is a
/// conservative characters-per-chunk heuristic (~4 chars/token), configurable per provider.
///
/// The builder holds no SwiftData references so it can be unit-tested in isolation; callers map
/// `MeetingSegment`/`MeetingNote` into the value types below.
enum TranscriptContextBuilder {
    /// Conservative default characters-per-chunk budget (~4 chars/token → ~4k tokens/chunk),
    /// leaving generous headroom under typical provider context windows.
    static let defaultCharBudget = 16_000

    /// A single transcript line for rendering. `speaker` is populated only once diarization/
    /// speaker mapping exists (M9); until then it is `nil` and lines render as bare text.
    struct Segment: Sendable {
        let start: Double
        let text: String
        let speaker: String?

        init(start: Double, text: String, speaker: String? = nil) {
            self.start = start
            self.text = text
            self.speaker = speaker
        }
    }

    /// A single in-meeting note for rendering. `offset` is elapsed seconds from capture start.
    struct Note: Sendable {
        let offset: Double?
        let text: String

        init(offset: Double?, text: String) {
            self.offset = offset
            self.text = text
        }
    }

    // MARK: - Rendering

    /// Render segments chronologically (by start time) into newline-separated lines. When a
    /// segment carries a speaker name it is prefixed `Name: text`, otherwise the bare text.
    static func renderTranscript(_ segments: [Segment]) -> String {
        segments
            .sorted { $0.start < $1.start }
            .map { segment -> String in
                let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if let speaker = segment.speaker?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !speaker.isEmpty {
                    return "\(speaker): \(text)"
                }
                return text
            }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    /// Render notes into newline-separated lines, each timestamp-prefixed when an offset is known.
    static func renderNotes(_ notes: [Note]) -> String {
        notes
            .map { note -> String in
                let text = note.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if let offset = note.offset {
                    return "[\(timestamp(offset))] \(text)"
                }
                return text
            }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    /// Compose the final user-text payload: the transcript (or a reduced set of partial
    /// summaries), optionally followed by a labeled notes block. The notes header is localized so
    /// the scaffolding language matches the rest of the UI.
    static func assemble(transcript: String, notes: String) -> String {
        let transcript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let notes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !notes.isEmpty else { return transcript }
        let header = String(localized: "meetings.output.notesHeader")
        return "\(transcript)\n\n\(header)\n\(notes)"
    }

    /// Assemble a reduce-stage payload that is *guaranteed* to fit `charBudget`.
    ///
    /// Map/reduce keeps each individual partial small, but with enough chunks the joined partials
    /// (plus notes) can themselves exceed the budget — leaving the single reduce call with an
    /// unbounded payload (M4 review finding 3). When the assembled input overflows, the
    /// higher-signal notes block is preserved and the transcript portion is truncated at a word
    /// boundary, with a localized truncation notice appended so the model knows content was cut.
    /// When the input already fits, this is exactly `assemble`.
    ///
    /// The notes block is itself capped at ~half the budget (`truncateWords`) so an oversized notes
    /// blob cannot blow the char-budget guarantee — previously the preserved notes were emitted
    /// whole, so notes larger than the budget produced an over-budget payload (M5-carried review
    /// finding 3). Notes that already fit within half the budget are preserved untouched.
    static func boundedAssemble(transcript: String, notes: String, charBudget: Int = defaultCharBudget) -> String {
        let assembled = assemble(transcript: transcript, notes: notes)
        guard charBudget > 0, assembled.count > charBudget else { return assembled }

        let notice = String(localized: "meetings.output.truncationNotice")
        let trimmedTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)

        if !trimmedNotes.isEmpty {
            let header = String(localized: "meetings.output.notesHeader")
            // Cap the notes block at ~half the budget so oversized notes cannot themselves break the
            // guarantee; notes under that cap are preserved whole.
            let notesBudget = max(0, charBudget / 2 - header.count - 2)
            let boundedNotes = truncateWords(trimmedNotes, to: notesBudget)
            let notesBlock = "\n\n\(header)\n\(boundedNotes)"
            // Reserve room for the (bounded) notes block and the notice so the total stays within
            // budget; the transcript absorbs the remaining overflow.
            let reserve = notesBlock.count + notice.count + 2
            let transcriptBudget = max(0, charBudget - reserve)
            let bounded = truncateWords(trimmedTranscript, to: transcriptBudget)
            return "\(bounded) \(notice)\(notesBlock)"
        }

        let bounded = truncateWords(trimmedTranscript, to: max(0, charBudget - notice.count - 1))
        return "\(bounded) \(notice)"
    }

    /// Truncate `text` to at most `charBudget` characters, backing off to the last whitespace so a
    /// word is never split. A single word longer than the budget is returned as its (over-budget)
    /// prefix rather than an empty string.
    static func truncateWords(_ text: String, to charBudget: Int) -> String {
        guard charBudget > 0 else { return "" }
        guard text.count > charBudget else { return text }
        let prefix = String(text.prefix(charBudget))
        if let lastSpace = prefix.lastIndex(where: { $0 == " " || $0 == "\n" || $0 == "\t" }) {
            let trimmed = prefix[..<lastSpace].trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return prefix
    }

    // MARK: - Chunking

    /// Split `text` into chunks each no longer than `charBudget`, never breaking a word.
    ///
    /// A transcript that already fits the budget is returned as a single chunk with its original
    /// line structure intact (the direct, single-call path). Once the budget is exceeded the text
    /// is re-flowed word-by-word so segment boundaries collapse to spaces but no word is ever
    /// split; a single word longer than the budget is emitted whole in its own (over-budget) chunk
    /// rather than truncated.
    static func chunk(_ text: String, charBudget: Int = defaultCharBudget) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        guard charBudget > 0, trimmed.count > charBudget else { return [trimmed] }

        var chunks: [String] = []
        var current = ""
        for token in trimmed.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }) {
            let word = String(token)
            if current.isEmpty {
                current = word
            } else if current.count + 1 + word.count <= charBudget {
                current += " " + word
            } else {
                chunks.append(current)
                current = word
            }
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    // MARK: - Helpers

    /// `mm:ss` (or `h:mm:ss` past an hour) for a non-negative seconds offset.
    static func timestamp(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%02d:%02d", minutes, secs)
    }
}
