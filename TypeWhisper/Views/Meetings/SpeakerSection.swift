import SwiftUI

/// [Speaker-recognition amendment, M9-SPK-A] The meeting document's speaker section (D-A7): a small,
/// honest, **path-aware** surface that states which labeling source applies to the completed meeting
/// so the action is never a mystery, plus the ad-hoc two-person toggle, an Undo/Redo for the
/// automatic channel labeling, and the name-mapping editor.
///
/// - Cloud (`.cloud`): "Speakers from your provider" + mapping editor.
/// - Channel (`.channel`): "Speakers labeled by your call's audio channels" (auto-run) + Undo/Redo.
/// - Pyannote (`.pyannote`): the on-demand "Identify speakers" button.
/// - None (`.none`): only the two-person toggle (when eligible) is offered.
struct SpeakerSection: View {
    @ObservedObject private var viewModel = MeetingsViewModel.shared
    @ObservedObject private var jobQueue = JobQueueService.shared
    let meeting: Meeting

    /// The resolved path (cloud / channel / pyannote / none) that applies to this meeting. Nil while
    /// the audio-header probe runs. Recomputed when the meeting or its labels change.
    @State private var plannedSource: SpeakerSource?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(String(localized: "meetings.diarization.title"))
                    .font(.headline)
                Spacer()
                trailingAction
            }

            pathDescription

            if viewModel.showsTwoPersonToggle(for: meeting) {
                twoPersonToggle
            }

            // [M1/D2] Never co-render a resolved-path caption with a contradictory "no path" status
            // (e.g. the persisted "unavailable" line under a `.channel`/`.cloud` path — the owner's
            // screenshot). The status is suppressed whenever the resolved plan already names a source.
            if let status = viewModel.diarizationStatusMessage,
               MeetingsViewModel.showsDiarizationStatus(status, under: plannedSource) {
                Label(status, systemImage: "info.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if let error = viewModel.diarizationErrorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }

            if hasSpeakerLabels {
                SpeakerMappingView(meeting: meeting)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // Re-resolve when the meeting changes, when its speaker labels change (a fresh auto-label /
        // Undo / Identify), or when the two-person toggle flips.
        .task(id: meeting.id) { await refreshPlan() }
        .task(id: meeting.speakerMapJSON) { await refreshPlan() }
        .task(id: meeting.twoPersonCall) { await refreshPlan() }
        // [M3] Adding/removing a participant changes `effectiveParticipantCount` (and empties/refills the
        // roster the two-person toggle keys off), so re-resolve the plan when the roster changes.
        .task(id: meeting.attendeesJSON) { await refreshPlan() }
    }

    private var hasSpeakerLabels: Bool {
        meeting.segments.contains { ($0.speakerLabel?.isEmpty == false) }
    }

    private func refreshPlan() async {
        plannedSource = await viewModel.plannedSpeakerSource(for: meeting)
    }

    // MARK: - Path description (D-A7)

    @ViewBuilder
    private var pathDescription: some View {
        if let source = plannedSource {
            switch source {
            case .cloud:
                caption("meetings.speakers.path.cloud", systemImage: "cloud")
            case .channel:
                caption("meetings.speakers.path.channel", systemImage: "waveform")
            case .pyannote:
                caption("meetings.speakers.path.pyannote", systemImage: "person.wave.2")
            case .none:
                EmptyView()
            }
        }
    }

    private func caption(_ key: String.LocalizationValue, systemImage: String) -> some View {
        Label(String(localized: key), systemImage: systemImage)
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    // MARK: - Trailing action (path-aware)

    @ViewBuilder
    private var trailingAction: some View {
        if isWorking {
            ProgressView().controlSize(.small)
        } else if let source = plannedSource {
            switch source {
            case .channel:
                // Auto-run: offer Undo, and a Redo (re-run) once cleared.
                if hasSpeakerLabels {
                    Button(String(localized: "meetings.speakers.undo")) {
                        viewModel.clearSpeakerLabels(for: meeting)
                    }
                } else {
                    Button {
                        viewModel.relabelByChannel(for: meeting)
                    } label: {
                        Label(String(localized: "meetings.speakers.redo"), systemImage: "arrow.clockwise")
                    }
                }
            case .pyannote:
                // [M9-SPK-B / D-A6] Disclose the timing re-pass in the button copy, but only when it
                // will actually run (the meeting still carries coarse live timestamps).
                Button {
                    viewModel.identifySpeakers(for: meeting)
                } label: {
                    Label(
                        String(localized: viewModel.pyannoteIdentifyRefinesTimingFirst(for: meeting)
                            ? "meetings.speakers.identify.refinesTiming"
                            : "meetings.diarization.identify"),
                        systemImage: "person.wave.2"
                    )
                }
            case .cloud:
                if hasSpeakerLabels {
                    Button(String(localized: "meetings.speakers.undo")) {
                        viewModel.clearSpeakerLabels(for: meeting)
                    }
                }
            case .none:
                EmptyView()
            }
        }
    }

    private var isWorking: Bool {
        viewModel.isEnriching(for: meeting)
    }

    // MARK: - Two-person toggle (D-A4)

    private var twoPersonToggle: some View {
        Toggle(isOn: Binding(
            get: { viewModel.isTwoPersonCall(meeting) },
            set: { viewModel.setTwoPersonCall($0, for: meeting) }
        )) {
            VStack(alignment: .leading, spacing: 2) {
                Text(String(localized: "meetings.speakers.twoPerson.title"))
                Text(String(localized: "meetings.speakers.twoPerson.subtitle"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .toggleStyle(.switch)
    }
}
