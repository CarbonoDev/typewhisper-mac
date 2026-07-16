import Foundation

/// The routable model-selection purposes for the Meetings feature (plan M4, D9). Each purpose carries
/// an independent per-purpose provider/model setting, resolved with precedence
/// `template > purpose > app default` **per call** (never snapshotted — mirrors the language-detection
/// pattern, plan D5). `languageDetection` deliberately reuses the pre-existing
/// `meetings.language.detection*` UserDefaults keys (back-compat, plan D9): its settings row moved into
/// the unified Models section, so detection is configured in exactly one place.
enum MeetingModelPurpose: String, CaseIterable, Sendable {
    /// Summaries / analysis outputs generated from a `.meeting` `PromptAction` template
    /// (`MeetingLLMService.generateOutput`). Template-overridable.
    case summariesAnalysis
    /// Pre-meeting briefs (`MeetingBriefService`). Template-overridable (the `.brief` template).
    case briefs
    /// In-meeting Q&A answers (`MeetingLLMService.answerQuestion`). No template rung.
    case qa
    /// Per-meeting spoken-language detection (`MeetingLanguageService`). No template rung; reuses the
    /// legacy detection keys.
    case languageDetection
    /// The related-documents relevance judge (`MeetingRelatedDocsService`). No template rung.
    case relatedDocsJudge

    /// UserDefaults key for this purpose's provider override (empty/unset ⇒ "Use app default").
    var providerDefaultsKey: String {
        switch self {
        case .summariesAnalysis: return UserDefaultsKeys.meetingsModelSummariesProviderId
        case .briefs: return UserDefaultsKeys.meetingsModelBriefsProviderId
        case .qa: return UserDefaultsKeys.meetingsModelQAProviderId
        case .languageDetection: return UserDefaultsKeys.meetingsLanguageDetectionProviderId
        case .relatedDocsJudge: return UserDefaultsKeys.meetingsModelRelatedDocsProviderId
        }
    }

    /// UserDefaults key for this purpose's model override (empty/unset ⇒ the provider default).
    var modelDefaultsKey: String {
        switch self {
        case .summariesAnalysis: return UserDefaultsKeys.meetingsModelSummariesModel
        case .briefs: return UserDefaultsKeys.meetingsModelBriefsModel
        case .qa: return UserDefaultsKeys.meetingsModelQAModel
        case .languageDetection: return UserDefaultsKeys.meetingsLanguageDetectionModel
        case .relatedDocsJudge: return UserDefaultsKeys.meetingsModelRelatedDocsModel
        }
    }

    /// Whether a `.meeting`/`.brief` `PromptAction` template can override this purpose for its own runs
    /// (plan D9: the precedence display carries an explicit template-override note only where a template
    /// actually beats the purpose setting). Q&A, detection, and the judge are template-less.
    var isTemplateOverridable: Bool {
        switch self {
        case .summariesAnalysis, .briefs: return true
        case .qa, .languageDetection, .relatedDocsJudge: return false
        }
    }
}

/// Resolves which LLM provider/model runs for a given `MeetingModelPurpose` under the precedence ladder
/// `template > purpose > app default`, resolved per call (never snapshotted — plan D9). Two flavors,
/// so provenance can never disagree with what actually ran:
///   • `overrideProvider`/`overrideModel` — the value to pass as `providerOverride:`/`cloudModelOverride:`
///     to the `PromptProcessing.process` seam: `template ?? purpose`, or `nil` to inherit the app
///     default (the "Use app default" passthrough — the processor resolves nil to its own selection).
///   • `effectiveProvider`/`effectiveModel` — the value that will ACTUALLY run, for provenance
///     (`providerUsed`/`modelUsed`) and the settings effective-value display:
///     `template ?? purpose ?? appDefault`.
/// Each dimension (provider, model) is resolved independently — matching the pre-M4 provenance
/// resolvers this generalizes.
@MainActor
final class MeetingModelRouter {
    private let processor: any PromptProcessing
    private let defaults: UserDefaults

    init(processor: any PromptProcessing, defaults: UserDefaults = .standard) {
        self.processor = processor
        self.defaults = defaults
    }

    // MARK: - Stored purpose rung

    /// The stored per-purpose provider override, or `nil` when unset ("Use app default").
    func purposeProvider(for purpose: MeetingModelPurpose) -> String? {
        normalized(defaults.string(forKey: purpose.providerDefaultsKey))
    }

    /// The stored per-purpose model override, or `nil` when unset (the provider default).
    func purposeModel(for purpose: MeetingModelPurpose) -> String? {
        normalized(defaults.string(forKey: purpose.modelDefaultsKey))
    }

    // MARK: - Call-time override (template > purpose; nil = inherit app default)

    /// The provider to pass to `process(providerOverride:)`: `template ?? purpose`, `nil` to inherit the
    /// app default. `templateProvider` is the resolved template's `providerType` (nil for template-less
    /// purposes).
    func overrideProvider(for purpose: MeetingModelPurpose, templateProvider: String? = nil) -> String? {
        normalized(templateProvider) ?? purposeProvider(for: purpose)
    }

    /// The model to pass to `process(cloudModelOverride:)`: `template ?? purpose`, `nil` to inherit the
    /// app default.
    func overrideModel(for purpose: MeetingModelPurpose, templateModel: String? = nil) -> String? {
        normalized(templateModel) ?? purposeModel(for: purpose)
    }

    // MARK: - Effective value (template > purpose > app default) — provenance + settings display

    /// The provider that will actually run: `template ?? purpose ?? appDefault`. `nil` only when even
    /// the app default is empty. This is what `providerUsed` records so provenance never lies.
    func effectiveProvider(for purpose: MeetingModelPurpose, templateProvider: String? = nil) -> String? {
        overrideProvider(for: purpose, templateProvider: templateProvider)
            ?? normalized(processor.selectedProviderId)
    }

    /// The model that will actually run: `template ?? purpose ?? appDefault`. `nil` when even the app
    /// default is empty (e.g. a provider with no model dimension).
    func effectiveModel(for purpose: MeetingModelPurpose, templateModel: String? = nil) -> String? {
        overrideModel(for: purpose, templateModel: templateModel)
            ?? normalized(processor.selectedCloudModel)
    }

    // MARK: - App default (for the settings display of the "Use app default" rung)

    /// The current app-default provider id (the prompt-provider selection), or `nil` when empty.
    var appDefaultProvider: String? { normalized(processor.selectedProviderId) }

    /// The current app-default model id, or `nil` when empty.
    var appDefaultModel: String? { normalized(processor.selectedCloudModel) }

    private func normalized(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}
