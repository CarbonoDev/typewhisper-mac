import Foundation

/// Which speaker-labeling source a *completed* meeting should use (speaker-recognition amendment,
/// D-A2/D-A3). A single strict precedence ladder — resolved by a pure function so the ladder is unit
/// tested without any audio — decides among:
///
///   **cloud labels (already on segments) > two-person channel path > local pyannote**
///
/// Cloud labels are the provider's own diarization tied to the real audio timeline (most accurate
/// when present); the channel path is deterministic physics (mic vs. system) and beats a statistical
/// model whenever it applies; pyannote is the general fallback.
enum SpeakerSource: Equatable {
    /// The transcript already carries provider (cloud) speaker labels — adopt them, skip local
    /// diarization entirely (D-A3).
    case cloud
    /// A two-person call whose recording is a genuinely separate mic/system track — label
    /// deterministically by channel with no detection and no sidecar (D-A4).
    case channel
    /// General local diarization via pyannote, hinted with the known participant count when available
    /// (D-A5). `nil` when the count is unknown (falls back to the global default inside the enricher).
    case pyannote(numSpeakers: Int?)
    /// Nothing to run: no transcript/audio, or a recording that is neither separate-track nor backed
    /// by a diarization sidecar.
    case none
}

/// The inputs the precedence resolver needs. All are derivable without decoding audio except
/// `trackAvailability`, which the enricher computes from a cheap header/prefix probe.
struct SpeakerSourceAvailability: Equatable {
    /// The meeting's transcript segments already carry at least one non-empty speaker label — the
    /// provider (cloud) labeled them on the final pass / import (D-A3, G4).
    var segmentsAlreadyLabeled: Bool
    /// Whether the "prefer provider speaker labels" meeting preference is on (D-A7). When off, cloud
    /// labels are not adopted and the ladder falls through to the channel/pyannote rungs.
    var preferProviderLabels: Bool
    /// Effective participant count: `attendees.count` when the meeting has attendees, else the
    /// additive two-person toggle (2 when set), else `nil` (unknown) — see
    /// `SpeakerSourcePlan.effectiveParticipantCount(for:)`.
    var effectiveParticipantCount: Int?
    /// What the recording supports for labeling: the offline separate-track heuristic, the pyannote
    /// sidecar, or neither.
    var trackAvailability: MeetingDiarizationEnricher.Availability
}

/// Pure precedence logic for meeting speaker labeling (D-A2). No audio, no I/O, no SwiftData mutation
/// — every decision is a function of `SpeakerSourceAvailability`, so the ladder is fully unit-testable.
enum SpeakerSourcePlan {
    /// Resolve the speaker source in strict precedence order (D-A2):
    /// cloud labels > two-person channel path > local pyannote > none.
    static func resolve(_ availability: SpeakerSourceAvailability) -> SpeakerSource {
        // 1) Cloud labels already present and preferred → adopt, skip local.
        if availability.segmentsAlreadyLabeled && availability.preferProviderLabels {
            return .cloud
        }
        // 2) Exactly two participants on a separate-track recording → deterministic channel labeling.
        if availability.effectiveParticipantCount == 2,
           availability.trackAvailability == .separateTrack {
            return .channel
        }
        // 3) A diarization path exists → pyannote, hinted with the participant count when known.
        switch availability.trackAvailability {
        case .separateTrack, .provider:
            return .pyannote(numSpeakers: availability.effectiveParticipantCount)
        case .unavailable:
            return .none
        }
    }

    /// Whether a stored speaker label originated from a cloud/provider's own diarization (D-A3), as
    /// opposed to a *local* label this app wrote itself. This is the single vocabulary test shared by
    /// the finalization adoption check (`MeetingDiarizationEnricher.hasProviderSpeakerLabels`) and the
    /// UI's planned-source resolution (`MeetingsViewModel.plannedSpeakerSource`), so a locally-labeled
    /// meeting can never be misreported as cloud-labeled:
    ///
    ///   - the two-person **channel** path writes `SPEAKER_ME` / `SPEAKER_OTHERS`
    ///     (`MeetingDiarizationEnricher.micSpeakerLabel` / `.systemSpeakerLabel`),
    ///   - local **pyannote** writes `SPEAKER_00`-style labels (`PyannoteDiarizationProvider`),
    ///   - **cloud** providers use their own vocabulary (e.g. AssemblyAI's "Speaker A"/"Speaker B").
    ///
    /// A label is provider-originated iff it is non-empty and is neither a channel label nor a
    /// `SPEAKER_`-prefixed local label. (The `SPEAKER_` prefix already covers both channel labels; the
    /// explicit equality checks keep the intent readable and robust to a future channel-label rename.)
    static func isProviderOriginatedLabel(_ label: String?) -> Bool {
        guard let trimmed = label?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return false
        }
        if trimmed == MeetingDiarizationEnricher.micSpeakerLabel
            || trimmed == MeetingDiarizationEnricher.systemSpeakerLabel {
            return false
        }
        return !trimmed.hasPrefix("SPEAKER_")
    }

    /// The effective participant count for a meeting (D-A4): the calendar attendee count when the
    /// meeting has attendees, else the additive two-person toggle (`2` when `twoPersonCall == true`),
    /// else `nil` (unknown — the two-person fast path is not eligible).
    static func effectiveParticipantCount(for meeting: Meeting) -> Int? {
        if !meeting.attendees.isEmpty { return meeting.attendees.count }
        if meeting.twoPersonCall == true { return 2 }
        return nil
    }

    /// The name to give `SPEAKER_OTHERS` on the two-person channel path (D-A8): the single attendee
    /// who is not the current user, when it can be identified from `Attendee.isSelf`. `nil` when self
    /// is indeterminate or there is not exactly one non-self attendee — the caller then falls back to
    /// the localized "Them".
    static func otherPartyName(for meeting: Meeting) -> String? {
        let others = meeting.attendees.filter { $0.isSelf != true }
        guard others.count == 1 else { return nil }
        let name = others[0].name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }
}
