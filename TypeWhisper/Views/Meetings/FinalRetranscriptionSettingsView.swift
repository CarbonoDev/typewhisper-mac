import SwiftUI

/// [Track C] Global default for a meeting's final (post-stop) re-transcription (addendum AD8).
/// A per-meeting override lives on the meeting detail; a matched rule can also set it.
struct FinalRetranscriptionSettingsView: View {
    @ObservedObject private var viewModel = MeetingsViewModel.shared

    /// The three modes exposed by the picker; `.engine` carries the currently-selected engine id.
    private enum Mode: Hashable {
        case off
        case sameEngine
        case engine
    }

    private var mode: Binding<Mode> {
        Binding(
            get: {
                switch viewModel.globalFinalRetranscriptionPolicy {
                case .off: return .off
                case .sameEngine: return .sameEngine
                case .engine: return .engine
                }
            },
            set: { newMode in
                switch newMode {
                case .off:
                    viewModel.globalFinalRetranscriptionPolicy = .off
                case .sameEngine:
                    viewModel.globalFinalRetranscriptionPolicy = .sameEngine
                case .engine:
                    let firstEngine = viewModel.transcriptionEngineOptions.first?.id ?? ""
                    let existing = currentEngineId ?? firstEngine
                    viewModel.globalFinalRetranscriptionPolicy = .engine(id: existing, model: currentModel)
                }
            }
        )
    }

    private var currentEngineId: String? {
        if case .engine(let id, _) = viewModel.globalFinalRetranscriptionPolicy { return id }
        return nil
    }

    private var currentModel: String? {
        if case .engine(_, let model) = viewModel.globalFinalRetranscriptionPolicy { return model }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "meetings.finalPass.section.title"))
                .font(.headline)
            Text(String(localized: "meetings.finalPass.section.subtitle"))
                .font(.caption)
                .foregroundStyle(.secondary)

            Picker(String(localized: "meetings.finalPass.mode.label"), selection: mode) {
                Text(String(localized: "meetings.finalPass.mode.off")).tag(Mode.off)
                Text(String(localized: "meetings.finalPass.mode.sameEngine")).tag(Mode.sameEngine)
                Text(String(localized: "meetings.finalPass.mode.engine")).tag(Mode.engine)
            }
            .pickerStyle(.radioGroup)

            if mode.wrappedValue == .engine {
                enginePicker
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var enginePicker: some View {
        let engineBinding = Binding<String>(
            get: { currentEngineId ?? viewModel.transcriptionEngineOptions.first?.id ?? "" },
            set: { viewModel.globalFinalRetranscriptionPolicy = .engine(id: $0, model: currentModel) }
        )
        let modelBinding = Binding<String>(
            get: { currentModel ?? "" },
            set: { newValue in
                let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                viewModel.globalFinalRetranscriptionPolicy = .engine(
                    id: currentEngineId ?? viewModel.transcriptionEngineOptions.first?.id ?? "",
                    model: trimmed.isEmpty ? nil : trimmed
                )
            }
        )
        return VStack(alignment: .leading, spacing: 6) {
            Picker(String(localized: "meetings.finalPass.engine"), selection: engineBinding) {
                ForEach(viewModel.transcriptionEngineOptions, id: \.id) { option in
                    Text(option.name).tag(option.id)
                }
            }
            TextField(String(localized: "meetings.finalPass.model"), text: modelBinding)
                .textFieldStyle(.roundedBorder)
        }
        .padding(.leading, 16)
    }
}
