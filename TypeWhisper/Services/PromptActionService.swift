import Foundation
import SwiftData
import Combine
import os.log
import TypeWhisperPluginSDK

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "TypeWhisper", category: "PromptActionService")

@MainActor
class PromptActionService: ObservableObject {
    private var modelContainer: ModelContainer?
    private var modelContext: ModelContext?

    /// Dictation-surface rows only (plan AD6). Every existing consumer reads dictation actions
    /// through this array, so keeping it scoped means the system-wide quick-action palette can never
    /// surface a meeting template — the scoping is a query invariant, not a per-call-site convention.
    @Published private(set) var promptActions: [PromptAction] = []
    /// Meeting-surface rows (plan AD6), driving the Meetings generate/library menus.
    @Published private(set) var meetingActions: [PromptAction] = []

    /// UserDefaults guard so the one-time `MeetingTemplate → PromptAction` migration runs at most
    /// once (plan AD6). Idempotent even without it — the guard just avoids a redundant fetch pass.
    private static let migrationCompletedKey = "meetings.templateMigration.completedV1"

    /// Defaults store backing the migration guard (injectable so tests get an isolated suite).
    private let defaults: UserDefaults

    init(
        appSupportDirectory: URL = AppConstants.appSupportDirectory,
        defaults: UserDefaults = .standard
    ) {
        self.defaults = defaults
        setupModelContainer(appSupportDirectory: appSupportDirectory)
    }

    private func setupModelContainer(appSupportDirectory: URL) {
        let schema = Schema([PromptAction.self])
        let storeDir = appSupportDirectory
        try? FileManager.default.createDirectory(at: storeDir, withIntermediateDirectories: true)

        let storeURL = storeDir.appendingPathComponent("prompt-actions.store")
        let config = ModelConfiguration(url: storeURL)

        do {
            modelContainer = try ModelContainer(for: schema, configurations: [config])
        } catch {
            // Incompatible schema - delete old store and retry
            for suffix in ["", "-wal", "-shm"] {
                let url = storeDir.appendingPathComponent("prompt-actions.store\(suffix)")
                try? FileManager.default.removeItem(at: url)
            }
            do {
                modelContainer = try ModelContainer(for: schema, configurations: [config])
            } catch {
                fatalError("Failed to create prompt-actions ModelContainer after reset: \(error)")
            }
        }
        modelContext = ModelContext(modelContainer!)
        modelContext?.autosaveEnabled = true

        loadActions()
    }

    func loadActions() {
        guard let context = modelContext else { return }

        do {
            let descriptor = FetchDescriptor<PromptAction>(
                sortBy: [SortDescriptor(\.sortOrder, order: .forward)]
            )
            let all = try context.fetch(descriptor)
            // Split by surface at the single load choke point (plan AD6): `promptActions` stays
            // dictation-only for every existing consumer; meeting rows live in `meetingActions`.
            promptActions = all.filter { $0.surface == .dictation }
            meetingActions = all.filter { $0.surface == .meeting }
        } catch {
            logger.error("Failed to fetch prompt actions: \(error.localizedDescription)")
        }
    }

    var availablePresets: [PromptAction] {
        let existingNames = Set(promptActions.map(\.name))
        return PromptAction.presets.filter { !existingNames.contains($0.name) }
    }

    func seedPresetsIfNeeded() {
        guard let context = modelContext else { return }

        let newPresets = availablePresets
        guard !newPresets.isEmpty else { return }

        let isInitialSeed = promptActions.isEmpty
        let nextSortOrder = (promptActions.map(\.sortOrder).max() ?? -1) + 1

        for (offset, preset) in newPresets.enumerated() {
            if isInitialSeed {
                context.insert(preset)
            } else {
                let newAction = PromptAction(
                    name: preset.name,
                    prompt: preset.prompt,
                    icon: preset.icon,
                    isPreset: true,
                    sortOrder: nextSortOrder + offset,
                    providerType: preset.providerType,
                    cloudModel: preset.cloudModel,
                    temperatureModeRaw: preset.temperatureModeRaw,
                    temperatureValue: preset.temperatureValue,
                    targetActionPluginId: preset.targetActionPluginId
                )
                context.insert(newAction)
            }
        }

        do {
            try context.save()
            loadActions()
        } catch {
            logger.error("Failed to seed presets: \(error.localizedDescription)")
        }
    }

