import Foundation
import os

/// [Sprint 3] Normalizer for imported meeting titles that arrive as export filenames — most
/// notably Google Meet's Gemini notes ("Llamada semanal - 2026_07_07 11_00 CST - Notas de Gemini
/// (1)"): strips the notes-app suffix and copy counter, extracts the embedded date, and returns
/// the human title. Pure and strict-match-or-passthrough: a title with no recognized export
/// pattern comes back untouched, so hand-written titles are never mangled.
enum ImportedMeetingTitle {
    struct Parsed: Equatable, Sendable {
        var cleanTitle: String
        /// The timestamp embedded in the filename, resolved in its stated time zone when the
        /// abbreviation is known (else the current zone).
        var date: Date?
        /// True when a recognized export pattern was stripped.
        var isImported: Bool
    }

    /// Known trailing notes-app markers (ES + EN Google Meet Gemini exports), matched
    /// case-insensitively after a dash separator.
    ///
    /// Internal (not private) — this is the **canonical marker list** ([Google Phase 2 · M1],
    /// D-D3/F3): `GoogleDriveAPI.filesListRequest` derives its `fullText contains '"<phrase>"'`
    /// narrowing terms from these same phrases, `hasNotesSuffix` below is the authoritative
    /// client-side discovery filter, and `parse` wraps them in its dash-separator suffix regex for
    /// title cleaning — one list, three derivations from the same code, impossible to drift
    /// (asserted by `GoogleDriveAPITests`).
    static let notesSuffixes = [
        "notas de gemini",
        "notes by gemini",
        "gemini notes",
    ]

    /// Known trailing **transcript** markers — the docs Meet publishes alongside the notes doc,
    /// and the ones Drive discovery actually wants.
    ///
    /// Phase 2 shipped discovering notes docs only (spec §Non-goals: *"No Meet '… - Transcript' doc
    /// format: v1 discovers Gemini notes names only"*), on the evidence of a single real export whose
    /// notes doc happened to contain the transcript. In practice Meet publishes **two** docs per
    /// call — `… - Notas de Gemini` (a summary: "📝 Las notas", "Resumen", "Decisiones") and
    /// `… - Transcripción` (the timed, speaker-attributed turns) — so discovery was importing the
    /// summary as if it were the transcript. `parseGeminiNotes` correctly declined those summaries
    /// (no timestamp headers, no transcript title heading) and the cascade fell through to the
    /// plain-paragraph rung, which turned summary bullets into untimed "segments".
    ///
    /// Both spellings of the Spanish word are listed because the accent is not guaranteed to survive
    /// every export path; the patterns are end-anchored after a dash, so `transcript` never matches a
    /// name ending in `Transcripción`.
    static let transcriptSuffixes = [
        "transcripción",
        "transcripcion",
        "transcript",
    ]

    /// Every recognized export marker: what `parse` strips and what `containsExportMarker` counts.
    static let exportSuffixes: [String] = notesSuffixes + transcriptSuffixes

    /// [Perf 1C] `parse` runs several times per meeting row per render (display title, sort
    /// date, header), so results are memoized per raw title. The key carries the current time
    /// zone because a stamp without a zone token resolves in it. Lock-guarded rather than
    /// actor-isolated: the enum is called from the main actor and from nonisolated code alike.
    private struct MemoKey: Hashable {
        let raw: String
        let timeZone: String
    }

    private static let memoLimit = 4096
    private static let memo = OSAllocatedUnfairLock(initialState: [MemoKey: Parsed]())

    static func parse(_ raw: String) -> Parsed {
        parse(raw, fallbackTimeZone: .current)
    }

    /// `parse` with the zone a token-less stamp resolves in made explicit (a test seam:
    /// `TimeZone.current` follows the system zone only).
    static func parse(_ raw: String, fallbackTimeZone: TimeZone) -> Parsed {
        let key = MemoKey(raw: raw, timeZone: fallbackTimeZone.identifier)
        if let cached = memo.withLock({ $0[key] }) { return cached }
        let parsed = uncachedParse(raw, fallbackTimeZone: fallbackTimeZone)
        memo.withLock { cache in
            // Titles are a bounded set in practice; the cap only guards pathological input.
            if cache.count >= memoLimit { cache.removeAll(keepingCapacity: true) }
            cache[key] = parsed
        }
        return parsed
    }

    private static func uncachedParse(_ raw: String, fallbackTimeZone: TimeZone) -> Parsed {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return Parsed(cleanTitle: trimmed, date: nil, isImported: false)
        }
        var working = trimmed
        var matched = false

