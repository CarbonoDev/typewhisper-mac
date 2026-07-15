import Foundation

/// [Track B] Pure, view-model-adjacent logic for the single-meeting document (plan D4, D5).
///
/// `MeetingsViewModel.swift` is frozen (D5): this extension adds only pure / derived members and
/// small value types. All *stored* document UI state (selected output, panel visibility, search
/// text, drafts) lives in the view-owned `MeetingDocumentModel`, never here.
extension MeetingsViewModel {

    // MARK: - Lifecycle state machine (D4)

    /// The body rendering mode of the meeting document.
    enum DocumentBodyMode: Equatable {
        /// Scheduled with nothing captured yet → serif header, chips, primary Start, pre-meeting brief.
        case scheduledEmpty
        /// Actively capturing this meeting → editable, timeline-stamped notes.
        case liveNotes
        /// Resting with content → the selected output rendered as markdown.
        case renderedOutput
    }

    /// The primary context action offered by the floating bottom bar (the state machine's verb).
    enum DocumentContextAction: Equatable {
        case start              // scheduled / empty → begin capture
        case stop               // live → finalize capture
        case finalizing         // stop pressed, teardown off-main in flight → disabled "Finalizing…"
        case resumeAndGenerate  // stopped-with-content → resume capture (restart-safe) + Generate ▾
        case generate           // completed → Generate ▾ only
    }

    /// The fully-resolved presentation of a meeting document — the single source the header, body,
    /// and bottom bar all read. Kept pure + `Equatable` so the whole state machine is unit-testable
    /// (`MeetingDocumentStateTests`) without SwiftUI or a live capture.
    struct DocumentPresentation: Equatable {
        var bodyMode: DocumentBodyMode
        var contextAction: DocumentContextAction
        var showsLiveChip: Bool
        var transcriptPanelOpenByDefault: Bool
    }

    /// Pure map `(state × isCapturingThisMeeting × hasContent) → presentation` (D4). Priority:
    /// live wins; then scheduled offers Start; a completed meeting only regenerates; any other
    /// resting state that carries content can be resumed (capture `start()` is restart-safe via
    /// `sessionTimeOffset`), otherwise it falls back to the empty/Start affordance.
    nonisolated static func documentPresentation(
        state: MeetingState,
        isCapturingThisMeeting: Bool,
        hasContent: Bool,
        isFinalizingThisMeeting: Bool = false
    ) -> DocumentPresentation {
        if isCapturingThisMeeting {
            return DocumentPresentation(
                bodyMode: .liveNotes,
                contextAction: .stop,
                showsLiveChip: true,
                transcriptPanelOpenByDefault: true
            )
        }
        // Stop pressed: `isCapturing` is already false but the heavy teardown (buffer snapshot,
        // recorder mixdown, audio adopt) is still running off the MainActor. Keep the live posture —
        // a disabled "Finalizing…" bar and the live chip — instead of briefly flashing the resting
        // resume/generate affordances the meeting will only earn once the final pass has run.
        if isFinalizingThisMeeting {
            return DocumentPresentation(
                bodyMode: .liveNotes,
                contextAction: .finalizing,
                showsLiveChip: true,
                transcriptPanelOpenByDefault: true
            )
        }
        switch state {
        case .scheduled:
            return DocumentPresentation(
                bodyMode: hasContent ? .renderedOutput : .scheduledEmpty,
                contextAction: .start,
                showsLiveChip: false,
                transcriptPanelOpenByDefault: false
            )
        case .completed:
            return DocumentPresentation(
                bodyMode: hasContent ? .renderedOutput : .scheduledEmpty,
                contextAction: hasContent ? .generate : .start,
                showsLiveChip: false,
                transcriptPanelOpenByDefault: false
            )
        case .live, .interrupted, .processing, .failed:
            return DocumentPresentation(
                bodyMode: hasContent ? .renderedOutput : .scheduledEmpty,
                contextAction: hasContent ? .resumeAndGenerate : .start,
                showsLiveChip: false,
                transcriptPanelOpenByDefault: false
            )
        }
    }

    /// Whether a meeting has anything worth rendering as a document body (a transcript or a
    /// generated output). Notes alone don't count — they are shown live, folded into outputs.
    nonisolated static func documentHasContent(_ meeting: Meeting) -> Bool {
        !meeting.segments.isEmpty || !meeting.outputs.isEmpty
    }