    func addPreset(_ preset: PromptAction) {
        guard let context = modelContext else { return }

        let maxOrder = promptActions.map(\.sortOrder).max() ?? -1
        let newAction = PromptAction(
            name: preset.name,
            prompt: preset.prompt,
            icon: preset.icon,
            isPreset: true,
            sortOrder: maxOrder + 1,
            providerType: preset.providerType,
            cloudModel: preset.cloudModel,
            temperatureModeRaw: preset.temperatureModeRaw,
            temperatureValue: preset.temperatureValue,
            targetActionPluginId: preset.targetActionPluginId
        )

        context.insert(newAction)

        do {
            try context.save()
            loadActions()
        } catch {
            logger.error("Failed to add preset: \(error.localizedDescription)")
        }
    }

    @discardableResult
    func addAction(
        name: String,
        prompt: String,
        icon: String = "sparkles",
        isEnabled: Bool = true,
        providerType: String? = nil,
        cloudModel: String? = nil,
        temperatureModeRaw: String = PluginLLMTemperatureMode.inheritProviderSetting.rawValue,
        temperatureValue: Double? = nil,
        targetActionPluginId: String? = nil
    ) -> PromptAction? {
        guard let context = modelContext else { return nil }

        let maxOrder = promptActions.map(\.sortOrder).max() ?? -1
        let action = PromptAction(
            name: name,
            prompt: prompt,
            icon: icon,
            isEnabled: isEnabled,
            sortOrder: maxOrder + 1,
            providerType: providerType,
            cloudModel: cloudModel,
            temperatureModeRaw: temperatureModeRaw,
            temperatureValue: temperatureValue,
            targetActionPluginId: targetActionPluginId
        )

        context.insert(action)

        do {
            try context.save()
            loadActions()
        } catch {
            logger.error("Failed to save prompt action: \(error.localizedDescription)")
        }

        return action
    }

    @discardableResult
    func updateAction(
        _ action: PromptAction,
        name: String,
        prompt: String,
        icon: String,
        isEnabled: Bool = true,
        providerType: String? = nil,
        cloudModel: String? = nil,
        temperatureModeRaw: String = PluginLLMTemperatureMode.inheritProviderSetting.rawValue,
        temperatureValue: Double? = nil,
        targetActionPluginId: String? = nil
    ) -> PromptAction? {
        guard let context = modelContext else { return nil }

        action.name = name
        action.prompt = prompt
        action.icon = icon
        action.isEnabled = isEnabled
        action.providerType = providerType
        action.cloudModel = cloudModel
        action.temperatureModeRaw = temperatureModeRaw
        action.temperatureValue = temperatureValue
        action.targetActionPluginId = targetActionPluginId
        action.updatedAt = Date()

        do {
            try context.save()
            loadActions()
        } catch {
            logger.error("Failed to update prompt action: \(error.localizedDescription)")
        }

        return action
    }

    func deleteAction(_ action: PromptAction) {
        guard let context = modelContext else { return }

        context.delete(action)

        do {
            try context.save()
            loadActions()
        } catch {
            logger.error("Failed to delete prompt action: \(error.localizedDescription)")
        }
    }

    func toggleAction(_ action: PromptAction) {
        guard let context = modelContext else { return }

        action.isEnabled.toggle()

        do {
            try context.save()
            loadActions()
        } catch {
            logger.error("Failed to toggle prompt action: \(error.localizedDescription)")
        }
    }

    func moveAction(fromIndex: Int, toIndex: Int) {
        guard let context = modelContext,
              fromIndex != toIndex,
              fromIndex >= 0, fromIndex < promptActions.count,
              toIndex >= 0, toIndex < promptActions.count else { return }

        var actions = promptActions
        let moved = actions.remove(at: fromIndex)
        actions.insert(moved, at: toIndex)

        for (index, action) in actions.enumerated() {
            action.sortOrder = index
        }

        do {
            try context.save()
            loadActions()
        } catch {
            logger.error("Failed to move prompt action: \(error.localizedDescription)")
        }
    }

    /// The enabled **dictation** actions that drive the quick-action palette (plan AD6). Explicitly
    /// scoped to `.dictation` so the invariant holds even if `promptActions` is ever repopulated
    /// from a broader fetch; a meeting template must never appear here.
    func getEnabledActions() -> [PromptAction] {
        promptActions.filter { $0.isEnabled && $0.surface == .dictation }
    }

    func action(byId id: String) -> PromptAction? {
        promptActions.first { $0.id.uuidString == id }
    }

    // MARK: - Meeting templates (plan AD6)

