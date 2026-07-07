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

    // MARK: - Additive-store safety (plan AD6: pre-v1.1 promptActions store opens without reset)

    /// A `promptActions.store` written before the additive `surfaceRaw`/`meetingKindRaw` columns
    /// existed must open on a new service instance **without a destructive reset**: the defaulted
    /// `surfaceRaw = "dictation"` applies, existing rows read back as `.dictation`, and they still
    /// drive the quick-action palette. `addAction` exercises the same v1 insert path (it never sets a
    /// surface), so a reopened row proves the additive columns are default-applied, not reset.
    func testExistingDictationRowsSurviveWithDictationSurfaceAcrossReopen() throws {
        let dir = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(dir) }

        let first = PromptActionService(appSupportDirectory: dir, defaults: makeDefaults())
        let created = try XCTUnwrap(first.addAction(name: "Rewrite", prompt: "Rewrite this."))
        let createdID = created.id

        // Reopen the same store with a fresh service instance (fresh defaults ⇒ migration would run).
        let reopened = PromptActionService(appSupportDirectory: dir, defaults: makeDefaults())
        reopened.migrateMeetingTemplatesIfNeeded(legacyTemplates: [])

        // The dictation row survived (no reset), reads back as `.dictation`, and is in the palette.
        let dictation = try XCTUnwrap(reopened.promptActions.first { $0.id == createdID })
        XCTAssertEqual(dictation.surface, .dictation)
        XCTAssertEqual(dictation.name, "Rewrite")
        XCTAssertTrue(reopened.getEnabledActions().contains { $0.id == createdID })
        // A meeting row does not leak into the dictation array.
        XCTAssertFalse(reopened.promptActions.contains { $0.surface == .meeting })
    }

    // MARK: - Store isolation (plan AD6: migration writes promptActions.store, never meetings.store)

    /// Running the migration (which only writes `promptActions.store`) must leave `meetings.store`
    /// byte-for-byte queryable afterwards: meetings, their `MeetingOutput` rows (including
    /// `templateID` UUID references), and the frozen `MeetingTemplate` snapshots all requery intact on
    /// a fresh `MeetingService` instance. Nothing else pins that `legacyMeetingTemplateSnapshots()` is
    /// read-only.
    func testMigrationLeavesMeetingsStoreIntact() throws {
        let dir = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(dir) }

        // Seed meetings.store with two meetings; one carries an output referencing a template UUID.
        let templateID = UUID()
        let meetingService = MeetingService(appSupportDirectory: dir)
        let m1 = meetingService.createMeeting(title: "Retro", source: .adHoc, state: .completed)
        _ = meetingService.createMeeting(title: "Standup", source: .adHoc, state: .completed)
        _ = meetingService.addOutput(to: m1, kind: .summary, content: "Body.", templateID: templateID)

        let meetingsBefore = meetingService.meetings.count
        let snapshotsBefore = meetingService.legacyMeetingTemplateSnapshots()

        // Migration runs against the separate promptActions.store in the same directory.
        let prompts = PromptActionService(appSupportDirectory: dir, defaults: makeDefaults())
        prompts.migrateMeetingTemplatesIfNeeded(legacyTemplates: snapshotsBefore)

        // Requery meetings.store on a brand-new instance: everything survives untouched.
        let reopened = MeetingService(appSupportDirectory: dir)
        XCTAssertEqual(reopened.meetings.count, meetingsBefore)
        let retro = try XCTUnwrap(reopened.meetings.first { $0.title == "Retro" })
        XCTAssertEqual(retro.outputs.count, 1)
        XCTAssertEqual(retro.outputs.first?.templateID, templateID)
        XCTAssertEqual(reopened.legacyMeetingTemplateSnapshots(), snapshotsBefore)
    }

    // MARK: - Behavioral equivalence (plan AD6: migrated template runs identically to its v1 fields)

    /// A migrated `.meeting` `PromptAction` must drive `MeetingLLMService` **identically** to a
    /// PromptAction built directly from the same v1 field set — same prompt, provider/model overrides,
    /// and temperature directive reach the stubbed processor. This pins that
    /// `MeetingTemplateMigration.makePromptAction(from:)` carries the fields the LLM path reads.
    func testMigratedTemplateRunsIdenticallyToItsV1Fields() async throws {
        let dir = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(dir) }

        let service = MeetingService(appSupportDirectory: dir)
        let stub = EquivalenceStubProcessor()
        let llm = MeetingLLMService(
            meetingService: service,
            vaultService: makeDisconnectedVault(),
            processor: stub
        )

        // v1 field set for a user-edited template.
        let snapshot = MeetingTemplateSnapshot(
            id: UUID(),
            name: "Decision Log",
            kindRaw: MeetingOutputKind.extended.rawValue,
            prompt: "Log the decisions.",
            providerType: "anthropic",
            cloudModel: "claude-3",
            temperatureModeRaw: PluginLLMTemperatureMode.custom.rawValue,
            temperatureValue: 0.25,
            isPreset: false,
            sortOrder: 0
        )

        // The migrated row vs. a directly-built v1-equivalent PromptAction.
        let migrated = MeetingTemplateMigration.makePromptAction(from: snapshot)
        let v1Equivalent = PromptAction(
            name: snapshot.name,
            prompt: snapshot.prompt,
            providerType: snapshot.providerType,
            cloudModel: snapshot.cloudModel,
            temperatureModeRaw: snapshot.temperatureModeRaw!,
            temperatureValue: snapshot.temperatureValue,
            surfaceRaw: PromptSurface.meeting.rawValue,
            meetingKindRaw: snapshot.kindRaw
        )

        let meetingA = makeCompletedMeeting(on: service, text: "Short transcript.")
        _ = try await llm.generateOutput(for: meetingA, using: migrated)
        let migratedCall = try XCTUnwrap(stub.calls.last)

        let meetingB = makeCompletedMeeting(on: service, text: "Short transcript.")
        _ = try await llm.generateOutput(for: meetingB, using: v1Equivalent)
        let v1Call = try XCTUnwrap(stub.calls.last)

        XCTAssertEqual(migratedCall.prompt, v1Call.prompt)
        XCTAssertEqual(migratedCall.providerOverride, v1Call.providerOverride)
        XCTAssertEqual(migratedCall.cloudModelOverride, v1Call.cloudModelOverride)
        XCTAssertEqual(migratedCall.temperatureDirective, v1Call.temperatureDirective)
        // And concretely: the migration carried the v1 overrides through.
        XCTAssertEqual(migratedCall.providerOverride, "anthropic")
        XCTAssertEqual(migratedCall.cloudModelOverride, "claude-3")
        XCTAssertEqual(migratedCall.temperatureDirective, .custom(0.25))
    }

    // MARK: - Equivalence-test helpers

    private func makeDisconnectedVault() -> ObsidianVaultService {
        let suite = "MeetingTemplateMigrationTests-vault-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        return ObsidianVaultService(defaults: defaults)
    }

    private func makeCompletedMeeting(on service: MeetingService, text: String) -> Meeting {
        let meeting = service.createMeeting(title: "M", source: .adHoc, state: .completed)
        service.appendStableSegments([TranscriptionSegment(text: text, start: 0, end: 2)], to: meeting)
        meeting.notesIncludedInOutputs = false
        service.update(meeting)
        return meeting
    }

    /// Minimal `PromptProcessing` seam capturing the args each call receives (plan AD6 equivalence).
    @MainActor
    private final class EquivalenceStubProcessor: PromptProcessing {
        struct Call {
            let prompt: String
            let providerOverride: String?
            let cloudModelOverride: String?
            let temperatureDirective: PluginLLMTemperatureDirective
        }

        var selectedProviderId: String = "global-provider"
        var selectedCloudModel: String = "global-model"
        private(set) var calls: [Call] = []

        func process(
            prompt: String,
            text: String,
            providerOverride: String?,
            cloudModelOverride: String?,
            temperatureDirective: PluginLLMTemperatureDirective,
            skipMemoryInjection: Bool
        ) async throws -> String {
            calls.append(Call(
                prompt: prompt,
                providerOverride: providerOverride,
                cloudModelOverride: cloudModelOverride,
                temperatureDirective: temperatureDirective
            ))
            return "resp-\(calls.count)"
        }
    }
}
