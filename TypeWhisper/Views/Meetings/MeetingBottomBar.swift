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
    // [M5/D10] The prompt-provider catalog for the one-shot "For this run" / "Save as default…" submenus.
    @ObservedObject private var promptProcessingService = ServiceContainer.shared.promptProcessingService
    @ObservedObject var model: MeetingDocumentModel
    let meeting: Meeting
    let presentation: MeetingsViewModel.DocumentPresentation

    var body: some View {
        HStack(spacing: 12) {
            // [Sprint 1] Pre-meeting the bar carries exactly one verb: Start. The waveform toggle
            // and Ask field are useless without segments, so they don't render — and the live timer
            // pill (relocated from the old header chip) anchors the left edge while recording.
            if presentation.showsLiveChip {
                liveTimerPill
            }
            if presentation.bodyMode == .scheduledEmpty {
                Spacer(minLength: 0)
                contextActions
                Spacer(minLength: 0)
            } else {
                transcriptToggle
                askField
                contextActions
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: MeetingTheme.barRadius))
        .overlay(
            RoundedRectangle(cornerRadius: MeetingTheme.barRadius)
                .strokeBorder(.separator, lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }

    /// True while `stop()`'s off-MainActor teardown is finalizing *this* meeting — the pill then
    /// reads "Finalizing…" instead of the live timer.
    private var isFinalizingThisMeeting: Bool {
        viewModel.isFinalizing && viewModel.activeMeeting?.id == meeting.id
    }

    /// The live timer pill (moved here from the old header live chip): red dot + monospaced elapsed
    /// time, or a spinner while finalizing.
    @ViewBuilder
    private var liveTimerPill: some View {
        if isFinalizingThisMeeting {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(String(localized: "meetingdoc.finalizing"))
                    .font(.caption.bold())
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(.secondary.opacity(0.12), in: Capsule())
        } else {
            HStack(spacing: 6) {
                Circle()
                    .fill(.red)
                    .frame(width: 8, height: 8)
                Text(String(localized: "meetingdoc.live"))
                    .font(.caption.bold())
                Text(MeetingTranscriptPanel.timestamp(viewModel.captureElapsedSeconds))
                    .font(.caption.monospacedDigit())
            }
            .foregroundStyle(.red)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(.red.opacity(0.12), in: Capsule())
        }
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
        case .finalizing:
            finalizingIndicator
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

    /// Shown the instant Stop is pressed while the off-MainActor teardown finalizes (buffer snapshot,
    /// recorder mixdown, audio adopt). A disabled, spinner-labeled affordance so the user sees the
    /// stop registered immediately — the window stays responsive because the teardown never blocks
    /// the main thread.
    private var finalizingIndicator: some View {
        Label {
            Text(String(localized: "meetingdoc.finalizing"))
        } icon: {
            ProgressView().controlSize(.small)
        }
        .foregroundStyle(.secondary)
        .help(String(localized: "meetingdoc.finalizing.help"))
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

                // [M5/D10] One-shot model override for the preselected template: pick a provider/model
                // "for this run" (wins the ladder, persists nothing) or save the pick as the template's
                // own default. Both target the *template* (adjudication Part A #6) — the copy says so.
                if let preselected {
                    Divider()
                    Menu(String(localized: "meetingdoc.generate.forThisRun")) {
                        modelPickerContents { providerId, modelId in
                            viewModel.generateOutput(
                                for: meeting, using: preselected,
                                providerOverride: providerId, modelOverride: modelId
                            )
                        }
                    }
                    Menu(String(localized: "meetingdoc.generate.saveAsDefault")) {
                        modelPickerContents { providerId, modelId in
                            viewModel.saveModelDefaultToTemplate(
                                provider: providerId, model: modelId, for: preselected
                            )
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

    /// [M5/D10] The provider→model nesting shared by the "For this run" and "Save as default…" submenus.
    /// `action(providerId, modelId?)` fires with the picked provider and optional model; a provider with
    /// no model dimension is a single leaf button (nil model), otherwise it nests one button per model.
    @ViewBuilder
    private func modelPickerContents(
        action: @escaping (_ providerId: String, _ modelId: String?) -> Void
    ) -> some View {
        ForEach(promptProcessingService.availableProviders, id: \.id) { provider in
            let models = promptProcessingService.modelsForProvider(provider.id)
            if models.isEmpty {
                Button(provider.displayName) { action(provider.id, nil) }
            } else {
                Menu(provider.displayName) {
                    ForEach(models, id: \.id) { model in
                        Button(model.displayName) { action(provider.id, model.id) }
                    }
                }
            }
        }
    }

    private func submitAsk() {
        let question = model.askDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !viewModel.isAnswering(for: meeting.id) else { return }
        model.askDraft = ""
        // [Sprint 1] Answers render in the side panel's Q&A tab — open it so the reply is visible
        // without pushing the document around.
        model.panelTab = .qa
        model.isTranscriptPanelOpen = true
        Task {
            let ok = await viewModel.askQuestion(question, for: meeting)
            if !ok, model.askDraft.isEmpty { model.askDraft = question }
        }
    }
}
