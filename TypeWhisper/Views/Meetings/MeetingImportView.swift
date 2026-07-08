import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Import surface (plan M8): create a new meeting from an audio or transcript file, or merge a
/// transcript file into an existing meeting. Presented as a sheet from the Meetings window.
struct MeetingImportView: View {
    @ObservedObject private var viewModel = MeetingsViewModel.shared
    // [Track J] Observe the queue directly so the import spinner reacts to `.audioImport` job state
    // (the VM no longer mirrors `isImporting` — plan J2 §CC7).
    @ObservedObject private var jobQueue = JobQueueService.shared
    @Environment(\.dismiss) private var dismiss

    /// When non-nil, the merge-into-existing option targets this meeting.
    let mergeTarget: Meeting?
    /// Called with the created meeting so the window can select it.
    var onImported: (Meeting) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(String(localized: "meetings.import.title"))
                .font(.headline)

            Text(String(localized: "meetings.import.description"))
                .font(.callout)
                .foregroundStyle(.secondary)

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

                if let meeting = mergeTarget {
                    Divider()
                    Text(String(format: String(localized: "meetings.import.mergeInto"), meeting.title))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button {
                        mergeTranscript(into: meeting)
                    } label: {
                        Label(String(localized: "meetings.import.mergeButton"), systemImage: "arrow.triangle.merge")
                    }
                    .disabled(viewModel.isImporting())
                }
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
        viewModel.importAudioFile(at: url) { meeting in
            onImported(meeting)
            dismiss()
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
