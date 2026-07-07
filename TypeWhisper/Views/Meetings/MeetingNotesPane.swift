import SwiftUI

/// In-meeting notes pane: a compose field plus the running list of notes, timestamped with the
/// elapsed capture time. Used inside `MeetingLiveCaptureView`.
struct MeetingNotesPane: View {
    @ObservedObject private var viewModel = MeetingsViewModel.shared
    let meeting: Meeting
    @State private var draft: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(String(localized: "meetings.detail.notes"))
                .font(.headline)

            HStack(spacing: 8) {
                TextField(String(localized: "meetings.notes.placeholder"), text: $draft, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...4)
                    .onSubmit(addNote)
                Button(String(localized: "meetings.notes.add"), action: addNote)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(meeting.notes.sorted { $0.createdAt < $1.createdAt }, id: \.id) { note in
                        HStack(alignment: .top, spacing: 8) {
                            if let offset = note.timestampOffset {
                                Text(MeetingTranscriptPanel.timestamp(offset))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                    .frame(width: 48, alignment: .leading)
                            }
                            Text(note.text)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
    }

    private func addNote() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        viewModel.addNote(text)
        draft = ""
    }
}
