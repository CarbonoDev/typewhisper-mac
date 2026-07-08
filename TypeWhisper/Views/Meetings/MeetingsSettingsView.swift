import SwiftUI

/// Meetings settings tab. Shows the calendar-driven upcoming-meetings section (M2) above the
/// list of stored meetings, or an empty state when none exist yet. Capture, outputs, and the
/// standalone window arrive in later milestones.
struct MeetingsSettingsView: View {
    @ObservedObject private var viewModel = MeetingsViewModel.shared
    // [M2] Language-detection provider selection, resolved per-call by the detector; empty = "Use
    // prompt provider" (inherit the current prompt-provider selection).
    @ObservedObject private var promptProcessingService = ServiceContainer.shared.promptProcessingService
    // [Track A] AD5 dictation bridge toggle — defaults OFF. Self-contained UserDefaults binding so
    // no shared view-model edit is required.
    @AppStorage(UserDefaultsKeys.meetingsBridgeToDictationEvents) private var bridgeToDictationEvents = false
    // [M2] Per-meeting language-detection provider/model (plan D5). Empty provider ⇒ prompt provider.
    @AppStorage(UserDefaultsKeys.meetingsLanguageDetectionProviderId) private var detectionProviderId = ""
    @AppStorage(UserDefaultsKeys.meetingsLanguageDetectionModel) private var detectionModel = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                UpcomingMeetingsSection()

                Divider()

                // [M11] Per-calendar inclusion: which macOS calendars feed the feature.
                CalendarSelectionSection()

                Divider()

                vaultSection

                Divider()

                pluginBridgeSection

                Divider()

                // [Track C] Capture-context rules (AD7) + global final re-transcription (AD8).
                MeetingContextRulesView()

                Divider()

                FinalRetranscriptionSettingsView()

                Divider()

                // [M2] Per-meeting language detection provider (plan D5).
                languageDetectionSection

                Divider()

                // [Track D] Automatic pre-meeting brief settings (plan AD9).
                AutoBriefSettingsView()

                Divider()

                if viewModel.hasMeetings {
                    meetingsList
                } else {
                    emptyState
                }

                Divider()

                // [Track B] Unified prompt/template library (plan AD6).
                PromptLibraryView()
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .navigationTitle(String(localized: "settings.tab.meetings"))
        .onAppear { viewModel.startCalendarPolling() }
        .onDisappear { viewModel.stopCalendarPolling() }
    }

    /// Obsidian knowledge-base connection (M5): connection state plus auto-detect / pick / forget.
    private var vaultSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "meetings.vault.sectionTitle"))
                .font(.headline)

            if viewModel.isVaultConnected {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text(String(
                        format: String(localized: "meetings.vault.connected"),
                        viewModel.vaultName ?? ""
                    ))
                    Spacer()
                    Button(String(localized: "meetings.vault.disconnect")) {
                        viewModel.disconnectVault()
                    }
                }
                .font(.callout)
            } else {
                Text(String(localized: "meetings.vault.notConnected"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Button(String(localized: "meetings.vault.autoDetect")) {
                        _ = viewModel.autoConnectVault()
                    }
                    Button(String(localized: "meetings.vault.chooseButton")) {
                        viewModel.chooseVault()
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// [Track A] Plugin integration for meetings. The bridge (AD5) re-emits a finished meeting's
    /// transcript on the classic dictation event stream so dictation-keyed plugins fire for
    /// meetings; default OFF to preserve the meeting/dictation isolation guarantee.
    private var pluginBridgeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "meetings.plugins.sectionTitle"))
                .font(.headline)

            Toggle(isOn: $bridgeToDictationEvents) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(localized: "meetings.plugins.bridge.title"))
                    Text(String(localized: "meetings.plugins.bridge.subtitle"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// [M2] Language-detection provider picker (plan D5). The default row "Use prompt provider" maps to
    /// an empty stored value, which the detector resolves per call to the current prompt-provider
    /// selection (`providerOverride: nil`). A specific provider optionally pins a model.
    private var languageDetectionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "meetings.language.sectionTitle"))
                .font(.headline)
            Text(String(localized: "meetings.language.section.subtitle"))
                .font(.caption)
                .foregroundStyle(.secondary)

            Picker(String(localized: "meetings.language.provider.label"), selection: $detectionProviderId) {
                Text(String(localized: "meetings.language.provider.usePromptProvider")).tag("")
                ForEach(promptProcessingService.availableProviders, id: \.id) { provider in
                    Text(provider.displayName).tag(provider.id)
                }
            }
            .onChange(of: detectionProviderId) { _, _ in
                // Switching provider invalidates a model pinned to the previous one.
                detectionModel = ""
            }

            if !detectionProviderId.isEmpty {
                let models = promptProcessingService.modelsForProvider(detectionProviderId)
                if !models.isEmpty {
                    Picker(String(localized: "meetings.language.model.label"), selection: $detectionModel) {
                        Text(String(localized: "meetings.language.model.default")).tag("")
                        ForEach(models, id: \.id) { model in
                            Text(model.displayName).tag(model.id)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            ContentUnavailableView {
                Label(String(localized: "meetings.emptyState.title"), systemImage: "person.2.wave.2")
            } description: {
                Text(String(localized: "meetings.emptyState.message"))
            }

            #if DEBUG
            Button("Seed Demo Meeting") {
                viewModel.seedDemoMeeting()
            }
            .buttonStyle(.plain)
            .foregroundStyle(.orange)
            .font(.caption)
            #endif
        }
        .frame(maxWidth: .infinity)
    }

    private var meetingsList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "meetings.list.title"))
                .font(.headline)
            ForEach(viewModel.meetings, id: \.id) { meeting in
                VStack(alignment: .leading, spacing: 4) {
                    Text(meeting.title)
                        .font(.headline)
                    HStack(spacing: 8) {
                        if let start = meeting.startDate {
                            Text(start, style: .date)
                        }
                        Text(meeting.state.displayName)
                            .foregroundStyle(.secondary)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 2)
            }
        }
    }
}
