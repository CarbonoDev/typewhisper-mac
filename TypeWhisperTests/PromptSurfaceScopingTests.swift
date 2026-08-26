import Foundation
import XCTest
import TypeWhisperPluginSDK
@testable import TypeWhisper

/// Plan AD6 dictation-isolation invariant: the system-wide quick-action palette
/// (`getEnabledActions`) must never surface a `.meeting`-surface row, and the two published arrays
/// stay disjoint by surface. These are the load-bearing scoping guarantees.
@MainActor
final class PromptSurfaceScopingTests: XCTestCase {
    private func makeDefaults() -> UserDefaults {
        let suite = "PromptSurfaceScopingTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        return defaults
    }

    func testEnabledActionsExcludeMeetingRows() throws {
        let dir = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(dir) }

        let service = PromptActionService(appSupportDirectory: dir, defaults: makeDefaults())
        // A dictation action (default surface) and a meeting template share the store.
        service.addAction(name: "Rewrite", prompt: "Rewrite this.")
        service.addMeetingTemplate(
            PromptTemplateSpec(surface: .meeting, name: "Sync Summary", prompt: "Summarize.", meetingKind: .summary)
        )

        // Palette (enabled dictation actions) contains only the dictation row.
        let enabled = service.getEnabledActions()
        XCTAssertEqual(enabled.count, 1)
        XCTAssertEqual(enabled.first?.name, "Rewrite")
        XCTAssertTrue(enabled.allSatisfy { $0.surface == .dictation })

        // Published arrays are disjoint by surface.
        XCTAssertTrue(service.promptActions.allSatisfy { $0.surface == .dictation })
        XCTAssertTrue(service.meetingActions.allSatisfy { $0.surface == .meeting })
        XCTAssertFalse(service.promptActions.contains { $0.name == "Sync Summary" })
        XCTAssertFalse(service.meetingActions.contains { $0.name == "Rewrite" })
    }

    func testMeetingTemplatesFilterByKind() throws {
        let dir = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(dir) }

        let service = PromptActionService(appSupportDirectory: dir, defaults: makeDefaults())
        service.addMeetingTemplate(PromptTemplateSpec(surface: .meeting, name: "S", prompt: "p", meetingKind: .summary))
        service.addMeetingTemplate(PromptTemplateSpec(surface: .meeting, name: "E", prompt: "p", meetingKind: .extended))
        service.addMeetingTemplate(PromptTemplateSpec(surface: .meeting, name: "B", prompt: "p", meetingKind: .brief))

        XCTAssertEqual(service.meetingTemplates(ofKind: .summary).map(\.name), ["S"])
        XCTAssertEqual(service.meetingTemplates(ofKind: .extended).map(\.name), ["E"])
        XCTAssertEqual(service.meetingTemplates(ofKind: .brief).map(\.name), ["B"])
    }

    func testMeetingTemplateEditsPersistAcrossReload() throws {
        let dir = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(dir) }
        let defaults = makeDefaults()

        let service = PromptActionService(appSupportDirectory: dir, defaults: defaults)
        let created = try XCTUnwrap(service.addMeetingTemplate(
            PromptTemplateSpec(surface: .meeting, name: "Draft", prompt: "old", meetingKind: .summary)
        ))
        let id = created.id
        service.updateMeetingTemplate(
            created,
            with: PromptTemplateSpec(
                surface: .meeting,
                name: "Draft",
                prompt: "new",
                meetingKind: .extended,
                providerType: "openai",
                cloudModel: "gpt-4o",
                temperatureMode: .custom,
                temperatureValue: 0.15
            )
        )

        // Reopen: the edit persisted, and the row is still meeting-scoped with the same id.
        let reopened = PromptActionService(appSupportDirectory: dir, defaults: defaults)
        let row = try XCTUnwrap(reopened.meetingActions.first { $0.id == id })
        XCTAssertEqual(row.prompt, "new")
        XCTAssertEqual(row.meetingKind, .extended)
        XCTAssertEqual(row.providerType, "openai")
        XCTAssertEqual(row.cloudModel, "gpt-4o")
        XCTAssertEqual(row.temperatureValue, 0.15)
        XCTAssertTrue(reopened.promptActions.isEmpty, "no dictation rows should exist")
    }
}