        // 1. Trailing copy counter "… (1)" — only treated as a counter when an export marker
        //    precedes it, so a real title that happens to end in "(2)" survives.
        if let range = copyCounterRange(in: working) {
            working = String(working[..<range.lowerBound])
            matched = true
        }

        // 2. Trailing notes-app suffix "… - Notas de Gemini".
        if let range = notesSuffixRange(in: working) {
            working = String(working[..<range.lowerBound])
            matched = true
        }

        // 3. Trailing date segment "… - 2026_07_07 11_00 CST" (time-zone token optional).
        var date: Date?
        if let range = Patterns.trailingDate.firstRange(in: working) {
            date = parseDate(from: String(working[range]), fallbackTimeZone: fallbackTimeZone)
            working = String(working[..<range.lowerBound])
            matched = true
        }

        let clean = working.trimmingCharacters(in: .whitespacesAndNewlines)
        // A title that was nothing but the export pattern would strip down to a bare date stamp (or
        // nothing) — pass it through instead of presenting a timestamp as a "title".
        let isBareStamp = Patterns.bareStamp.firstRange(in: clean) != nil
        guard matched, !clean.isEmpty, !isBareStamp else {
            return Parsed(cleanTitle: trimmed, date: nil, isImported: false)
        }
        return Parsed(cleanTitle: clean, date: date, isImported: true)
    }

    /// The row-display convenience: the clean title when the raw one is a recognized export name.
    static func displayTitle(for raw: String) -> String {
        parse(raw).cleanTitle
    }

    /// True when the name carries a trailing Gemini-notes marker (optionally followed by a copy
    /// counter): *the* Drive discovery filter ([Google Phase 2 · M1], D-D3 review fix).
    ///
    /// Load-bearing: Drive's `contains` operator **prefix-matches** the `name` field
    /// (`name contains 'World'` does not match "HelloWorld" —
    /// developers.google.com/workspace/drive/api/guides/ref-search-terms), so a *trailing* marker
    /// can never be matched server-side. Discovery therefore lists by mimeType/time window (with
    /// an optional `fullText` narrowing for unbounded scans) and filters names here.
    static func hasNotesSuffix(_ raw: String) -> Bool {
        var working = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = copyCounterRange(in: working) {
            working = String(working[..<range.lowerBound])
        }
        return notesSuffixRange(in: working) != nil
    }

    private static func copyCounterRange(in text: String) -> Range<String.Index>? {
        guard let range = Patterns.copyCounter.firstRange(in: text),
              containsExportMarker(String(text[..<range.lowerBound]))
        else { return nil }
        return range
    }

    /// The authoritative client-side discovery filter for Drive (`GoogleDriveSyncEngine`): **either**
    /// export shape.
    ///
    /// Filename alone cannot tell a transcript from a summary. Meet names the doc
    /// `… - Notas de Gemini` whether Gemini wrote only meeting notes *or* notes plus the full
    /// transcript, and separately publishes `… - Transcripción` in some configurations. Narrowing
    /// discovery to transcript-suffixed names (the first attempt at this fix) therefore matched
    /// nothing at all for accounts whose transcripts live inside the notes doc. So discovery stays
    /// wide and `MeetingImportService.carriesRecoverableTiming` decides from the exported *content*,
    /// which is the only reliable signal.
    static func isDiscoverableExportName(_ raw: String) -> Bool {
        hasNotesSuffix(raw) || hasTranscriptSuffix(raw)
    }

    /// `hasNotesSuffix`'s transcript twin — the `… - Transcripción` / `… - Transcript` docs Meet
    /// publishes alongside (or instead of) the notes doc.
    static func hasTranscriptSuffix(_ raw: String) -> Bool {
        var working = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = copyCounterRange(in: working) {
            working = String(working[..<range.lowerBound])
        }
        return suffixRange(in: working, patterns: Patterns.transcriptSuffixes) != nil
    }

    private static func notesSuffixRange(in text: String) -> Range<String.Index>? {
        suffixRange(in: text, patterns: Patterns.exportSuffixes)
    }

    /// First match in list order — the same precedence the per-suffix loop always had.
    private static func suffixRange(in text: String, patterns: [CompiledPattern]) -> Range<String.Index>? {
        for pattern in patterns {
            if let range = pattern.firstRange(in: text) { return range }
        }
        return nil
    }

    private static func containsExportMarker(_ text: String) -> Bool {
        let lowered = text.lowercased()
        if lowered.contains("gemini") { return true }
        if transcriptSuffixes.contains(where: { lowered.contains($0) }) { return true }
        return Patterns.dateStamp.firstRange(in: text) != nil
    }

    private static func parseDate(from segment: String, fallbackTimeZone: TimeZone) -> Date? {
        guard let stampRange = Patterns.stamp.firstRange(in: segment) else { return nil }
        var stamp = String(segment[stampRange])
        // Normalize the date/time joiner (space or underscore) to a space for the fixed formatter.
        let joinerIndex = stamp.index(stamp.startIndex, offsetBy: 10)
        stamp.replaceSubrange(joinerIndex...joinerIndex, with: " ")

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy_MM_dd HH_mm"
        formatter.timeZone = timeZone(in: segment) ?? fallbackTimeZone
        return formatter.date(from: stamp)
    }

    /// Fixed offsets for the common export abbreviations. `TimeZone(abbreviation: "CST")` resolves
    /// to America/Chicago and applies its DST rules, which shifts a summer-dated "11_00 CST" stamp
    /// (fixed UTC−6, e.g. Mexico) an hour early — the stamp states an offset, so honor it literally.
    private static let fixedOffsetHours: [String: Int] = [
        "UTC": 0, "GMT": 0, "Z": 0,
        "EST": -5, "EDT": -4,
        "CST": -6, "CDT": -5,
        "MST": -7, "MDT": -6,
        "PST": -8, "PDT": -7,
    ]

    private static func timeZone(in segment: String) -> TimeZone? {
        guard let abbreviationRange = Patterns.zoneAbbreviation.firstRange(in: segment) else { return nil }
        let abbreviation = String(segment[abbreviationRange]).trimmingCharacters(in: .whitespaces).uppercased()
        if let hours = fixedOffsetHours[abbreviation] {
            return TimeZone(secondsFromGMT: hours * 3600)
        }
        return TimeZone(abbreviation: abbreviation)
    }

    // MARK: - Precompiled patterns

    /// [Perf 1C] Each pattern is compiled once instead of per call (per suffix, per row, per
    /// render). Same ICU engine and options `String.range(of:options: .regularExpression)` uses,
    /// so matches are identical. `NSRegularExpression` is immutable and documented thread-safe.
    struct CompiledPattern: @unchecked Sendable {
        let pattern: String
        let caseInsensitive: Bool
        private let regex: NSRegularExpression

        init(_ pattern: String, caseInsensitive: Bool = false) {
            self.pattern = pattern
            self.caseInsensitive = caseInsensitive
            // Force-try: every pattern is a literal (or an escaped literal) checked by the tests.
            regex = try! NSRegularExpression(pattern: pattern, options: caseInsensitive ? [.caseInsensitive] : [])
        }

        func firstRange(in text: String) -> Range<String.Index>? {
            guard let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
            else { return nil }
            return Range(match.range, in: text)
        }
    }

    enum Patterns {
        static let trailingDate = CompiledPattern(#"\s*[-–—]\s*\d{4}_\d{2}_\d{2}[ _]\d{2}_\d{2}(\s+[A-Za-z]{2,5})?\s*$"#)
        static let bareStamp = CompiledPattern(#"^\d{4}_\d{2}_\d{2}([ _]\d{2}_\d{2})?(\s+[A-Za-z]{2,5})?$"#)
        static let copyCounter = CompiledPattern(#"\s*\(\d+\)\s*$"#)
        static let dateStamp = CompiledPattern(#"\d{4}_\d{2}_\d{2}"#)
        static let stamp = CompiledPattern(#"\d{4}_\d{2}_\d{2}[ _]\d{2}_\d{2}"#)
        static let zoneAbbreviation = CompiledPattern(#"[A-Za-z]{2,5}\s*$"#)
        static let exportSuffixes = ImportedMeetingTitle.exportSuffixes.map(suffixPattern)
        static let transcriptSuffixes = ImportedMeetingTitle.transcriptSuffixes.map(suffixPattern)
        static var all: [CompiledPattern] {
            [trailingDate, bareStamp, copyCounter, dateStamp, stamp, zoneAbbreviation]
                + exportSuffixes + transcriptSuffixes
        }

        private static func suffixPattern(_ suffix: String) -> CompiledPattern {
            CompiledPattern(
                #"\s*[-–—]\s*"# + NSRegularExpression.escapedPattern(for: suffix) + #"\s*$"#,
                caseInsensitive: true
            )
        }
    }
}
