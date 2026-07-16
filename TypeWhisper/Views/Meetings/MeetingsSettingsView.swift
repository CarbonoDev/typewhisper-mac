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
    // [M4] Vault-relative root folder that meeting exports nest under (plan D7). Default "Meetings";
    // empty exports to the vault root.
    @AppStorage(UserDefaultsKeys.meetingsObsidianRootFolder) private var obsidianRootFolder = "Meetings"
    // [Speaker-recognition amendment, D-A7] Prefer provider (cloud) speaker labels over local
    // diarization when a speaker-capable engine returns them. Registered default ON.
    @AppStorage(UserDefaultsKeys.meetingsPreferProviderSpeakerLabels) private var preferProviderSpeakerLabels = true

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

                // [Speaker-recognition amendment, D-A7] Speaker labeling preference.
                speakerSection

                Divider()

                // [M2] Per-meeting language detection provider (plan D5).
                languageDetectionSection

                Divider()

                // [M3-Participants] Directory management: rename, merge, split, delete (plan M3/D5#11).
                ParticipantDirectorySection()

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

            // [M4] Meetings root folder (plan D7): exports nest under this vault-relative folder.
            Divider()
            VStack(alignment: .leading, spacing: 4) {
                Text(String(localized: "meetings.obsidian.root.label"))
                    .font(.callout)
                TextField(String(localized: "meetings.obsidian.root.placeholder"), text: $obsidianRootFolder)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 320)
                Text(String(localized: "meetings.obsidian.root.hint"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
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

    /// [Speaker-recognition amendment, D-A7] A tiny speaker block: prefer provider labels when a
    /// speaker-capable engine returns them (drives cloud adoption + the path-aware Identify UI). The
    /// two-person channel path and the global diarization / numSpeakers controls live elsewhere.
    private var speakerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "meetings.speakers.sectionTitle"))
                .font(.headline)
            Toggle(isOn: $preferProviderSpeakerLabels) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(localized: "meetings.speakers.preferProvider.title"))
                    Text(String(localized: "meetings.speakers.preferProvider.subtitle"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            // [O1] Adoption is adopt-only: the meeting pref never reaches into a plugin's settings, so
            // it does nothing unless the selected cloud engine has its own speaker-labels option turned
            // on (e.g. AssemblyAI's `speaker_labels`, default off). Surface that so the setting is not
            // silently inert.
            if preferProviderSpeakerLabels {
                Label(String(localized: "meetings.speakers.preferProvider.hint"), systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 2)
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

/// [M3-Participants] The participant directory manager (plan M3): the accumulated people list with
/// per-person rename (display-time only, plan D6), manual merge (plan D5 #11), split of a
/// merge-recorded secondary email back out (plan D8 escape hatch), and delete (plan Part F #6). All
/// mutations route through `MeetingsViewModel` → the single-writer `ParticipantDirectoryService`.
private struct ParticipantDirectorySection: View {
    @ObservedObject private var viewModel = MeetingsViewModel.shared
    @ObservedObject private var directory = ServiceContainer.shared.participantDirectoryService

    @State private var renamingPersonID: UUID?
    @State private var renameDraft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "meetings.participants.sectionTitle"))
                .font(.headline)
            Text(String(localized: "meetings.participants.section.subtitle"))
                .font(.caption)
                .foregroundStyle(.secondary)

            if directory.persons.isEmpty {
                Text(String(localized: "meetings.participants.empty"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                let stats = viewModel.directoryStats()
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(directory.persons, id: \.id) { person in
                        personRow(person, stats: stats[person.id])
                        if person.id != directory.persons.last?.id {
                            Divider()
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func personRow(_ person: Person, stats: PersonStats?) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                if renamingPersonID == person.id {
                    TextField(String(localized: "meetings.participants.rename.field"), text: $renameDraft)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 220)
                        .onSubmit { commitRename(person) }
                } else {
                    Text(person.displayName)
                        .font(.callout)
                }
                HStack(spacing: 6) {
                    if let email = person.emailKey, !email.isEmpty {
                        Text(email)
                    } else {
                        Text(String(localized: "meetings.participants.noEmail"))
                    }
                    if let count = stats?.meetingCount, count > 0 {
                        Text("·")
                        Text(String(
                            format: String(localized: "meetings.participants.meetingCount"),
                            count
                        ))
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)

            if renamingPersonID == person.id {
                Button(String(localized: "meetings.participants.rename.save")) { commitRename(person) }
                Button(String(localized: "meetings.participants.rename.cancel")) { cancelRename() }
            } else {
                rowMenu(person)
            }
        }
        .padding(.vertical, 6)
    }

    private func rowMenu(_ person: Person) -> some View {
        Menu {
            Button {
                renamingPersonID = person.id
                renameDraft = person.displayName
            } label: {
                Label(String(localized: "meetings.participants.action.rename"), systemImage: "pencil")
            }

            let others = directory.persons.filter { $0.id != person.id }
            if !others.isEmpty {
                Menu(String(localized: "meetings.participants.action.mergeInto")) {
                    ForEach(others, id: \.id) { other in
                        Button(other.displayName) {
                            viewModel.mergePersons(person, into: other)
                        }
                    }
                }
            }

            let altEmails = person.altEmails
            if !altEmails.isEmpty {
                Menu(String(localized: "meetings.participants.action.split")) {
                    ForEach(altEmails, id: \.self) { email in
                        Button(email) {
                            viewModel.splitEmail(email, from: person)
                        }
                    }
                }
            }

            Divider()
            Button(role: .destructive) {
                viewModel.deletePerson(person)
            } label: {
                Label(String(localized: "meetings.participants.action.delete"), systemImage: "trash")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private func commitRename(_ person: Person) {
        viewModel.renamePerson(person, to: renameDraft)
        cancelRename()
    }

    private func cancelRename() {
        renamingPersonID = nil
        renameDraft = ""
    }
}
