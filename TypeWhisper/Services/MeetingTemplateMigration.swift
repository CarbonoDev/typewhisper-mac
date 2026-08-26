import Foundation
import TypeWhisperPluginSDK

/// A SwiftData-free snapshot of a legacy `MeetingTemplate` row (plan AD6). `MeetingService` reads
/// the frozen `MeetingTemplate` rows out of `meetings.store` and hands them to `PromptActionService`
/// as these value types, so the migration logic stays testable without a live `ModelContainer`.
struct MeetingTemplateSnapshot: Sendable, Equatable {
    let id: UUID
    let name: String
    let kindRaw: String
    let prompt: String
    let providerType: String?
    let cloudModel: String?
    let temperatureModeRaw: String?
    let temperatureValue: Double?
    let isPreset: Bool
    let sortOrder: Int
}

/// Pure conversion between legacy `MeetingTemplate` rows and unified `PromptAction` meeting rows
/// (plan AD6). Holds no persistence references so `MeetingTemplateMigrationTests` can exercise the
/// mapping — including UUID preservation — in isolation. `PromptActionService` drives the actual
/// store writes; this only builds the target model objects.
enum MeetingTemplateMigration {
    /// Build a `.meeting`-surface `PromptAction` equivalent to a legacy template, **preserving the
    /// same `id`** (plan AD6): `MeetingOutput.templateID` and Track C's `defaultOutputTemplateID`
    /// reference templates by UUID, so a re-keyed migration would orphan both.
    static func makePromptAction(from snapshot: MeetingTemplateSnapshot) -> PromptAction {
        PromptAction(
            id: snapshot.id,
            name: snapshot.name,
            prompt: snapshot.prompt,
            icon: "doc.text.magnifyingglass",
            isPreset: snapshot.isPreset,
            isEnabled: true,
            sortOrder: snapshot.sortOrder,
            providerType: snapshot.providerType,
            cloudModel: snapshot.cloudModel,
            temperatureModeRaw: snapshot.temperatureModeRaw
                ?? PluginLLMTemperatureMode.inheritProviderSetting.rawValue,
            temperatureValue: snapshot.temperatureValue,
            surfaceRaw: PromptSurface.meeting.rawValue,
            meetingKindRaw: (MeetingOutputKind(rawValue: snapshot.kindRaw) ?? .summary).rawValue
        )
    }

    /// The curated starter meeting templates as snapshots, derived from `MeetingTemplatePresets`
    /// so the preset copy/prompts live in exactly one place. Used to seed a fresh install (which has
    /// no legacy rows) and to backfill any preset a user deleted before upgrading.
    static func presetSnapshots() -> [MeetingTemplateSnapshot] {
        MeetingTemplatePresets.all.map { preset in
            MeetingTemplateSnapshot(
                id: preset.id,
                name: preset.name,
                kindRaw: preset.kindRaw,
                prompt: preset.prompt,
                providerType: preset.providerType,
                cloudModel: preset.cloudModel,
                temperatureModeRaw: preset.temperatureModeRaw,
                temperatureValue: preset.temperatureValue,
                isPreset: true,
                sortOrder: preset.sortOrder
            )
        }
    }
}
