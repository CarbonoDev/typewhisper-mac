import Foundation
import XCTest
import TypeWhisperPluginSDK
@testable import TypeWhisper

/// Plan AD6 migration: legacy `MeetingTemplate` rows become unified `.meeting` `PromptAction` rows
/// with **identical UUIDs** and overrides intact; presets are backfilled; the pass runs once.
@MainActor
final class MeetingTemplateMigrationTests: XCTestCase {
    private func makeDefaults() -> UserDefaults {
        let suite = "MeetingTemplateMigrationTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        return defaults
    }

    private func presetSnapshots() -> [MeetingTemplateSnapshot] {
        MeetingTemplateMigration.presetSnapshots()
    }

    // MARK: - Pure mapping

    func testMakePromptActionPreservesIdAndFields() {
        let id = UUID()
        let snapshot = MeetingTemplateSnapshot(
            id: id,
            name: "Decision Log",
            kindRaw: MeetingOutputKind.extended.rawValue,
            prompt: "Log decisions.",
            providerType: "anthropic",
            cloudModel: "claude-3",
            temperatureModeRaw: PluginLLMTemperatureMode.custom.rawValue,
            temperatureValue: 0.25,
            isPreset: false,
            sortOrder: 3
        )
        let action = MeetingTemplateMigration.makePromptAction(from: snapshot)

        XCTAssertEqual(action.id, id, "UUID must be preserved")
        XCTAssertEqual(action.surface, .meeting)
        XCTAssertEqual(action.meetingKind, .extended)
        XCTAssertEqual(action.name, "Decision Log")
        XCTAssertEqual(action.prompt, "Log decisions.")
        XCTAssertEqual(action.providerType, "anthropic")
        XCTAssertEqual(action.cloudModel, "claude-3")
        XCTAssertEqual(action.temperatureModeRaw, PluginLLMTemperatureMode.custom.rawValue)
        XCTAssertEqual(action.temperatureValue, 0.25)
        XCTAssertEqual(action.sortOrder, 3)
    }

    // MARK: - Full migration through the service

    func testMigrationConvertsPresetsAndUserRowWithSameUUIDs() throws {
        let dir = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(dir) }

        // Simulate a v1 store: the six presets plus one user-edited row.
        let userID = UUID()
        var legacy = presetSnapshots()
        legacy.append(MeetingTemplateSnapshot(
            id: userID,
            name: "My Custom",
            kindRaw: MeetingOutputKind.summary.rawValue,
            prompt: "Custom prompt.",
            providerType: "openai",
            cloudModel: "gpt-4o",
            temperatureModeRaw: PluginLLMTemperatureMode.custom.rawValue,
            temperatureValue: 0.7,
            isPreset: false,
            sortOrder: 6
        ))

        let service = PromptActionService(appSupportDirectory: dir, defaults: makeDefaults())
        service.migrateMeetingTemplatesIfNeeded(legacyTemplates: legacy)

        // All seven meeting rows exist; UUIDs preserved.
        XCTAssertEqual(service.meetingActions.count, 7)
        let byID = Dictionary(uniqueKeysWithValues: service.meetingActions.map { ($0.id, $0) })
        for snapshot in legacy {
            XCTAssertNotNil(byID[snapshot.id], "template \(snapshot.name) lost its UUID")
        }
        // The user row's overrides survived.
        let user = try XCTUnwrap(byID[userID])
        XCTAssertEqual(user.prompt, "Custom prompt.")
        XCTAssertEqual(user.providerType, "openai")
        XCTAssertEqual(user.temperatureValue, 0.7)
        XCTAssertEqual(user.meetingKind, .summary)
        // No meeting row leaked into the dictation palette.
        XCTAssertTrue(service.getEnabledActions().isEmpty)
    }

    func testFreshInstallSeedsPresetsWithNoLegacyRows() throws {
        let dir = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(dir) }

        let service = PromptActionService(appSupportDirectory: dir, defaults: makeDefaults())
        service.migrateMeetingTemplatesIfNeeded(legacyTemplates: [])

        XCTAssertEqual(service.meetingActions.count, presetSnapshots().count)
        XCTAssertTrue(service.meetingActions.allSatisfy { $0.surface == .meeting })
    }

    func testSecondRunIsNoOp() throws {
        let dir = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(dir) }
        let defaults = makeDefaults()

        let service = PromptActionService(appSupportDirectory: dir, defaults: defaults)
        let legacy = presetSnapshots()
        service.migrateMeetingTemplatesIfNeeded(legacyTemplates: legacy)
        let firstCount = service.meetingActions.count

        // Re-running (same defaults guard) inserts nothing new.
        service.migrateMeetingTemplatesIfNeeded(legacyTemplates: legacy)
        XCTAssertEqual(service.meetingActions.count, firstCount)

        // A brand-new service instance on the same store + defaults also stays stable.
        let reopened = PromptActionService(appSupportDirectory: dir, defaults: defaults)
        reopened.migrateMeetingTemplatesIfNeeded(legacyTemplates: legacy)
        XCTAssertEqual(reopened.meetingActions.count, firstCount)
    }

    func testDeletedPresetIsBackfilledButUserRowsUntouched() throws {
        let dir = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(dir) }

        // v1 store missing one preset (user deleted it) — migration should restore it by name.
        var legacy = presetSnapshots()
        let dropped = legacy.removeLast()

        let service = PromptActionService(appSupportDirectory: dir, defaults: makeDefaults())
        service.migrateMeetingTemplatesIfNeeded(legacyTemplates: legacy)

        XCTAssertEqual(service.meetingActions.count, presetSnapshots().count)
        XCTAssertTrue(service.meetingActions.contains { $0.name == dropped.name })
    }

    func testIdCollisionIsSkippedNotOverwritten() throws {
        let dir = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(dir) }

        let service = PromptActionService(appSupportDirectory: dir, defaults: makeDefaults())
        // Pre-existing meeting row.
        let existing = try XCTUnwrap(service.addMeetingTemplate(
            PromptTemplateSpec(surface: .meeting, name: "Existing", prompt: "keep me", meetingKind: .summary)
        ))
        // A legacy snapshot colliding on id but with different content must NOT overwrite it.
        let colliding = MeetingTemplateSnapshot(
            id: existing.id,
            name: "Impostor",
            kindRaw: MeetingOutputKind.extended.rawValue,
            prompt: "overwrite me",
            providerType: nil,
            cloudModel: nil,
            temperatureModeRaw: nil,
            temperatureValue: nil,
            isPreset: false,
            sortOrder: 0
        )
        service.migrateMeetingTemplatesIfNeeded(legacyTemplates: [colliding])

        let row = try XCTUnwrap(service.meetingActions.first { $0.id == existing.id })
        XCTAssertEqual(row.prompt, "keep me")
        XCTAssertEqual(row.name, "Existing")
    }
}
