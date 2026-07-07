import XCTest
@testable import TypeWhisper

@MainActor
final class MeetingTemplatePresetsTests: XCTestCase {
    private let nameKeys = [
        "meetings.template.preset.generalSync.name",
        "meetings.template.preset.oneOnOne.name",
        "meetings.template.preset.decisionLog.name",
        "meetings.template.preset.salesDiscovery.name",
        "meetings.template.preset.interviewDebrief.name",
        "meetings.template.preset.actionItems.name"
    ]

    private let promptKeys = [
        "meetings.template.preset.generalSync.prompt",
        "meetings.template.preset.oneOnOne.prompt",
        "meetings.template.preset.decisionLog.prompt",
        "meetings.template.preset.salesDiscovery.prompt",
        "meetings.template.preset.interviewDebrief.prompt",
        "meetings.template.preset.actionItems.prompt"
    ]

    // MARK: - Preset invariants

    func testPresetInvariants() {
        let presets = MeetingTemplatePresets.all
        XCTAssertEqual(presets.count, 6)

        // Unique ids.
        XCTAssertEqual(Set(presets.map(\.id)).count, presets.count)

        // Contiguous, unique sort order 0..<count.
        XCTAssertEqual(presets.map(\.sortOrder).sorted(), Array(0..<presets.count))

        for preset in presets {
            XCTAssertTrue(preset.isPreset)
            XCTAssertFalse(preset.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            XCTAssertFalse(preset.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            XCTAssertTrue([.summary, .extended].contains(preset.kind), "brief is not a template kind")
        }
    }

    // MARK: - Localization (EN + DE)

    func testPresetNamesAndPromptsAreLocalizedInEnglishAndGerman() throws {
        for key in nameKeys + promptKeys {
            let en = try TestSupport.localizedCatalogValue(for: key, language: "en")
            let de = try TestSupport.localizedCatalogValue(for: key, language: "de")
            XCTAssertFalse(en.isEmpty, "missing EN for \(key)")
            XCTAssertFalse(de.isEmpty, "missing DE for \(key)")
        }
    }

    // Seeding/migration of presets now lives in the unified `promptActions.store` and is covered by
    // `MeetingTemplateMigrationTests` (plan AD6). `MeetingTemplatePresets.all` remains the single
    // source of preset copy, exercised by the invariants + localization tests above.
}
