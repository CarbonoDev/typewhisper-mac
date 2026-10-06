import SwiftUI

/// [Track B] The single-meeting lifecycle document (plan D4). Replaces the Step 0 placeholder
/// wholesale. One state-switched screen — scheduled → live → stopped/completed — composed of:
/// a serif header + chip row (`MeetingDocumentHeader`), a state-switched body
/// (`MeetingDocumentBody`), a floating bottom bar with the Start/Stop/Resume/Generate state machine
/// (`MeetingBottomBar`), and a slide-in transcript panel (`MeetingTranscriptPanel`).
///
/// Frozen contract (D4): `MeetingDocumentView(meeting:)`. All cross-navigation flows through
/// `MainWindowCoordinator.shared`; there is no `onBack` closure.
struct MeetingDocumentView: View {
    /// [VM split] Only `documentPresentation(for:)` is read, which derives from capture state:
    /// observe the capture slice, not the whole view model.
    private var viewModel: MeetingsViewModel { .shared }
    @ObservedObject private var capture = MeetingsViewModel.shared.capture
    @StateObject private var model = MeetingDocumentModel()
    let meeting: Meeting

    /// Resolved from `DocumentFacts` (denormalised columns, no segment walk). Read ONCE per body pass
    /// (bound via `let` in `body`) and threaded to the header / body / bottom bar.
    private var presentation: MeetingsViewModel.DocumentPresentation {
        viewModel.documentPresentation(for: meeting, hasContent: model.facts(for: meeting).hasContent)
    }

    var body: some View {
        let presentation = self.presentation
        HStack(spacing: 0) {
            documentColumn(presentation)
            if model.isTranscriptPanelOpen {
                Divider()
                MeetingTranscriptPanel(model: model, meeting: meeting)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: model.isTranscriptPanelOpen)
        // [Sprint 4] The window names the meeting (clean title for imported exports), not the app.
        .navigationTitle(ImportedMeetingTitle.displayTitle(for: meeting.title))
        .onAppear { applyPanelDefault() }
        .onChange(of: meeting.id) { _, _ in
            // Switching to a different meeting: reset per-document UI state and re-apply defaults.
            model.resetForMeetingSwitch()
            applyPanelDefault()
        }
        .onChange(of: presentation.transcriptPanelOpenByDefault) { _, _ in applyPanelDefault() }
        .sheet(isPresented: $model.isPresentingImport) {
            MeetingImportView(mergeTarget: meeting) { imported in
                MainWindowCoordinator.shared.openMeeting(id: imported.id)
            }
        }
        .sheet(isPresented: $model.isPresentingExport) {
            exportSheet
        }
        .sheet(isPresented: $model.isPresentingLinkEvent) {
            MeetingLinkEventView(meeting: meeting, isPresented: $model.isPresentingLinkEvent)
        }
    }

    private func documentColumn(_ presentation: MeetingsViewModel.DocumentPresentation) -> some View {
        ScrollView {
            // [Sprint 1] The document reads in a centered, measure-limited column — a page, not a
            // form (MeetingTheme.contentMaxWidth).
            VStack(alignment: .leading, spacing: MeetingTheme.sectionGap) {
                MeetingDocumentHeader(model: model, meeting: meeting, presentation: presentation)
                MeetingDocumentBody(model: model, meeting: meeting, presentation: presentation)
            }
            .frame(maxWidth: MeetingTheme.contentMaxWidth, alignment: .topLeading)
            .padding(MeetingTheme.pagePadding)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // [Sprint 4] The document reads on faint warm paper in light mode (MeetingTheme).
        .background(MeetingTheme.paperBackground)
        .safeAreaInset(edge: .bottom) {
            MeetingBottomBar(model: model, meeting: meeting, presentation: presentation)
        }
    }

    private var exportSheet: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(String(localized: "meetingdoc.export.title"))
                    .font(.headline)
                Spacer()
                Button(String(localized: "meetingdoc.export.done")) { model.isPresentingExport = false }
            }
            .padding()
            Divider()
            ScrollView {
                MeetingExportView(meeting: meeting)
                    .id(meeting.id)
                    .padding()
            }
        }
        .frame(width: 460, height: 520)
    }

    private func applyPanelDefault() {
        // Apply the "open by default while live" rule once per meeting so the user can still
        // minimize it without it snapping back open on the next state tick. The applied marker is
        // recorded ONLY when the default actually fires (i.e. the panel is opened) — otherwise a
        // scheduled meeting (default = false) would consume the guard on appear, and the later
        // scheduled→live flip (Start pressed) would be swallowed and never open the panel.
        guard model.appliedPanelDefaultForMeetingID != meeting.id else { return }
        guard presentation.transcriptPanelOpenByDefault else { return }
        model.appliedPanelDefaultForMeetingID = meeting.id
        model.isTranscriptPanelOpen = true
    }
}

/// [Track B] View-owned UI state for the meeting document (plan D5: stored document state lives in a
/// track-owned `ObservableObject`, never in the frozen `MeetingsViewModel`). Instantiated per
/// document via `@StateObject`.
@MainActor
final class MeetingDocumentModel: ObservableObject {
    /// The side panel's tab: the transcript or the Q&A history (Sprint 1 — Q&A moved off the page
    /// into the panel so answers never push the document around).
    enum PanelTab: Hashable {
        case transcript
        case qa
    }

    /// The output kind currently rendered in the body (Summary / Extended / Brief).
    @Published var selectedOutputKind: MeetingOutputKind = .summary
    @Published var isTranscriptPanelOpen = false
    @Published var panelTab: PanelTab = .transcript
    // The ask draft and transcript search live in leaf `@State` (`MeetingBottomBar` /
    // `MeetingTranscriptPanel`) so a keystroke never re-renders the whole document.
    @Published var isPresentingImport = false
    @Published var isPresentingExport = false
    /// The "Link to calendar event…" picker sheet (requirement 3).
    @Published var isPresentingLinkEvent = false

    /// The meeting id the panel-open default was last applied for (prevents re-forcing the panel
    /// open after the user minimizes it).
    var appliedPanelDefaultForMeetingID: UUID?

    func resetForMeetingSwitch() {
        selectedOutputKind = .summary
        isTranscriptPanelOpen = false
        panelTab = .transcript
        isPresentingLinkEvent = false
        appliedPanelDefaultForMeetingID = nil
    }

    // MARK: - Per-render facts

    /// Transcript-derived facts the header / body / presentation read on every body pass. Read from
    /// the denormalised columns on `Meeting` (perf plan Phase 2, `Meeting+Facts.swift`), so no body
    /// pass walks or faults `meeting.segments`; this replaced a per-document memo of three segment
    /// walks keyed by `(id, updatedAt, segments.count)`.
    struct DocumentFacts: Equatable {
        let segmentCount: Int
        /// Max segment end in seconds, or nil when there is no positive end (no transcript).
        let transcriptDuration: Double?
        /// Distinct non-blank speaker labels across the transcript.
        let speakerCount: Int
        /// `MeetingsViewModel.documentHasContent` (a transcript or a non-brief output).
        let hasContent: Bool

        init(meeting: Meeting) {
            let transcript = meeting.transcriptFacts
            segmentCount = transcript.segmentCount
            transcriptDuration = transcript.transcriptDuration
            speakerCount = transcript.speakerCount
            hasContent = transcript.hasTranscript || meeting.outputKinds.contains { $0 != .brief }
        }
    }

    func facts(for meeting: Meeting) -> DocumentFacts {
        DocumentFacts(meeting: meeting)
    }
}
