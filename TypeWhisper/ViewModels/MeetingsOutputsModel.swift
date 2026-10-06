import Combine
import Foundation

/// [Perf Phase 2 · VM split] The outputs slice of `MeetingsViewModel`: the meeting output templates,
/// the in-flight Q&A set and the per-operation error/status messages (output, brief, Q&A, export,
/// import, diarization), on their own `ObservableObject` so asking a question or a failed generate
/// re-renders only the document leaves that show them instead of every observer of the singleton
/// view model (the main window, the lists, Home).
///
/// Owned by `MeetingsViewModel` as `outputs` (a plain `let`); the VM forwards the old property names
/// as computed properties and remains the only writer of the messages (its actions set and clear
/// them, hence the internal setters). See `docs/specs/2026-10-06-meetings-vm-split.md`.
@MainActor
final class MeetingsOutputsModel: ObservableObject {
    // Outputs / templates (M4; unified into PromptAction meeting rows — plan AD6)
    @Published private(set) var templates: [PromptAction]
    @Published var outputErrorMessage: String?
    /// Set alongside `outputErrorMessage` when the failure is specifically "no LLM provider
    /// configured", so the document body can offer a deep link into Settings › Library › Prompts.
    @Published var outputErrorNeedsProvider = false

    // Brief (M5). [Track J] `isGeneratingBrief` is derived from the job queue, not mirrored.
    @Published var briefErrorMessage: String?
    @Published var briefErrorNeedsProvider = false

    // In-meeting Q&A (M6)
    /// [Track J] Meeting-scoped Q&A activity (plan J2): mirrored from `MeetingLLMService`. Asking a
    /// question in meeting A must not disable meeting B's Ask field, so this is a set, not a bool.
    @Published private(set) var answeringMeetingIDs: Set<UUID>
    @Published var qaErrorMessage: String?
    @Published var qaErrorNeedsProvider = false

    // Obsidian export (M7)
    @Published var exportErrorMessage: String?

    // Import / merge (M8). [Track J] `isImporting` is derived from the job queue, not mirrored.
    @Published var importErrorMessage: String?

    // Speaker diarization & mapping (M9). [Track J] `isEnriching` is derived from the job queue.
    @Published var diarizationErrorMessage: String?
    /// A localized status shown after enrichment finishes without labeling (e.g. "no speakers
    /// detected"). Cleared when a new enrichment starts.
    @Published var diarizationStatusMessage: String?
    /// [M1/D2] The enrichment outcome that produced `diarizationStatusMessage`, tracked alongside the
    /// localized string so suppression under a resolved `.channel`/`.cloud` plan can distinguish a
    /// "no path" outcome (`.unavailable`/`.noAudio` — genuinely mutually exclusive with a resolved path,
    /// suppress it) from an outcome that is still meaningful under a channel/cloud plan (a Redo that
    /// returns `.timelineMismatch`/`.noSpeakersDetected` — keep it visible; the earlier blanket
    /// suppression silently swallowed those, leaving the user with zero feedback). Set and cleared in
    /// lockstep with `diarizationStatusMessage`.
    @Published var diarizationStatusOutcome: MeetingDiarizationEnricher.Outcome?

    private var cancellables = Set<AnyCancellable>()

    init(promptActionService: PromptActionService, llmService: MeetingLLMService) {
        templates = promptActionService.meetingActions
        answeringMeetingIDs = llmService.answeringMeetingIDs

        // Assigned unconditionally: `PromptAction` rows compare by identity, so an in-place edit
        // (rename, prompt change) republishes the same array and must still reach the views.
        promptActionService.$meetingActions
            .sink { [weak self] templates in
                self?.templates = templates
            }
            .store(in: &cancellables)
        // Q&A activity is mirrored (Q&A stays out of the job queue) as a per-meeting set (J2).
        llmService.$answeringMeetingIDs.mirror(to: self, \.answeringMeetingIDs).store(in: &cancellables)
    }

    /// Clear the per-meeting transient status/error banners (see
    /// `MeetingsViewModel.clearTransientMessages()`). Each write is guarded so a navigation with
    /// nothing to clear publishes nothing.
    func clearTransientMessages() {
        if outputErrorMessage != nil { outputErrorMessage = nil }
        if outputErrorNeedsProvider { outputErrorNeedsProvider = false }
        if briefErrorMessage != nil { briefErrorMessage = nil }
        if briefErrorNeedsProvider { briefErrorNeedsProvider = false }
        if qaErrorMessage != nil { qaErrorMessage = nil }
        if qaErrorNeedsProvider { qaErrorNeedsProvider = false }
        if exportErrorMessage != nil { exportErrorMessage = nil }
        if diarizationErrorMessage != nil { diarizationErrorMessage = nil }
        if diarizationStatusMessage != nil { diarizationStatusMessage = nil }
        if diarizationStatusOutcome != nil { diarizationStatusOutcome = nil }
    }
}
