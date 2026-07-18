import Foundation

/// [Sprint 3] Normalizer for imported meeting titles that arrive as export filenames — most
/// notably Google Meet's Gemini notes ("Llamada semanal - 2026_07_07 11_00 CST - Notas de Gemini
/// (1)"): strips the notes-app suffix and copy counter, extracts the embedded date, and returns
/// the human title. Pure and strict-match-or-passthrough: a title with no recognized export
/// pattern comes back untouched, so hand-written titles are never mangled.
enum ImportedMeetingTitle {
    struct Parsed: Equatable {
        var cleanTitle: String
        /// The timestamp embedded in the filename, resolved in its stated time zone when the
        /// abbreviation is known (else the current zone).
        var date: Date?
        /// True when a recognized export pattern was stripped.
        var isImported: Bool
    }

    /// Known trailing notes-app markers (ES + EN Google Meet Gemini exports), matched
    /// case-insensitively after a dash separator.
    private static let notesSuffixes = [
        "notas de gemini",
        "notes by gemini",
        "gemini notes",
    ]

    static func parse(_ raw: String) -> Parsed {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return Parsed(cleanTitle: trimmed, date: nil, isImported: false)
        }
        var working = trimmed
        var matched = false

        // 1. Trailing copy counter "… (1)" — only treated as a counter when an export marker
        //    precedes it, so a real title that happens to end in "(2)" survives.
        if let range = working.range(of: #"\s*\(\d+\)\s*$"#, options: .regularExpression),
           containsExportMarker(String(working[..<range.lowerBound])) {
            working = String(working[..<range.lowerBound])
            matched = true
        }

        // 2. Trailing notes-app suffix "… - Notas de Gemini".
        for suffix in notesSuffixes {
            let pattern = #"\s*[-–—]\s*"# + NSRegularExpression.escapedPattern(for: suffix) + #"\s*$"#
            if let range = working.range(of: pattern, options: [.regularExpression, .caseInsensitive]) {
                working = String(working[..<range.lowerBound])
                matched = true
                break
            }
        }

        // 3. Trailing date segment "… - 2026_07_07 11_00 CST" (time-zone token optional).
        var date: Date?
        if let range = working.range(
            of: #"\s*[-–—]\s*\d{4}_\d{2}_\d{2}[ _]\d{2}_\d{2}(\s+[A-Za-z]{2,5})?\s*$"#,
            options: .regularExpression
        ) {
            date = parseDate(from: String(working[range]))
            working = String(working[..<range.lowerBound])
            matched = true
        }

        let clean = working.trimmingCharacters(in: .whitespacesAndNewlines)
        // A title that was nothing but the export pattern would strip down to a bare date stamp (or
        // nothing) — pass it through instead of presenting a timestamp as a "title".
        let isBareStamp = clean.range(
            of: #"^\d{4}_\d{2}_\d{2}([ _]\d{2}_\d{2})?(\s+[A-Za-z]{2,5})?$"#,
            options: .regularExpression
        ) != nil
        guard matched, !clean.isEmpty, !isBareStamp else {
            return Parsed(cleanTitle: trimmed, date: nil, isImported: false)
        }
        return Parsed(cleanTitle: clean, date: date, isImported: true)
    }

    /// The row-display convenience: the clean title when the raw one is a recognized export name.
    static func displayTitle(for raw: String) -> String {
        parse(raw).cleanTitle
    }

    private static func containsExportMarker(_ text: String) -> Bool {
        let lowered = text.lowercased()
        if lowered.contains("gemini") { return true }
        return text.range(of: #"\d{4}_\d{2}_\d{2}"#, options: .regularExpression) != nil
    }

    private static func parseDate(from segment: String) -> Date? {
        guard let stampRange = segment.range(
            of: #"\d{4}_\d{2}_\d{2}[ _]\d{2}_\d{2}"#, options: .regularExpression
        ) else { return nil }
        var stamp = String(segment[stampRange])
        // Normalize the date/time joiner (space or underscore) to a space for the fixed formatter.
        let joinerIndex = stamp.index(stamp.startIndex, offsetBy: 10)
        stamp.replaceSubrange(joinerIndex...joinerIndex, with: " ")

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy_MM_dd HH_mm"
        formatter.timeZone = timeZone(in: segment) ?? .current
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
        guard let abbreviationRange = segment.range(of: #"[A-Za-z]{2,5}\s*$"#, options: .regularExpression)
        else { return nil }
        let abbreviation = String(segment[abbreviationRange]).trimmingCharacters(in: .whitespaces).uppercased()
        if let hours = fixedOffsetHours[abbreviation] {
            return TimeZone(secondsFromGMT: hours * 3600)
        }
        return TimeZone(abbreviation: abbreviation)
    }
}
