import Foundation

/// Per-meeting language (plan D1): the single-writer setters behind the provenance ladder.
extension MeetingService {
    // MARK: - Per-meeting language (plan D1 — provenance ladder manual > rule > detected)

    /// The transcription language for a meeting, derived from the one persisted column (plan D3):
    /// `.exact(code)` when a language is set, else `.auto`. Every transcription consumer (live
    /// capture, both final-pass paths, audio import) resolves through this so there is exactly one
    /// notion of "the meeting's language".
    func transcriptionLanguageSelection(for meeting: Meeting) -> LanguageSelection {
        guard let code = meeting.languageCode?.trimmingCharacters(in: .whitespacesAndNewlines),
              !code.isEmpty else { return .auto }
        return .exact(code)
    }

    /// Explicit per-meeting language pick (plan D1). Writes `.manual` **unconditionally** — a
    /// deliberate user choice outranks any rule or detection. A blank code clears the language.
    /// Single-writer on the MainActor with no `await` between check and write.
    func setLanguage(_ code: String?, for meeting: Meeting) {
        let normalized = code?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let normalized, !normalized.isEmpty else {
            clearLanguage(for: meeting)
            return
        }
        guard meeting.languageCode != normalized || meeting.languageProvenance != .manual else { return }
        meeting.languageCode = normalized
        meeting.languageProvenance = .manual
        meeting.updatedAt = Date()
        commitWrite(.inPlace)
    }

    /// Clear a meeting's language (both columns to `nil`) — returns it to the `.auto` /
    /// detection-eligible state (plan D1).
    func clearLanguage(for meeting: Meeting) {
        guard meeting.languageCode != nil || meeting.languageProvenanceRaw != nil else { return }
        meeting.languageCode = nil
        meeting.languageProvenanceRaw = nil
        meeting.updatedAt = Date()
        commitWrite(.inPlace)
    }

    /// Seed the language from a matched capture-context rule at capture start (plan D1/D2). A rule is
    /// standing user configuration, so it writes when provenance is **nil, `.rule`, or `.detected`**
    /// — it outranks an inference but **never** overwrites an explicit per-meeting `.manual` pick.
    /// Single-writer on the MainActor with no `await` between the ladder check and the write.
    func seedRuleLanguage(_ code: String, for meeting: Meeting) {
        // M2 (M1-review fix): the rule language field is free text, and `LanguageSelection(storedValue:)`
        // maps *any* non-empty value to `.exact(value)` — so a rule value like "german" or garbage would
        // otherwise be persisted verbatim as a meeting language code. Normalize/validate it here through
        // the same catalog detection uses: a recognizable value (ISO code or language name, "german" →
        // "de") normalizes to a canonical lowercased code; **unrecognizable garbage is silently skipped**
        // (seeds nothing) rather than becoming a bogus `languageCode`.
        guard let normalized = MeetingLanguageCatalog.normalize(code) else { return }
        // Never over a manual pick.
        if meeting.languageProvenance == .manual { return }
        guard meeting.languageCode != normalized || meeting.languageProvenance != .rule else { return }
        meeting.languageCode = normalized
        meeting.languageProvenance = .rule
        meeting.updatedAt = Date()
        commitWrite(.inPlace)
    }

    /// Persist an auto-detected language (plan D1/D5, M2). Writes `.detected` **only when the meeting
    /// has no language yet** — a manual or rule value always wins. The `languageCode == nil` guard is
    /// re-checked here, on the MainActor, with no `await` between the check and the write, so a manual
    /// pick that lands while a detection job is in flight is never clobbered by the finishing job.
    func setDetectedLanguage(_ code: String, for meeting: Meeting) {
        let normalized = code.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return }
        guard meeting.languageCode == nil else { return }
        meeting.languageCode = normalized
        meeting.languageProvenance = .detected
        meeting.updatedAt = Date()
        commitWrite(.inPlace)
    }
}
