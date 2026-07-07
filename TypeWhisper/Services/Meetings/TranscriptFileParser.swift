import Foundation

/// Pure parser that turns a transcript-only text file into normalized `[TranscriptionSegment]`
/// (plan M8 / D13). It handles the common shapes seen in exported meeting transcripts:
///
/// - **Google Meet** headers — `Speaker Name  HH:MM:SS` (name, a run of whitespace, a timestamp)
///   followed by the utterance on the next line(s).
/// - **`Speaker: utterance`** lines (one speaker turn per line).
/// - **Timestamped lines** — `HH:MM:SS utterance` or `[MM:SS] utterance`, optionally with a
///   `Speaker:` prefix after the timestamp.
/// - **Plain text** — no structure at all: paragraphs (blank-line separated) become segments with
///   no timing (all-zero timestamps, plan reminder 4).
///
/// It owns its **own** extension set and never touches `AudioFileService.supportedExtensions`
/// (plan D13: that set feeds AVAssetReader and adding `.txt` there would misroute text files).
/// Malformed lines are skipped rather than aborting the parse; best-effort start times are emitted
/// and end times are backfilled from the following segment's start (Meet gives no end times).
enum TranscriptFileParser {
    /// The file extensions this parser accepts. Deliberately disjoint from
    /// `AudioFileService.supportedExtensions` (plan D13). SRT/VTT are out of scope for v1 (plan M8).
    static let supportedExtensions: Set<String> = ["txt", "text", "md", "markdown"]

    /// An intermediate parsed entry before start/end resolution.
    private struct Entry {
        var text: String
        var start: Double?
        var speaker: String?
    }

    /// Parse raw transcript text into ordered, best-effort-timed segments. Order follows the file
    /// (chronological); segments with no recoverable timestamp get `start == end == 0` so the
    /// downstream deterministic renumbering keeps them stable (plan reminder 4).
    static func parse(_ raw: String) -> [TranscriptionSegment] {
        let normalized = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.components(separatedBy: "\n")

        var entries: [Entry] = []
        var pendingSpeaker: String?
        var pendingStart: Double?
        var utteranceBuffer: [String] = []

        func flushBuffer() {
            guard !utteranceBuffer.isEmpty else { return }
            let text = utteranceBuffer.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            utteranceBuffer.removeAll(keepingCapacity: true)
            guard !text.isEmpty else { return }
            entries.append(Entry(text: text, start: pendingStart, speaker: pendingSpeaker))
        }

        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                // A blank line closes the current utterance block (Meet / plain-text paragraph).
                flushBuffer()
                pendingSpeaker = nil
                pendingStart = nil
                continue
            }

            // 1) Google Meet header: `Speaker Name  HH:MM:SS` (or `Speaker Name: HH:MM:SS`).
            if let header = matchSpeakerTimestampHeader(line) {
                flushBuffer()
                pendingSpeaker = header.speaker
                pendingStart = header.start
                continue
            }

            // 2) Leading timestamp: `HH:MM:SS text` or `[MM:SS] text`, maybe with a `Speaker:` prefix.
            if let stamped = matchLeadingTimestamp(line) {
                flushBuffer()
                pendingSpeaker = nil
                pendingStart = nil
                let (speaker, text) = splitSpeakerPrefix(stamped.rest)
                guard !text.isEmpty else { continue }
                entries.append(Entry(text: text, start: stamped.seconds, speaker: speaker))
                continue
            }

            // 3) `Speaker: utterance` on a single line.
            if let turn = matchSpeakerColon(line) {
                flushBuffer()
                pendingSpeaker = nil
                pendingStart = nil
                entries.append(Entry(text: turn.text, start: nil, speaker: turn.speaker))
                continue
            }

