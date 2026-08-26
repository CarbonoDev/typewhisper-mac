import Foundation

/// Builds the LLM output-language directive appended to a meeting's final-output prompts (plan D4).
///
/// The output language of a summary / extended analysis / brief / Q&A answer is enforced purely by
/// a prompt instruction — there is no model-level language switch. The directive is a stable
/// **English** scaffold (models follow English instructions most reliably); only the *target
/// language name* embedded in it varies. It is deliberately **not** localized: it is never shown to
/// the user, and translating the instruction itself would weaken adherence.
///
/// Per Decision 4 the directive is appended to the direct single-call path, the map/reduce **reduce**
/// step, Q&A, and the brief — but never to the extractive **map** step (instructing map to translate
/// would make the reduce input a lossy translation with names/quotes mangled at an intermediate
/// stage). A unit test guards the map-step exclusion.
enum MeetingLanguageDirective {
    /// The directive sentence for `code`, or `nil` when no language is set (`code` nil/blank).
    /// e.g. `"Write your entire response in German (de)."`. The language name is resolved in
    /// English regardless of the app's UI locale.
    static func instruction(for code: String?) -> String? {
        guard let trimmed = code?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        let normalized = trimmed.lowercased()
        let englishName = Locale(identifier: "en").localizedString(forIdentifier: normalized) ?? normalized
        return "Write your entire response in \(englishName) (\(normalized)). "
            + "Do not use any other language, regardless of the language of the transcript, notes, or context."
    }

    /// `prompt` with the directive for `code` appended (separated by a blank line), or `prompt`
    /// unchanged when no language is set.
    static func appending(for code: String?, to prompt: String) -> String {
        appending(instruction(for: code), to: prompt)
    }

    /// `prompt` with `directive` appended (separated by a blank line), or `prompt` unchanged when
    /// `directive` is `nil`.
    static func appending(_ directive: String?, to prompt: String) -> String {
        guard let directive else { return prompt }
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedPrompt.isEmpty ? directive : "\(prompt)\n\n\(directive)"
    }
}
