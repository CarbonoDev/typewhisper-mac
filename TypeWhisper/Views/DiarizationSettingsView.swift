import SwiftUI

struct DiarizationSettingsView: View {
    @AppStorage("diarization.enabled") private var isEnabled = false
    @AppStorage("diarization.pythonPath") private var pythonPath = ""
    @AppStorage("diarization.numSpeakers") private var numSpeakers = 0

    @State private var hfToken = ""
    @State private var providerAvailable: Bool?
    @State private var isCheckingStatus = false

    private static let keychainService = "diarization.huggingFaceToken"

    var body: some View {
        Form {
            Section {
                Toggle(String(localized: "Enable speaker diarization"), isOn: $isEnabled)

                Text(String(localized: "Detects and labels different speakers in a recording. Runs entirely on your Mac using a local Python process."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text(String(localized: "Local Speaker Diarization"))
            }

            if isEnabled {
                Section {
                    TextField(
                        String(localized: "Python path"),
                        text: $pythonPath,
                        prompt: Text(verbatim: "python3")
                    )
                    .textFieldStyle(.roundedBorder)

                    SecureField(
                        String(localized: "HuggingFace Token"),
                        text: $hfToken
                    )
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: hfToken) { _, newValue in
                        saveToken(newValue)
                    }

                    Stepper(
                        value: $numSpeakers,
                        in: 0...20
                    ) {
                        HStack {
                            Text(String(localized: "Number of speakers"))
                            Spacer()
                            Text(numSpeakers == 0
                                 ? String(localized: "Auto-detect")
                                 : "\(numSpeakers)")
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text(String(localized: "Configuration"))
                } footer: {
                    Text(String(localized: "Set the number of speakers to 0 to let the model detect it automatically."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section {
                    statusRow
                } header: {
                    Text(String(localized: "Status"))
                } footer: {
                    Text(String(localized: "Requires pyannote.audio. See the README for setup instructions."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(minWidth: 500, minHeight: 300)
        .onAppear {
            hfToken = KeychainService.load(service: Self.keychainService) ?? ""
        }
        .task(id: isEnabled) {
            guard isEnabled else { return }
            await refreshStatus()
        }
    }

    @ViewBuilder
    private var statusRow: some View {
        HStack {
            if isCheckingStatus {
                ProgressView()
                    .controlSize(.small)
                Text(String(localized: "Checking..."))
                    .foregroundStyle(.secondary)
            } else if providerAvailable == true {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text(String(localized: "Ready"))
            } else {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                Text(String(localized: "Setup required"))
            }

            Spacer()

            Button(String(localized: "Recheck")) {
                Task { await refreshStatus() }
            }
            .disabled(isCheckingStatus)
        }
    }

    private func refreshStatus() async {
        isCheckingStatus = true
        defer { isCheckingStatus = false }
        providerAvailable = await LocalDiarizationService.shared.provider.isAvailable
    }

    private func saveToken(_ value: String) {
        if value.isEmpty {
            try? KeychainService.delete(service: Self.keychainService)
        } else {
            try? KeychainService.save(key: value, service: Self.keychainService)
        }
    }
}
