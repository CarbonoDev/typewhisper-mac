import Foundation

/// Pure parser that turns a transcript-only text file into normalized `[TranscriptionSegment]`
/// (plan M8 / D13). It handles the common shapes seen in exported meeting transcripts:
///
/// - **Gemini Notes** — the Google "Notas de Gemini" / "Notes by Gemini" markdown export:
///   a `## **Title - Transcripción**` heading, running `### **HH:MM:SS**` section headers, and
///   `**Speaker Name:** utterance` turns (detected first; see `parseGeminiNotes`).
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

        // 0) Gemini Notes export — markdown-structured, detected as a whole document so the
        //    markdown stripping it needs never leaks into the plain-text rungs below.
        if let gemini = parseGeminiNotes(lines) {
            return gemini
        }

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

    // MARK: - Gemini Notes export

    /// A `### **HH:MM:SS**` section: the running start time of the block and the speaker turns
    /// under it (in file order).
    private struct GeminiSection {
        var start: Double
        var turns: [(speaker: String, text: String)] = []
    }

    /// Parse the Google Gemini meeting-notes transcript export ("Notas de Gemini" / "Notes by
    /// Gemini"). The document shape:
    ///
    /// - a date line (`jul 22, 2026`) before any heading — skipped;
    /// - `## **<Title> \- Transcripción**` (or `- Transcript`) — the export escapes markdown
    ///   punctuation with backslashes (`\-`, `\.`), which is unescaped per-line here, never
    ///   globally — skipped;
    /// - `### **HH:MM:SS**` running section headers — set the start time of the block that follows;
    /// - `### **La transcripción finalizó después de HH:MM:SS**` / "Transcript ended" — the closing
    ///   line; its timestamp is the total duration and bounds the last section;
    /// - `**Speaker Name:** utterance` turns (the colon sits *inside* the bold markers), blank-line
    ///   separated; a non-blank line while a turn is open continues that turn;
    /// - a trailing `*italic*` disclaimer — never a turn, so it is dropped like the date line.
    ///
    /// **Timing choice (documented):** the export only timestamps sections, not turns. Turns inside
    /// a section are interpolated linearly between the section's start and the next boundary (the
    /// next section header, or the closing line's total duration), **weighted by utterance length**
    /// so a long monologue occupies proportionally more of the section than a one-word interjection.
    /// A last section with no closing boundary degrades to all turns carrying the section start.
    /// This keeps every turn's time inside its section and monotonic across the file — real enough
    /// for the merge-import overlap span and for transcript display.
    ///
    /// Returns nil when the document does not look like a Gemini export (no bold speaker turns, or
    /// neither a timestamped section header nor a transcript title heading), so every other format
    /// falls through to the generic rungs unchanged.
    private static func parseGeminiNotes(_ lines: [String]) -> [TranscriptionSegment]? {
        var sections: [GeminiSection] = []
        var finalBound: Double?
        var sawTimestampHeader = false
        var sawTranscriptTitle = false
        var inTurn = false

        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                inTurn = false
                continue
            }

            // `### **…**` — a running timestamp header, or the closing "transcript ended" line.
            if line.hasPrefix("###") {
                inTurn = false
                guard let inner = boldHeadingText(line, hashes: "###") else { continue }
                let unescaped = unescapeMarkdown(inner)
                if let seconds = parseTimestamp(unescaped) {
                    sections.append(GeminiSection(start: seconds))
                    sawTimestampHeader = true
                } else if let seconds = embeddedTimestamp(in: unescaped) {
                    // Closing line ("La transcripción finalizó después de 00:41:08"): total duration.
                    finalBound = seconds
                    sawTimestampHeader = true
                }
                continue
            }

            // `## **<Title> - Transcripción**` — the document title heading, never a segment.
            if line.hasPrefix("##") {
                inTurn = false
                if let inner = boldHeadingText(line, hashes: "##") {
                    let unescaped = unescapeMarkdown(inner)
                    if unescaped.localizedCaseInsensitiveContains("transcripción")
                        || unescaped.localizedCaseInsensitiveContains("transcript") {
                        sawTranscriptTitle = true
                    }
                }
                continue
            }

            // `**Speaker Name:** utterance` — a speaker turn (colon inside the bold markers).
            if let turn = matchGeminiTurn(line) {
                if sections.isEmpty {
                    // Turns before the first timestamp header (unusual) anchor at 0.
                    sections.append(GeminiSection(start: 0))
                }
                sections[sections.count - 1].turns.append(turn)
                inTurn = true
                continue
            }

            // Continuation of an open turn; anything else (date line, italic disclaimer) is dropped.
            if inTurn, !sections.isEmpty, !sections[sections.count - 1].turns.isEmpty {
                let lastSection = sections.count - 1
                let lastTurn = sections[lastSection].turns.count - 1
                sections[lastSection].turns[lastTurn].text += " " + cleanGeminiText(line)
            }
        }

        let turnCount = sections.reduce(0) { $0 + $1.turns.count }
        guard turnCount > 0, sawTimestampHeader || sawTranscriptTitle else { return nil }

        return buildGeminiSegments(sections: sections, finalBound: finalBound)
    }

    /// Interpolate per-turn start times inside each section (length-weighted, see
    /// `parseGeminiNotes`) and assemble the final segments. End times backfill from the following
    /// turn's start; the very last turn ends at the closing boundary when one exists.
    private static func buildGeminiSegments(
        sections: [GeminiSection],
        finalBound: Double?
    ) -> [TranscriptionSegment] {
        // Drop turns that ended up textless (a header-only turn line with no continuation).
        var sections = sections
        for index in sections.indices {
            sections[index].turns.removeAll { $0.text.isEmpty }
        }

        var timed: [(speaker: String, text: String, start: Double)] = []
        for (index, section) in sections.enumerated() {
            guard !section.turns.isEmpty else { continue }
            let nextBound: Double? = (index + 1 < sections.count) ? sections[index + 1].start : finalBound
            let span = (nextBound ?? section.start) - section.start
            if span > 0 {
                let weights = section.turns.map { Double(max(1, $0.text.count)) }
                let total = weights.reduce(0, +)
                var consumed = 0.0
                for (turn, weight) in zip(section.turns, weights) {
                    let start = section.start + span * (consumed / total)
                    timed.append((turn.speaker, turn.text, start))
                    consumed += weight
                }
            } else {
                // No forward boundary (last section without a closing line): carry the section start.
                for turn in section.turns {
                    timed.append((turn.speaker, turn.text, section.start))
                }
            }
        }

        var segments: [TranscriptionSegment] = []
        segments.reserveCapacity(timed.count)
        for (index, entry) in timed.enumerated() {
            var end = entry.start
            if index + 1 < timed.count {
                let nextStart = timed[index + 1].start
                if nextStart > end { end = nextStart }
            } else if let finalBound, finalBound > end {
                end = finalBound
            }
            segments.append(
                TranscriptionSegment(
                    text: entry.text,
                    start: entry.start,
                    end: end,
                    speakerLabel: entry.speaker
                )
            )
        }
        return segments
    }

    /// Extract the inner text of a `<hashes> **inner**` markdown heading, or nil.
    private static func boldHeadingText(_ line: String, hashes: String) -> String? {
        let pattern = "^\(hashes)\\s+\\*\\*(.+?)\\*\\*\\s*$"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        guard let match = regex.firstMatch(in: line, range: range),
              match.numberOfRanges >= 2,
              let inner = Range(match.range(at: 1), in: line) else { return nil }
        return String(line[inner]).trimmingCharacters(in: .whitespaces)
    }

    /// Find a `HH:MM:SS` timestamp embedded in prose (the closing "transcript ended after" line).
    private static func embeddedTimestamp(in text: String) -> Double? {
        guard let range = text.range(of: #"\d{1,2}:\d{2}:\d{2}"#, options: .regularExpression) else {
            return nil
        }
        return parseTimestamp(String(text[range]))
    }

    /// Match a `**Speaker Name:** utterance` turn. The name is validated with
    /// `looksLikeSpeakerName` so a bolded prose sentence is not mistaken for a turn.
    private static func matchGeminiTurn(_ line: String) -> (speaker: String, text: String)? {
        guard let (name, rest) = captureTwo(in: line, pattern: #"^\*\*([^*]+?):\*\*\s*(.*)$"#) else {
            return nil
        }
        let speaker = unescapeMarkdown(name).trimmingCharacters(in: .whitespaces)
        guard looksLikeSpeakerName(speaker) else { return nil }
        return (speaker, cleanGeminiText(rest))
    }

    /// Normalize a Gemini utterance: drop residual bold markers and backslash escapes. Scoped to
    /// the Gemini rung so the generic rungs never munge legitimate asterisks/backslashes.
    private static func cleanGeminiText(_ text: String) -> String {
        unescapeMarkdown(text.replacingOccurrences(of: "**", with: ""))
            .trimmingCharacters(in: .whitespaces)
    }

    /// Remove the export's backslash-escaping of markdown punctuation (`\-` → `-`, `\.` → `.`, …).
    private static func unescapeMarkdown(_ text: String) -> String {
        text.replacingOccurrences(
            of: #"\\([\\`*_{}\[\]()#+\-.!>~|])"#,
            with: "$1",
            options: .regularExpression
        )
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
