import Foundation
import XCTest
import TypeWhisperPluginSDK
@testable import TypeWhisper

/// Plan AD6 shared-editor model: `PromptTemplateSpec` is the pure value type the one editor binds
/// to. These tests pin its validation and field mapping without SwiftUI or a `ModelContainer`.
final class PromptTemplateEditorModelTests: XCTestCase {
    func testValidityRequiresNameAndPrompt() {
        XCTAssertFalse(PromptTemplateSpec(surface: .meeting, name: "", prompt: "p").isValid)
        XCTAssertFalse(PromptTemplateSpec(surface: .meeting, name: "n", prompt: "  ").isValid)
        XCTAssertFalse(PromptTemplateSpec(surface: .meeting, name: "   ", prompt: "p").isValid)
        XCTAssertTrue(PromptTemplateSpec(surface: .meeting, name: "n", prompt: "p").isValid)
    }

    func testNormalizedTemperatureValueOnlyInCustomMode() {
        var spec = PromptTemplateSpec(surface: .meeting, name: "n", prompt: "p")
        spec.temperatureMode = .inheritProviderSetting
        spec.temperatureValue = 0.5
        XCTAssertNil(spec.normalizedTemperatureValue, "inherit mode carries no explicit value")

        spec.temperatureMode = .providerDefault
        XCTAssertNil(spec.normalizedTemperatureValue)

        spec.temperatureMode = .custom
        XCTAssertEqual(spec.normalizedTemperatureValue, 0.5)
    }

    func testTrimmedAccessors() {
        let spec = PromptTemplateSpec(surface: .meeting, name: "  Name  ", prompt: "\n Prompt \n")
        XCTAssertEqual(spec.trimmedName, "Name")
        XCTAssertEqual(spec.trimmedPrompt, "Prompt")
    }

    func testInitFromMeetingActionRoundTrips() {
        let action = PromptAction(
            name: "Sync",
            prompt: "Summarize.",
            providerType: "openai",
            cloudModel: "gpt-4o",
            temperatureModeRaw: PluginLLMTemperatureMode.custom.rawValue,
            temperatureValue: 0.3,
            surfaceRaw: PromptSurface.meeting.rawValue,
            meetingKindRaw: MeetingOutputKind.extended.rawValue
        )
        let spec = PromptTemplateSpec(meetingAction: action)
        XCTAssertEqual(spec.surface, .meeting)
        XCTAssertEqual(spec.name, "Sync")
        XCTAssertEqual(spec.prompt, "Summarize.")
        XCTAssertEqual(spec.meetingKind, .extended)
        XCTAssertEqual(spec.providerType, "openai")
        XCTAssertEqual(spec.cloudModel, "gpt-4o")
        XCTAssertEqual(spec.temperatureMode, .custom)
        XCTAssertEqual(spec.temperatureValue, 0.3)
    }

    func testMeetingKindDefaultsToSummaryWhenActionHasNoKind() {
        let action = PromptAction(
            name: "X",
            prompt: "p",
            surfaceRaw: PromptSurface.meeting.rawValue,
            meetingKindRaw: nil
        )
        XCTAssertEqual(PromptTemplateSpec(meetingAction: action).meetingKind, .summary)
    }
}