    // MARK: - Import / merge affordance (merge-import default fix)

    /// Which posture the import sheet presents. With a merge target the sheet leads with *merging*
    /// the chosen transcript into that meeting (the natural, non-duplicating action); without one
    /// (the list toolbar) it leads with *creating* a new meeting. Pure + `Equatable` so the posture
    /// is unit-testable without SwiftUI (`MeetingImportSheetModeTests`).
    enum ImportSheetMode: Equatable {
        /// No merge target — the list-toolbar posture: create a new meeting from a file.
        case createPrimary
        /// A merge target — merging into `meetingTitle` is the primary action; create-new is demoted.
        case mergePrimary(meetingTitle: String)
    }

    /// Resolve the import sheet's posture from the presence of a merge target's title.
    nonisolated static func importSheetMode(mergeTargetTitle: String?) -> ImportSheetMode {
        guard let title = mergeTargetTitle else { return .createPrimary }
        return .mergePrimary(meetingTitle: title)
    }

    /// Whether the document surfaces an "import transcript into this meeting" action (requirement 1).
    /// Reachable on any resting meeting that already has a transcript or is `.completed`; suppressed
    /// while *this* meeting is actively capturing (a merge rewrites all segments and must never race
    /// the live capture writer). Pure so reachability — including for completed meetings — is
    /// unit-testable (`MeetingImportSheetModeTests`).
    nonisolated static func showsImportMergeAction(
        state: MeetingState,
        isCapturingThisMeeting: Bool,
        hasTranscript: Bool
    ) -> Bool {
        guard !isCapturingThisMeeting else { return false }
        return hasTranscript || state == .completed
    }

    /// Live-state convenience for the header: whether to show the import/merge chip for `meeting`.
    func showsImportMergeAction(for meeting: Meeting) -> Bool {
        Self.showsImportMergeAction(
            state: meeting.state,
            isCapturingThisMeeting: isCapturing && activeMeeting?.id == meeting.id,
            hasTranscript: !meeting.segments.isEmpty
        )
    }

    /// Resolve the live presentation for a meeting from current published capture state.
    func documentPresentation(for meeting: Meeting) -> DocumentPresentation {
        Self.documentPresentation(
            state: meeting.state,
            isCapturingThisMeeting: isCapturing && activeMeeting?.id == meeting.id,
            hasContent: Self.documentHasContent(meeting),
            isFinalizingThisMeeting: isFinalizing && activeMeeting?.id == meeting.id
        )
    }

    /// Resume capturing a stopped meeting — the same `startCapture` path (restart-safe: the capture
    /// service offsets new segments past the prior transcript's max end). Distinct wrapper so the
    /// document's "Resume" verb reads clearly at the call site.
    func resumeCapture(for meeting: Meeting) async {
        await startCapture(for: meeting)
    }

    // MARK: - Output selection (chip row)

    /// The output kinds offered by the document's output selector, in display order.
    nonisolated static var selectableOutputKinds: [MeetingOutputKind] { [.summary, .extended, .brief] }

    /// Localized label for an output kind (the chip title and selector rows).
    nonisolated static func outputKindLabel(_ kind: MeetingOutputKind) -> String {
        switch kind {
        case .summary: return String(localized: "meetingdoc.output.kind.summary")
        case .extended: return String(localized: "meetingdoc.output.kind.extended")
        case .brief: return String(localized: "meetingdoc.output.kind.brief")
        }
    }

    // MARK: - Transcript panel model (D4)

    /// One rendered entry in the transcript panel: a speaker bubble, or a time-gap separator.
    struct TranscriptBubble: Identifiable, Equatable {
        enum Kind: Equatable {
            case speech
            /// A timestamp marker inserted where a silence gap separates two segments.
            case gap
        }
        /// Deterministic, order-stable identity derived from the adjacent segment (`speech-<uuid>` /
        /// `gap-<uuid>`) so `bubbles` recomputation on every live tick keeps identity and the
        /// `LazyVStack` rows don't tear down/rebuild (which jittered scroll anchoring at gaps).
        let id: String
        let kind: Kind
        /// Raw `SPEAKER_xx` label, or nil when the segment is unlabeled.
        let speakerLabel: String?
        /// Display name resolved through the meeting's speaker map (falls back to the raw label).
        let displayName: String?
        /// The segment is the user's own microphone (`SPEAKER_ME`) — rendered right-aligned as "(Me)".
        let isMe: Bool
        let text: String
        let start: Double
        /// `mm:ss` timestamp string for the entry (the gap marker's separator, or a speech start).
        let timestamp: String
        /// The segment came from an imported/merged source, not live capture — carries a source tag.
        let isImported: Bool
    }