    /// Meeting-surface templates of a given output kind, in sort order (drives the generate menus).
    func meetingTemplates(ofKind kind: MeetingOutputKind) -> [PromptAction] {
        meetingActions.filter { $0.meetingKind == kind }
    }

    @discardableResult
    func addMeetingTemplate(_ spec: PromptTemplateSpec) -> PromptAction? {
        guard let context = modelContext else { return nil }
        let maxOrder = meetingActions.map(\.sortOrder).max() ?? -1
        let action = PromptAction(
            name: spec.trimmedName,
            prompt: spec.trimmedPrompt,
            icon: "doc.text.magnifyingglass",
            sortOrder: maxOrder + 1,
            providerType: spec.providerType,
            cloudModel: spec.cloudModel,
            temperatureModeRaw: spec.temperatureMode.rawValue,
            temperatureValue: spec.normalizedTemperatureValue,
            surfaceRaw: PromptSurface.meeting.rawValue,
            meetingKindRaw: spec.meetingKind.rawValue
        )
        context.insert(action)
        saveAndReload("add meeting template")
        return action
    }

    /// Apply an edited spec to an existing meeting-surface row.
    func updateMeetingTemplate(_ action: PromptAction, with spec: PromptTemplateSpec) {
        guard modelContext != nil else { return }
        action.name = spec.trimmedName
        action.prompt = spec.trimmedPrompt
        action.providerType = spec.providerType
        action.cloudModel = spec.cloudModel
        action.temperatureModeRaw = spec.temperatureMode.rawValue
        action.temperatureValue = spec.normalizedTemperatureValue
        action.meetingKind = spec.meetingKind
        action.surface = .meeting
        action.updatedAt = Date()
        saveAndReload("update meeting template")
    }

    func deleteMeetingTemplate(_ action: PromptAction) {
        guard let context = modelContext else { return }
        context.delete(action)
        saveAndReload("delete meeting template")
    }

    // MARK: - Meeting template migration (plan AD6)

    /// One-time, idempotent migration of legacy `MeetingTemplate` rows into unified `.meeting`
    /// `PromptAction` rows (plan AD6). Preserves UUIDs so `MeetingOutput.templateID` and rule
    /// `defaultOutputTemplateID` references stay valid. Also backfills the curated presets so a fresh
    /// install (no legacy rows) still gets the six starters. Safe to call every launch: the legacy
    /// pass is UserDefaults-guarded, and preset backfill is scoped by name.
    func migrateMeetingTemplatesIfNeeded(legacyTemplates: [MeetingTemplateSnapshot]) {
        guard let context = modelContext else { return }

        // Existing meeting rows keyed by id/name (drives collision + preset-backfill checks).
        let existingIDs = Set(meetingActions.map(\.id))
        let existingNames = Set(meetingActions.map(\.name))
        var insertedIDs = existingIDs
        var insertedNames = existingNames
        var didInsert = false

        let migrationDone = defaults.bool(forKey: Self.migrationCompletedKey)
        if !migrationDone {
            for snapshot in legacyTemplates {
                // On an id collision with an existing PromptAction, skip-and-log — never overwrite
                // (plan AD6). Name collisions are allowed (a user may have renamed a preset).
                guard !insertedIDs.contains(snapshot.id) else {
                    logger.error("Skipping meeting-template migration for id \(snapshot.id) — already present")
                    continue
                }
                context.insert(MeetingTemplateMigration.makePromptAction(from: snapshot))
                insertedIDs.insert(snapshot.id)
                insertedNames.insert(snapshot.name)
                didInsert = true
            }
        }

        // Backfill any preset missing by name (fresh install, or a preset deleted pre-upgrade). A
        // backfilled preset keeps its own curated sort order; ties are broken arbitrarily by the
        // fetch and are cosmetic.
        for preset in MeetingTemplateMigration.presetSnapshots() where !insertedNames.contains(preset.name) {
            context.insert(MeetingTemplateMigration.makePromptAction(from: preset))
            insertedNames.insert(preset.name)
            didInsert = true
        }

        if didInsert {
            do {
                try context.save()
                loadActions()
            } catch {
                logger.error("Failed to persist meeting-template migration: \(error.localizedDescription)")
            }
        }

        defaults.set(true, forKey: Self.migrationCompletedKey)
    }

    private func saveAndReload(_ label: String) {
        guard let context = modelContext else { return }
        do {
            try context.save()
            loadActions()
        } catch {
            logger.error("Failed to \(label): \(error.localizedDescription)")
        }
    }
}
