import SwiftUI

/// [Track B] The floating bottom bar of the meeting document (plan D4): a waveform button that
/// toggles the transcript panel, an "Ask this meeting…" field wired to the existing Q&A path, and
/// the Start / Stop / Resume / Generate ▾ context-action state machine
/// (`MeetingsViewModel.DocumentContextAction`).
struct MeetingBottomBar: View {
    @ObservedObject private var viewModel = MeetingsViewModel.shared
    // [Track J] Observe the queue directly so the meeting-scoped Generate spinner reacts to job
    // state changes (the VM does not republish on queue mutations — plan J1 §CC7).
    @ObservedObject private var jobQueue = JobQueueService.shared
    @ObservedObject var model: MeetingDocumentModel
    let meeting: Meeting
    let presentation: MeetingsViewModel.DocumentPresentation

    var body: some View {
        HStack(spacing: 12) {
            transcriptToggle
            askField
            contextActions
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(.separator, lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }

    private var transcriptToggle: some View {
        Button {
            model.isTranscriptPanelOpen.toggle()
        } label: {
            Image(systemName: model.isTranscriptPanelOpen ? "waveform.circle.fill" : "waveform.circle")
                .font(.title2)
                .symbolRenderingMode(.hierarchical)
        }
        .buttonStyle(.borderless)
        .help(String(localized: "meetingdoc.bottombar.transcriptToggle"))
    }

    private var askField: some View {
        HStack(spacing: 6) {
            Image(systemName: "sparkles")
                .foregroundStyle(.secondary)
            TextField(String(localized: "meetingdoc.bottombar.askPlaceholder"), text: $model.askDraft)
                .textFieldStyle(.plain)
                .onSubmit(submitAsk)
                .disabled(viewModel.isAnswering(for: meeting.id))
            if viewModel.isAnswering(for: meeting.id) {
                ProgressView().controlSize(.small)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.secondary.opacity(0.12), in: Capsule())
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var contextActions: some View {
        switch presentation.contextAction {
        case .start:
            startButton
        case .stop:
            stopButton
        case .resumeAndGenerate:
            HStack(spacing: 8) {
                resumeButton
                generateMenu
            }
        case .generate:
            generateMenu
        }
    }

    private var startButton: some View {
        Button {
            Task { await viewModel.startCapture(for: meeting) }
        } label: {
            Label(String(localized: "meetingdoc.start.primary"), systemImage: "record.circle.fill")
        }
        .buttonStyle(.borderedProminent)
        .tint(.red)
        .disabled(!viewModel.canStartCapture)
    }

    private var stopButton: some View {
        Button {
            Task { await viewModel.stopCapture() }
        } label: {
            Label(String(localized: "meetingdoc.stop"), systemImage: "stop.circle.fill")
        }
        .buttonStyle(.borderedProminent)
        .tint(.red)
        .keyboardShortcut(".", modifiers: [.command])
    }

    private var resumeButton: some View {
        Button {
            Task { await viewModel.resumeCapture(for: meeting) }
        } label: {
            Label(String(localized: "meetingdoc.resume"), systemImage: "record.circle")
        }
        .disabled(!viewModel.canStartCapture)
    }

    @ViewBuilder
    private var generateMenu: some View {
        let kind = model.selectedOutputKind
        let templates = viewModel.templates(ofKind: kind)
        let preselected = viewModel.defaultTemplate(ofKind: kind, for: meeting)
        let hasExisting = viewModel.latestOutput(ofKind: kind, for: meeting) != nil
        let label = hasExisting
            ? String(localized: "meetingdoc.generate.regenerate")
            : String(localized: "meetingdoc.generate")

        if viewModel.isGeneratingOutput(for: meeting) {
            ProgressView().controlSize(.small)
        } else if templates.isEmpty {
            Text(String(localized: "meetingdoc.generate.noTemplates"))
                .font(.caption2)
                .foregroundStyle(.secondary)
        } else {
            Menu {
                ForEach(templates, id: \.id) { template in
                    Button {
                        viewModel.generateOutput(for: meeting, using: template)
                    } label: {
                        if template.id == preselected?.id {
                            Label(template.name, systemImage: "checkmark")
                        } else {
                            Text(template.name)
                        }
                    }
                }
            } label: {
                Label(label, systemImage: "sparkles")
            } primaryAction: {
                if let preselected {
                    viewModel.generateOutput(for: meeting, using: preselected)
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(meeting.segments.isEmpty)
        }
    }

    private func submitAsk() {
        let question = model.askDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !viewModel.isAnswering(for: meeting.id) else { return }
        model.askDraft = ""
        Task {
            let ok = await viewModel.askQuestion(question, for: meeting)
            if !ok, model.askDraft.isEmpty { model.askDraft = question }
        }
    }
}
