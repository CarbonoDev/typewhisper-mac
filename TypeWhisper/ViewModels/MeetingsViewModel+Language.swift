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
}
