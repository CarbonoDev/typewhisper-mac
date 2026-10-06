import Foundation

/// Transcript facts a row, the Home timeline, or the document header shows for one meeting.
struct MeetingTranscriptFacts: Equatable, Sendable {
    var segmentCount: Int
    /// Largest segment `end` in seconds; `0` with no transcript.
    var transcriptEnd: Double
    /// Distinct trimmed, non-blank speaker labels.
    var speakerLabels: Set<String>

    static let empty = MeetingTranscriptFacts(segmentCount: 0, transcriptEnd: 0, speakerLabels: [])

    var hasTranscript: Bool { segmentCount > 0 }
    /// The transcript's length, or nil when no segment has a positive end.
    var transcriptDuration: Double? { transcriptEnd > 0 ? transcriptEnd : nil }
    var speakerCount: Int { speakerLabels.count }

    /// A change token over the distinct speaker labels (sorted), for views that re-resolve
    /// something when the label set changes.
    var speakerLabelsFingerprint: String { speakerLabels.sorted().joined(separator: "\u{1f}") }

    /// Whether any label came from a cloud provider rather than the app's own diarization
    /// (`SpeakerSourcePlan.isProviderOriginatedLabel`).
    var hasProviderOriginatedLabels: Bool {
        speakerLabels.contains { SpeakerSourcePlan.isProviderOriginatedLabel($0) }
    }

    /// The facts after appending `segments` (the live-append path keeps them incrementally).
    func appending<S: Sequence>(_ segments: S) -> MeetingTranscriptFacts where S.Element == MeetingSegment {
        var next = self
        for segment in segments { next.add(end: segment.end, speakerLabel: segment.speakerLabel) }
        return next
    }

    /// Fold one segment in.
    mutating func add(end: Double, speakerLabel: String?) {
        segmentCount += 1
        transcriptEnd = max(transcriptEnd, end)
        if let label = Self.normalizedLabel(speakerLabel) { speakerLabels.insert(label) }
    }

    static func normalizedLabel(_ label: String?) -> String? {
        guard let trimmed = label?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}

/// Read API for the denormalised fact columns (perf plan Phase 2). Readers use `transcriptFacts`,
/// `outputKinds`, `hasTranscript`, and `hasContent`; only `MeetingService` writes the columns.
///
/// The relationships stay the source of truth. A column is trusted only when it claims content:
/// a `nil` column (not backfilled yet) or one that claims "nothing here" is confirmed against the
/// relationship — cheap, because an empty to-many faults nothing — so a transcript or an output is
/// never reported missing because of a stale or missing column. Drift in a positive claim (a count
/// that is too low) is healed by `MeetingService.reconcileFacts`, which compares against the store.
extension Meeting {
    var transcriptFacts: MeetingTranscriptFacts {
        if let stored = storedTranscriptFacts, stored.hasTranscript { return stored }
        return computedTranscriptFacts()
    }

    var outputKinds: Set<MeetingOutputKind> {
        if let stored = storedOutputKinds, !stored.isEmpty { return stored }
        return computedOutputKinds()
    }

    var hasTranscript: Bool { transcriptFacts.hasTranscript }

    /// A transcript or a generated output other than the pre-meeting brief (see
    /// `MeetingsViewModel.documentHasContent`).
    var hasContent: Bool {
        hasTranscript || outputKinds.contains { $0 != .brief }
    }

    // MARK: - Stored columns

    /// The stored transcript facts, or nil while any transcript column is still unset.
    var storedTranscriptFacts: MeetingTranscriptFacts? {
        guard let count = factSegmentCount, let end = factTranscriptEnd, let labels = factSpeakerLabelsRaw else {
            return nil
        }
        return MeetingTranscriptFacts(
            segmentCount: count,
            transcriptEnd: end,
            speakerLabels: Set(labels.split(separator: "\n").map(String.init))
        )
    }

    /// The stored output kinds, or nil while the column is unset. Unknown raw values are dropped.
    var storedOutputKinds: Set<MeetingOutputKind>? {
        guard let raw = factOutputKindsRaw else { return nil }
        return Set(raw.split(separator: ",").compactMap { MeetingOutputKind(rawValue: String($0)) })
    }

    var hasStoredFacts: Bool { storedTranscriptFacts != nil && factOutputKindsRaw != nil }

    func storeTranscriptFacts(_ facts: MeetingTranscriptFacts) {
        if factSegmentCount != facts.segmentCount { factSegmentCount = facts.segmentCount }
        if factTranscriptEnd != facts.transcriptEnd { factTranscriptEnd = facts.transcriptEnd }
        let labels = facts.speakerLabels.sorted().joined(separator: "\n")
        if factSpeakerLabelsRaw != labels { factSpeakerLabelsRaw = labels }
    }

    func storeOutputKinds(_ kinds: Set<MeetingOutputKind>) {
        let raw = kinds.map(\.rawValue).sorted().joined(separator: ",")
        if factOutputKindsRaw != raw { factOutputKindsRaw = raw }
    }

    // MARK: - From the relationships (authoritative)

    func computedTranscriptFacts() -> MeetingTranscriptFacts {
        MeetingTranscriptFacts.empty.appending(segments.lazy.filter { !$0.isDeleted && !$0.isDeletedFromStore })
    }

    func computedOutputKinds() -> Set<MeetingOutputKind> {
        Set(outputs.lazy.filter { !$0.isDeleted && !$0.isDeletedFromStore }.map(\.kind))
    }
}
