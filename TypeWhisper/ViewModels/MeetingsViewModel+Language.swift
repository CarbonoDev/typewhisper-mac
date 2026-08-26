import Foundation

/// Per-meeting language surface (plan M1, D1/D9). Thin MainActor pass-throughs to the
/// single-writer `MeetingService` setters plus the display projections the Language chip renders.
/// Lives in its own extension file per the view model's extension-file discipline (no stored state
/// is added here). Detection (Detect / Re-detect) is deliberately absent until M2.
@MainActor
extension MeetingsViewModel {
    /// The language codes offered in the per-meeting language picker (the app's spoken-language set),
    /// paired with their localized display names. Featured ranking is applied by the picker UI via
    /// `featuredAppLanguageRank`.
    var meetingLanguageOptions: [LocalizedAppLanguageOption] {
        localizedAppLanguageOptions(for: defaultSpokenLanguageCodes)
    }

    /// Explicitly set a meeting's language (`.manual`, plan D1). A nil/blank code clears it.
    func setMeetingLanguage(_ code: String?, for meeting: Meeting) {
        meetingService.setLanguage(code, for: meeting)
    }

    /// Clear a meeting's language, returning it to the unset (`.auto` / detection-eligible) state.
    func clearMeetingLanguage(for meeting: Meeting) {
        meetingService.clearLanguage(for: meeting)
    }

    /// The localized display name of a meeting's language for the chip, or `nil` when unset.
    func languageDisplayName(for meeting: Meeting) -> String? {
        guard let code = meeting.languageCode?.trimmingCharacters(in: .whitespacesAndNewlines),
              !code.isEmpty else { return nil }
        return localizedAppLanguageName(for: code)
    }

    /// A localized provenance tag ("Set manually" / "From rule" / "Auto-detected") for the chip
    /// popover, or `nil` when the language is unset.
    func languageProvenanceLabel(for meeting: Meeting) -> String? {
        guard meeting.languageCode != nil else { return nil }
        switch meeting.languageProvenance {
        case .manual:
            return String(localized: "meetingdoc.language.provenance.manual")
        case .rule:
            return String(localized: "meetingdoc.language.provenance.rule")
        case .detected:
            return String(localized: "meetingdoc.language.provenance.detected")
        case .none:
            return nil
        }
    }

    // MARK: - Detection (M2, plan D5)

    /// Kick off a user-initiated Detect / Re-detect from the Language chip. Clears any standing
    /// `.rule`/`.detected` value and enqueues a `.userInitiated` detection job (plan D1). A no-op when
    /// the language is a `.manual` pick — the UI disables the control with a "clear first" hint
    /// (Decision 3 / owner-veto 3), and this is the programmatic backstop.
    func detectMeetingLanguage(for meeting: Meeting) {
        languageService.requestUserDetection(for: meeting)
    }

    /// Whether the chip's Detect / Re-detect action is enabled: only when the language is unset or was
    /// set by a rule/detection (never over a manual pick — clear it first).
    func canDetectLanguage(for meeting: Meeting) -> Bool {
        meeting.languageProvenance != .manual
    }

    /// Whether a language-detection job is in flight for this meeting — drives the chip's spinner and
    /// disabled state. Meeting-scoped (via the job queue) so it does not follow navigation.
    func isDetectingLanguage(for meeting: Meeting) -> Bool {
        jobQueue.hasActiveJob(kind: .languageDetection, meetingID: meeting.id)
    }

    /// The "Detect" (unset) vs "Re-detect" (already has a value) button title for the chip popover.
    func detectActionTitle(for meeting: Meeting) -> String {
        meeting.languageCode == nil
            ? String(localized: "meetingdoc.language.detect")
            : String(localized: "meetingdoc.language.redetect")
    }
}
