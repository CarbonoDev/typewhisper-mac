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
    @ObservedObject private var viewModel = MeetingsViewModel.shared
    @StateObject private var model = MeetingDocumentModel()
    let meeting: Meeting

    private var presentation: MeetingsViewModel.DocumentPresentation {
        viewModel.documentPresentation(for: meeting)
    }

    var body: some View {
        HStack(spacing: 0) {
            documentColumn
            if model.isTranscriptPanelOpen {
                Divider()
                MeetingTranscriptPanel(model: model, meeting: meeting)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: model.isTranscriptPanelOpen)
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
    }

    private var documentColumn: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                MeetingDocumentHeader(model: model, meeting: meeting, presentation: presentation)
                MeetingDocumentBody(model: model, meeting: meeting, presentation: presentation)
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
    /// The output kind currently rendered in the body (Summary / Extended / Brief).
    @Published var selectedOutputKind: MeetingOutputKind = .summary
    @Published var isTranscriptPanelOpen = false
    @Published var transcriptSearch = ""
    @Published var noteDraft = ""
    @Published var askDraft = ""
    @Published var isPresentingImport = false
    @Published var isPresentingExport = false

    /// The meeting id the panel-open default was last applied for (prevents re-forcing the panel
    /// open after the user minimizes it).
    var appliedPanelDefaultForMeetingID: UUID?

    func resetForMeetingSwitch() {
        selectedOutputKind = .summary
        isTranscriptPanelOpen = false
        transcriptSearch = ""
        noteDraft = ""
        askDraft = ""
        appliedPanelDefaultForMeetingID = nil
    }
}
