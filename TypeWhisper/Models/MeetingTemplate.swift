import Foundation
import SwiftData
import TypeWhisperPluginSDK

/// A reusable, LLM-driven meeting output template (summary or extended analysis). Independent
/// of `Meeting` (not a child relationship). Reuses `PromptAction`'s provider/model/temperature
/// override shape; presets are seeded idempotently (see plan D11, seeding lands in M4).
@Model
final class MeetingTemplate {
    @Attribute(.unique) var id: UUID
    var name: String
    var kindRaw: String
    var prompt: String
    var providerType: String?
    var cloudModel: String?
    var temperatureModeRaw: String?
    var temperatureValue: Double?
    var isPreset: Bool
    var sortOrder: Int

    init(
        id: UUID = UUID(),
        name: String,
        kind: MeetingOutputKind,
        prompt: String,
        providerType: String? = nil,
        cloudModel: String? = nil,
        temperatureModeRaw: String? = nil,
        temperatureValue: Double? = nil,
        isPreset: Bool = false,
        sortOrder: Int = 0
    ) {
        self.id = id
        self.name = name
        self.kindRaw = kind.rawValue
        self.prompt = prompt
        self.providerType = providerType
        self.cloudModel = cloudModel
        self.temperatureModeRaw = temperatureModeRaw
        self.temperatureValue = temperatureValue
        self.isPreset = isPreset
        self.sortOrder = sortOrder
    }

    var kind: MeetingOutputKind {
        get { MeetingOutputKind(rawValue: kindRaw) ?? .summary }
        set { kindRaw = newValue.rawValue }
    }

    var temperatureMode: PluginLLMTemperatureMode {
        get { PluginLLMTemperatureMode(rawValue: temperatureModeRaw ?? "") ?? .inheritProviderSetting }
        set { temperatureModeRaw = newValue.rawValue }
    }

    var temperatureDirective: PluginLLMTemperatureDirective {
        PluginLLMTemperatureDirective(mode: temperatureMode, value: temperatureValue)
    }
}
