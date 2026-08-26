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

    // MARK: - Call-time override (one-shot > template > purpose; nil = inherit app default)

    /// The provider to pass to `process(providerOverride:)`: `one-shot ?? template ?? purpose`, `nil` to
    /// inherit the app default. `templateProvider` is the resolved template's `providerType` (nil for
    /// template-less purposes). `oneShotProvider` (plan M5/D10) is a per-run override chosen from a
    /// Generate/Regenerate menu; it wins for that run and is never persisted (existing call sites pass
    /// nil = today's behavior).
    func overrideProvider(
        for purpose: MeetingModelPurpose,
        templateProvider: String? = nil,
        oneShotProvider: String? = nil
    ) -> String? {
        normalized(oneShotProvider) ?? normalized(templateProvider) ?? purposeProvider(for: purpose)
    }

    /// The model to pass to `process(cloudModelOverride:)`: `one-shot ?? template ?? purpose`, `nil` to
    /// inherit the app default.
    ///
    /// `oneShotProvider` pins the model dimension to that provider (M5 review finding): when a one-shot
    /// provider is chosen without a one-shot model (the menus emit `action(provider.id, nil)` for a
    /// provider with an empty model list), a nil one-shot model means "that provider's own default
    /// model", NOT the template/purpose model — which belongs to a *different* provider. So the ladder
    /// stops at the one-shot rung (returns nil) rather than bleeding a foreign model under the one-shot
    /// provider. Execution defuses a foreign model via `resolvedModelId`, but `effectiveModel` (below)
    /// would otherwise record it, contradicting D10 ("provenance always records what actually ran").
    func overrideModel(
        for purpose: MeetingModelPurpose,
        templateModel: String? = nil,
        oneShotModel: String? = nil,
        oneShotProvider: String? = nil
    ) -> String? {
        if let model = normalized(oneShotModel) { return model }
        if normalized(oneShotProvider) != nil { return nil }
        return normalized(templateModel) ?? purposeModel(for: purpose)
    }

    // MARK: - Effective value (one-shot > template > purpose > app default) — provenance + settings display

    /// The provider that will actually run: `one-shot ?? template ?? purpose ?? appDefault`. `nil` only
    /// when even the app default is empty. This is what `providerUsed` records so provenance never lies —
    /// including a one-shot override (plan M5: "provenance always records what actually ran").
    func effectiveProvider(
        for purpose: MeetingModelPurpose,
        templateProvider: String? = nil,
        oneShotProvider: String? = nil
    ) -> String? {
        overrideProvider(for: purpose, templateProvider: templateProvider, oneShotProvider: oneShotProvider)
            ?? normalized(processor.selectedProviderId)
    }

    /// The model that will actually run: `one-shot ?? template ?? purpose ?? appDefault`. `nil` when even
    /// the app default is empty (e.g. a provider with no model dimension).
    func effectiveModel(
        for purpose: MeetingModelPurpose,
        templateModel: String? = nil,
        oneShotModel: String? = nil,
        oneShotProvider: String? = nil
    ) -> String? {
        if let override = overrideModel(
            for: purpose, templateModel: templateModel, oneShotModel: oneShotModel, oneShotProvider: oneShotProvider
        ) {
            return override
        }
        // Only inherit the app-default model when no one-shot provider pinned the model dimension: a
        // one-shot provider chosen without a model runs that provider's own default (which we can't name
        // here), so record no model rather than the app default of a *different* provider (M5 finding).
        if normalized(oneShotProvider) != nil { return nil }
        return normalized(processor.selectedCloudModel)
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
