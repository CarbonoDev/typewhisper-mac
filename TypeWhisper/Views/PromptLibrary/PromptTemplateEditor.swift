import SwiftUI
import TypeWhisperPluginSDK

/// The single, surface-agnostic editor for a prompt template (plan AD6 "one editor"). Bound to a
/// `PromptTemplateSpec`, it renders the common fields (name, prompt, provider/model/temperature
/// overrides) plus the meeting-only output-kind picker when `surface == .meeting`. Both the meeting
/// template management UI and the unified library re-host this component instead of duplicating the
/// field layout.
struct PromptTemplateEditor: View {
    @Binding var spec: PromptTemplateSpec

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField(String(localized: "promptLibrary.editor.name"), text: $spec.name)
                .textFieldStyle(.roundedBorder)

            if spec.surface == .meeting {
                // Summary/extended drive the per-meeting generate menus; `.brief` is the single
                // editable pre-meeting brief template (plan M6, amendment DA3). MeetingBriefService
                // resolves the first `.brief` template as the brief's system prompt (falling back to
                // the built-in default when none exists), so a brief template is a live, user-editable
                // prompt rather than a dead row.
                Picker(String(localized: "promptLibrary.editor.kind"), selection: $spec.meetingKind) {
                    Text(String(localized: "meetings.output.kind.summary")).tag(MeetingOutputKind.summary)
                    Text(String(localized: "meetings.output.kind.extended")).tag(MeetingOutputKind.extended)
                    Text(String(localized: "meetings.output.kind.brief")).tag(MeetingOutputKind.brief)
                }
                .pickerStyle(.segmented)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(String(localized: "promptLibrary.editor.prompt"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextEditor(text: $spec.prompt)
                    .font(.body)
                    .frame(minHeight: 140)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
            }

            if spec.surface == .meeting {
                Text(String(localized: "promptLibrary.editor.placeholderLegend"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            DisclosureGroup(String(localized: "promptLibrary.editor.advanced")) {
                VStack(alignment: .leading, spacing: 10) {
                    TextField(
                        String(localized: "promptLibrary.editor.providerOverride"),
                        text: providerBinding
                    )
                    .textFieldStyle(.roundedBorder)

                    TextField(
                        String(localized: "promptLibrary.editor.modelOverride"),
                        text: modelBinding
                    )
                    .textFieldStyle(.roundedBorder)

                    Picker(String(localized: "promptLibrary.editor.temperature"), selection: $spec.temperatureMode) {
                        Text(String(localized: "promptLibrary.editor.temperature.inherit"))
                            .tag(PluginLLMTemperatureMode.inheritProviderSetting)
                        Text(String(localized: "promptLibrary.editor.temperature.providerDefault"))
                            .tag(PluginLLMTemperatureMode.providerDefault)
                        Text(String(localized: "promptLibrary.editor.temperature.custom"))
                            .tag(PluginLLMTemperatureMode.custom)
                    }
                    .pickerStyle(.menu)

                    if spec.temperatureMode == .custom {
                        HStack {
                            Slider(value: temperatureValueBinding, in: 0...1, step: 0.05)
                            Text(String(format: "%.2f", spec.temperatureValue ?? 0))
                                .font(.caption.monospacedDigit())
                                .frame(width: 42, alignment: .trailing)
                        }
                    }
                }
                .padding(.top, 6)
            }
        }
    }

    private var providerBinding: Binding<String> {
        Binding(
            get: { spec.providerType ?? "" },
            set: {
                let trimmed = $0.trimmingCharacters(in: .whitespacesAndNewlines)
                spec.providerType = trimmed.isEmpty ? nil : trimmed
            }
        )
    }

    private var modelBinding: Binding<String> {
        Binding(
            get: { spec.cloudModel ?? "" },
            set: {
                let trimmed = $0.trimmingCharacters(in: .whitespacesAndNewlines)
                spec.cloudModel = trimmed.isEmpty ? nil : trimmed
            }
        )
    }

    private var temperatureValueBinding: Binding<Double> {
        Binding(
            get: { spec.temperatureValue ?? 0.2 },
            set: { spec.temperatureValue = $0 }
        )
    }
}