    /// Default silence gap (seconds) that triggers a timestamp separator in the transcript panel.
    nonisolated static let transcriptGapThreshold: Double = 30

    /// Build the transcript panel's entries from a meeting's segments (D4): speaker-attributed
    /// bubbles with mapped names, `SPEAKER_ME` → "(Me)" right-alignment, source tags on imported
    /// segments, and a timestamp separator inserted wherever a silence of at least `gapThreshold`
    /// seconds separates two consecutive segments. Pure + order-stable so it is unit-testable
    /// (`TranscriptBubbleModelTests`) without SwiftUI.
    ///
    /// `suppressSpeakers` (speaker-recognition amendment, Fix A) forces every bubble to render with no
    /// speaker attribution (`speakerLabel: nil, displayName: nil, isMe: false`) regardless of what the
    /// segments carry. The panel passes `true` while **this** meeting is capturing, which is the single
    /// render choke point that guarantees the live transcript never shows a speaker — even for a
    /// resumed/restarted meeting whose preserved segments still carry labels from an earlier pass
    /// (the "labels appeared randomly live" defect). Independent of any writer.
    nonisolated static func transcriptBubbles(
        segments: [MeetingSegment],
        speakerMap: [String: String],
        gapThreshold: Double = transcriptGapThreshold,
        suppressSpeakers: Bool = false
    ) -> [TranscriptBubble] {
        // Read the SwiftData-persisted `.order` once per segment (each access faults the property)
        // instead of on every comparison during the sort — this runs inside `body` on every publish.
        let ordered = segments
            .map { (segment: $0, order: $0.order) }
            .sorted { $0.order < $1.order }
            .map(\.segment)
        var bubbles: [TranscriptBubble] = []
        var previousEnd: Double?

        for segment in ordered {
            if let previousEnd, segment.start - previousEnd >= gapThreshold {
                bubbles.append(
                    TranscriptBubble(
                        id: "gap-\(segment.id.uuidString)",
                        kind: .gap,
                        speakerLabel: nil,
                        displayName: nil,
                        isMe: false,
                        text: "",
                        start: segment.start,
                        timestamp: MeetingTranscriptPanel.timestamp(segment.start),
                        isImported: false
                    )
                )
            }
            let label = suppressSpeakers ? nil : segment.speakerLabel?.trimmingCharacters(in: .whitespacesAndNewlines)
            let isMe = (label == MeetingDiarizationEnricher.micSpeakerLabel)
            bubbles.append(
                TranscriptBubble(
                    id: "speech-\(segment.id.uuidString)",
                    kind: .speech,
                    speakerLabel: (label?.isEmpty == false) ? label : nil,
                    displayName: suppressSpeakers ? nil : MeetingTranscriptPanel.speakerName(for: segment, speakerMap: speakerMap),
                    isMe: isMe,
                    text: segment.text,
                    start: segment.start,
                    timestamp: MeetingTranscriptPanel.timestamp(segment.start),
                    isImported: segment.source != .liveCapture
                )
            )
            previousEnd = segment.end
        }
        return bubbles
    }

    /// Client-side transcript search: keep speech bubbles whose text or resolved speaker name
    /// contains `query` (case-insensitive); gap separators are dropped while filtering. An empty
    /// query returns the input unchanged.
    nonisolated static func filterTranscriptBubbles(_ bubbles: [TranscriptBubble], query: String) -> [TranscriptBubble] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return bubbles }
        return bubbles.filter { bubble in
            guard bubble.kind == .speech else { return false }
            if bubble.text.lowercased().contains(needle) { return true }
            if let name = bubble.displayName?.lowercased(), name.contains(needle) { return true }
            return false
        }
    }
}
