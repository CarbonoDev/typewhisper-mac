import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Import surface (plan M8): create a new meeting from an audio or transcript file, or merge a
/// transcript file into an existing meeting. Presented as a sheet from the Meetings window.
///
/// The posture is driven by `mergeTarget` (merge-import default fix): when a merge target is set the
/// sheet leads with **merging** the chosen transcript into that meeting (the natural, non-duplicating
/// action), and demotes "create a separate meeting" to a clearly-labeled secondary option. Without a
/// merge target (the list toolbar) it keeps the create-new posture. The posture decision itself lives
/// in the pure, unit-tested `MeetingsViewModel.importSheetMode(mergeTargetTitle:)`.
struct MeetingImportView: View {
    @ObservedObject private var viewModel = MeetingsViewModel.shared
    // [Track J] Observe the queue directly so the import spinner reacts to `.audioImport` job state
    // (the VM no longer mirrors `isImporting` — plan J2 §CC7).
    @ObservedObject private var jobQueue = JobQueueService.shared
    @Environment(\.dismiss) private var dismiss

    /// When non-nil, merging into this meeting is the sheet's primary action.
    let mergeTarget: Meeting?
    /// Called with the created/merged meeting so the window can select it.
    var onImported: (Meeting) -> Void = { _ in }

    /// Optional language for an audio import (plan M1/D9). `nil` = Auto (detect); a chosen code drives
    /// transcription and is persisted `.manual` on the created meeting.
    @State private var audioLanguageCode: String?

    /// In merge-primary mode, whether the user expanded the demoted "create a separate meeting"
    /// options. Kept collapsed by default so the primary (merge) action reads first.
    @State private var showCreateNewOptions = false

    private var mode: MeetingsViewModel.ImportSheetMode {
        MeetingsViewModel.importSheetMode(mergeTargetTitle: mergeTarget?.title)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            switch mode {
            case .createPrimary:
                createPrimaryHeader
                createNewOptions
            case .mergePrimary(let title):
                mergePrimaryHeader(title: title)
                mergePrimaryAction
                Divider()
                createNewSecondary
            }

            if viewModel.isImporting() {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(String(localized: "meetings.import.inProgress"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let error = viewModel.importErrorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button(String(localized: "meetings.import.close")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    // MARK: - Create-primary posture (no merge target — list toolbar)

    private var createPrimaryHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "meetings.import.title"))
                .font(.headline)
            Text(String(localized: "meetings.import.description"))
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    /// The create-a-new-meeting options (transcript file, audio file, and the audio language picker).
    /// Shared by the create-primary posture and the demoted secondary in merge-primary mode.
    private var createNewOptions: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                importTranscript()
            } label: {
                Label(String(localized: "meetings.import.transcriptButton"), systemImage: "doc.text")
            }
            .disabled(viewModel.isImporting())

            Button {
                importAudio()
            } label: {
                Label(String(localized: "meetings.import.audioButton"), systemImage: "waveform")
            }
            .disabled(viewModel.isImporting())

            HStack(spacing: 8) {
                Text(String(localized: "meetings.import.language.label"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Menu {
                    Button {
                        audioLanguageCode = nil
                    } label: {
                        languageMenuRow(
                            title: String(localized: "meetings.import.language.auto"),
                            isSelected: audioLanguageCode == nil
                        )
                    }
                    Divider()
                    ForEach(viewModel.meetingLanguageOptions, id: \.code) { option in
                        Button {
                            audioLanguageCode = option.code
                        } label: {
                            languageMenuRow(title: option.name, isSelected: audioLanguageCode == option.code)
                        }
                    }
                } label: {
                    Text(selectedLanguageTitle)
                }
                .fixedSize()
                .disabled(viewModel.isImporting())
            }
        }
    }

    // MARK: - Merge-primary posture (a merge target — document import)

    private func mergePrimaryHeader(title: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(format: String(localized: "meetings.import.merge.title"), title))
                .font(.headline)
            Text(String(localized: "meetings.import.merge.description"))
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var mergePrimaryAction: some View {
        if let meeting = mergeTarget {
            Button {
                mergeTranscript(into: meeting)
            } label: {
                Label(String(localized: "meetings.import.merge.primaryButton"), systemImage: "arrow.triangle.merge")
            }
            .buttonStyle(.borderedProminent)
            .disabled(viewModel.isImporting())
        }
    }

    /// The demoted "create a separate meeting instead" affordance: a link that reveals the full
    /// create-new options on demand, so the primary (merge) action stays visually dominant.
    @ViewBuilder
    private var createNewSecondary: some View {
        if showCreateNewOptions {
            Text(String(localized: "meetings.import.merge.createInstead"))
                .font(.caption)
                .foregroundStyle(.secondary)
            createNewOptions
        } else {
            Button(String(localized: "meetings.import.merge.createInstead")) {
                showCreateNewOptions = true
            }
            .buttonStyle(.link)
        }
    }

    // MARK: - Actions

    private func importTranscript() {
        guard let url = openPanel(extensions: viewModel.transcriptFileExtensions) else { return }
        if let meeting = viewModel.importTranscriptFile(at: url) {
            onImported(meeting)
            dismiss()
        }
    }

    private func importAudio() {
        guard let url = openPanel(extensions: viewModel.audioFileExtensions) else { return }
        // [Track J] Audio import is now a queued `.audioImport` job; the sheet stays open showing the
        // spinner (`isImporting()`) until the job's completion selects the created meeting and dismisses.
        viewModel.importAudioFile(at: url, languageCode: audioLanguageCode) { meeting in
            onImported(meeting)
            dismiss()
        }
    }

    private var selectedLanguageTitle: String {
        guard let audioLanguageCode else { return String(localized: "meetings.import.language.auto") }
        return localizedAppLanguageName(for: audioLanguageCode)
    }

    @ViewBuilder
    private func languageMenuRow(title: String, isSelected: Bool) -> some View {
        if isSelected {
            Label(title, systemImage: "checkmark")
        } else {
            Text(title)
        }
    }

    private func mergeTranscript(into meeting: Meeting) {
        guard let url = openPanel(extensions: viewModel.transcriptFileExtensions) else { return }
        if viewModel.mergeTranscriptFile(at: url, into: meeting) {
            onImported(meeting)
            dismiss()
        }
    }

    private func openPanel(extensions: [String]) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = extensions.compactMap { UTType(filenameExtension: $0) }
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }
}
