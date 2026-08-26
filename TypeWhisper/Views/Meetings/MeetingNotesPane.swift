import SwiftUI

/// [Sprint 1] In-meeting notes — the live page's hero: the composer pinned on top, then the
/// running list newest-first with manuscript-margin timestamps. The page (outer ScrollView) owns
/// scrolling; this pane lays out its full height.
struct MeetingNotesPane: View {
    @ObservedObject private var viewModel = MeetingsViewModel.shared
    let meeting: Meeting
    @State private var draft: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: MeetingTheme.s3) {
            MeetingSectionLabel(String(localized: "meetings.detail.notes"))

            HStack(spacing: MeetingTheme.s2) {
                TextField(String(localized: "meetings.notes.placeholder"), text: $draft, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...4)
                    .onSubmit(addNote)
                Button(String(localized: "meetings.notes.add"), action: addNote)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            VStack(alignment: .leading, spacing: MeetingTheme.s2) {
                ForEach(meeting.notes.sorted { $0.createdAt > $1.createdAt }, id: \.id) { note in
                    HStack(alignment: .firstTextBaseline, spacing: MeetingTheme.s2) {
                        if let offset = note.timestampOffset {
                            Text(MeetingTranscriptPanel.timestamp(offset))
                                .font(MeetingTheme.mono)
                                .foregroundStyle(.secondary)
                                .frame(width: 56, alignment: .leading)
                        }
                        Text(note.text)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private func addNote() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        viewModel.addNote(text)
        draft = ""
    }
}
