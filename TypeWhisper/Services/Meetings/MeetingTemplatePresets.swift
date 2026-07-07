import Foundation
import TypeWhisperPluginSDK

/// The curated starter set of meeting output templates (plan M4 §3), seeded idempotently by
/// `MeetingService.seedTemplatesIfNeeded()` — mirroring `PromptAction.presets`. Names and prompts
/// are localized (EN+DE). Provider/model are left unset so presets inherit the global LLM
/// selection; temperature is pinned low for factual, non-inventive outputs.
enum MeetingTemplatePresets {
    static var all: [MeetingTemplate] {
        [
            MeetingTemplate(
                name: String(localized: "meetings.template.preset.generalSync.name"),
                kind: .summary,
                prompt: String(localized: "meetings.template.preset.generalSync.prompt"),
                temperatureModeRaw: PluginLLMTemperatureMode.custom.rawValue,
                temperatureValue: 0.2,
                isPreset: true,
                sortOrder: 0
            ),
            MeetingTemplate(
                name: String(localized: "meetings.template.preset.oneOnOne.name"),
                kind: .summary,
                prompt: String(localized: "meetings.template.preset.oneOnOne.prompt"),
                temperatureModeRaw: PluginLLMTemperatureMode.custom.rawValue,
                temperatureValue: 0.2,
                isPreset: true,
                sortOrder: 1
            ),
            MeetingTemplate(
                name: String(localized: "meetings.template.preset.decisionLog.name"),
                kind: .extended,
                prompt: String(localized: "meetings.template.preset.decisionLog.prompt"),
                temperatureModeRaw: PluginLLMTemperatureMode.custom.rawValue,
                temperatureValue: 0.2,
                isPreset: true,
                sortOrder: 2
            ),
            MeetingTemplate(
                name: String(localized: "meetings.template.preset.salesDiscovery.name"),
                kind: .extended,
                prompt: String(localized: "meetings.template.preset.salesDiscovery.prompt"),
                temperatureModeRaw: PluginLLMTemperatureMode.custom.rawValue,
                temperatureValue: 0.3,
                isPreset: true,
                sortOrder: 3
            ),
            MeetingTemplate(
                name: String(localized: "meetings.template.preset.interviewDebrief.name"),
                kind: .extended,
                prompt: String(localized: "meetings.template.preset.interviewDebrief.prompt"),
                temperatureModeRaw: PluginLLMTemperatureMode.custom.rawValue,
                temperatureValue: 0.2,
                isPreset: true,
                sortOrder: 4
            ),
            MeetingTemplate(
                name: String(localized: "meetings.template.preset.actionItems.name"),
                kind: .summary,
                prompt: String(localized: "meetings.template.preset.actionItems.prompt"),
                temperatureModeRaw: PluginLLMTemperatureMode.custom.rawValue,
                temperatureValue: 0.1,
                isPreset: true,
                sortOrder: 5
            )
        ]
    }
}
