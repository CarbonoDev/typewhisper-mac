import Foundation
import TypeWhisperPluginSDK

/// Which surface a `PromptAction` row belongs to (plan AD6). Dictation rows drive the system-wide
/// quick-action palette; meeting rows drive the Meetings output/generate menus. The two never mix:
/// the dictation palette is scoped to `.dictation` as a query invariant (see
/// `PromptActionService`), so a meeting template can never appear as a dictation action.
enum PromptSurface: String, CaseIterable, Sendable, Codable {
    case dictation
    case meeting
}

/// A surface-agnostic, SwiftData-free description of a prompt template used by the shared
/// `PromptTemplateEditor` (plan AD6 "one editor"). Meeting-only fields (`meetingKind`) are ignored
/// when `surface == .dictation`; the editor renders the kind picker only for `.meeting`.
///
/// The spec is a pure value type so the editor's validation and field mapping can be unit-tested
/// without SwiftUI or a `ModelContainer` (`PromptTemplateEditorModelTests`).
struct PromptTemplateSpec: Equatable, Sendable {
    var surface: PromptSurface
    var name: String
    var prompt: String
    /// Only meaningful for `.meeting` rows; the meeting output kind this template generates.
    var meetingKind: MeetingOutputKind
    var providerType: String?
    var cloudModel: String?
    var temperatureMode: PluginLLMTemperatureMode
    var temperatureValue: Double?

    init(
        surface: PromptSurface,
        name: String = "",
        prompt: String = "",
        meetingKind: MeetingOutputKind = .summary,
        providerType: String? = nil,
        cloudModel: String? = nil,
        temperatureMode: PluginLLMTemperatureMode = .inheritProviderSetting,
        temperatureValue: Double? = nil
    ) {
        self.surface = surface
        self.name = name
        self.prompt = prompt
        self.meetingKind = meetingKind
        self.providerType = providerType
        self.cloudModel = cloudModel
        self.temperatureMode = temperatureMode
        self.temperatureValue = temperatureValue
    }

    /// Build a spec from an existing meeting-surface `PromptAction` (for the edit sheet).
    init(meetingAction action: PromptAction) {
        self.surface = .meeting
        self.name = action.name
        self.prompt = action.prompt
        self.meetingKind = action.meetingKind ?? .summary
        self.providerType = action.providerType
        self.cloudModel = action.cloudModel
        self.temperatureMode = action.temperatureMode
        self.temperatureValue = action.temperatureValue
    }

    /// Whether the spec is complete enough to persist: name and prompt non-empty after trimming.
    var isValid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The temperature value that should be persisted for the current mode: a concrete value only
    /// in `.custom` mode, otherwise `nil` (inherit / provider default carry no explicit value).
    var normalizedTemperatureValue: Double? {
        temperatureMode == .custom ? temperatureValue : nil
    }

    /// The trimmed name/prompt as they should be written to storage.
    var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    var trimmedPrompt: String { prompt.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// The provider/model overrides as they should be persisted: trimmed, with empty → nil. Trimming
    /// here (not just in the editor binding) keeps a pasted `"openai "` from being stored verbatim and
    /// then failing provider resolution at generate time while provenance records the clean name.
    var trimmedProviderType: String? {
        let value = (providerType ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    var trimmedCloudModel: String? {
        let value = (cloudModel ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