            // 4) Plain utterance line — either the body under a Meet header (keeps the pending
            //    speaker/start) or free-form plain text (accumulated into a paragraph).
            utteranceBuffer.append(line)
        }
        flushBuffer()

        return buildSegments(from: entries)
    }

    // MARK: - Segment assembly

    private static func buildSegments(from entries: [Entry]) -> [TranscriptionSegment] {
        guard !entries.isEmpty else { return [] }
        let starts = entries.map { $0.start ?? 0 }
        var segments: [TranscriptionSegment] = []
        segments.reserveCapacity(entries.count)
        for (index, entry) in entries.enumerated() {
            let start = starts[index]
            var end = start
            if index + 1 < entries.count {
                let nextStart = starts[index + 1]
                if nextStart > start { end = nextStart }
            }
            let speaker = entry.speaker?.trimmingCharacters(in: .whitespaces)
            segments.append(
                TranscriptionSegment(
                    text: entry.text,
                    start: start,
                    end: end,
                    speakerLabel: (speaker?.isEmpty == false) ? speaker : nil
                )
            )
        }
        return segments
    }

    // MARK: - Line matchers

    /// A Meet-style header: a plausible speaker name, a separator (a run of 2+ spaces/tabs, or a
    /// colon + space), then a trailing timestamp. Returns nil for anything else.
    private static func matchSpeakerTimestampHeader(_ line: String) -> (speaker: String, start: Double)? {
        guard let range = line.range(
            of: #"^(.+?)(?:[ \t]{2,}|:[ \t]+)\[?(\d{1,2}:\d{2}(?::\d{2})?)\]?$"#,
            options: .regularExpression
        ), range.lowerBound == line.startIndex else {
            return nil
        }
        guard let (name, stampString) = captureTwo(
            in: line,
            pattern: #"^(.+?)(?:[ \t]{2,}|:[ \t]+)\[?(\d{1,2}:\d{2}(?::\d{2})?)\]?$"#
        ) else { return nil }
        let speaker = name.trimmingCharacters(in: .whitespaces)
        guard looksLikeSpeakerName(speaker), let seconds = parseTimestamp(stampString) else { return nil }
        return (speaker, seconds)
    }

    /// A leading timestamp followed by the utterance. `[00:12] hi`, `00:00:12 - hi`, `1:02 hi`.
    private static func matchLeadingTimestamp(_ line: String) -> (seconds: Double, rest: String)? {
        guard let (stampString, rest) = captureTwo(
            in: line,
            pattern: #"^\[?(\d{1,2}:\d{2}(?::\d{2})?)\]?[\s\-–—:]+(.+)$"#
        ), let seconds = parseTimestamp(stampString) else { return nil }
        let trimmed = rest.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        return (seconds, trimmed)
    }

    /// A `Speaker: utterance` line. Guarded by `looksLikeSpeakerName` so ordinary prose that happens
    /// to contain a colon is not mistaken for a speaker turn.
    private static func matchSpeakerColon(_ line: String) -> (speaker: String, text: String)? {
        guard let colonIndex = line.firstIndex(of: ":") else { return nil }
        let name = String(line[line.startIndex..<colonIndex]).trimmingCharacters(in: .whitespaces)
        let text = String(line[line.index(after: colonIndex)...]).trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, looksLikeSpeakerName(name) else { return nil }
        return (name, text)
    }

    /// Split a `Speaker: text` prefix off an already-timestamp-stripped remainder, if present.
    private static func splitSpeakerPrefix(_ text: String) -> (speaker: String?, text: String) {
        if let turn = matchSpeakerColon(text) {
            return (turn.speaker, turn.text)
        }
        return (nil, text)
    }

    // MARK: - Helpers

    /// A conservative name test: 1–5 words, starts with a letter, no sentence-ending punctuation,
    /// bounded length. Keeps false positives (prose with a mid-sentence colon) low without a
    /// dictionary.
    private static func looksLikeSpeakerName(_ candidate: String) -> Bool {
        guard !candidate.isEmpty, candidate.count <= 40 else { return false }
        guard let first = candidate.unicodeScalars.first, CharacterSet.letters.contains(first) else { return false }
        if candidate.rangeOfCharacter(from: CharacterSet(charactersIn: ".!?")) != nil { return false }
        let words = candidate.split(separator: " ")
        return words.count >= 1 && words.count <= 5
    }

    /// Parse `HH:MM:SS`, `H:MM:SS`, or `MM:SS` into seconds. Rejects out-of-range minute/second
    /// fields so a malformed line is skipped rather than yielding a garbage time.
    static func parseTimestamp(_ string: String) -> Double? {
        let parts = string.split(separator: ":")
        guard parts.count == 2 || parts.count == 3 else { return nil }
        var values: [Int] = []
        for part in parts {
            guard let value = Int(part), value >= 0 else { return nil }
            values.append(value)
        }
        if values.count == 3 {
            guard values[1] < 60, values[2] < 60 else { return nil }
            return Double(values[0] * 3600 + values[1] * 60 + values[2])
        }
        guard values[1] < 60 else { return nil }
        return Double(values[0] * 60 + values[1])
    }

    /// Return the first two capture groups of `pattern` applied to `line`, or nil.
    private static func captureTwo(in line: String, pattern: String) -> (String, String)? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        guard let match = regex.firstMatch(in: line, range: range), match.numberOfRanges >= 3 else { return nil }
        guard let first = Range(match.range(at: 1), in: line),
              let second = Range(match.range(at: 2), in: line) else { return nil }
        return (String(line[first]), String(line[second]))
    }
}
