import SwiftUI

/// In-meeting Q&A chat pane (plan M6): the running log of question/answer turns for a meeting plus
/// a composer to ask a new question against the transcript-so-far and the connected knowledge base.
/// Embedded in `MeetingLiveCaptureView` (during capture) and `MeetingDetailView` (after).
struct MeetingQAView: View {
    @ObservedObject private var viewModel = MeetingsViewModel.shared
    let meeting: Meeting
    @State private var draft: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(String(localized: "meetings.qa.sectionTitle"))
                .font(.headline)

            let turns = meeting.qaTurns.sorted { $0.createdAt < $1.createdAt }
            if turns.isEmpty {
                Text(String(localized: "meetings.qa.empty"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(turns, id: \.id) { turn in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(turn.question)
                            .font(.subheadline.weight(.semibold))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(turn.answer)
                            .font(.body)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(10)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
                }
            }

            if let error = viewModel.qaErrorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            composer
        }
    }

    private var composer: some View {
        HStack(spacing: 8) {
            TextField(String(localized: "meetings.qa.placeholder"), text: $draft, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...4)
                .onSubmit(submit)
                .disabled(viewModel.isAnswering)
            if viewModel.isAnswering {
                ProgressView()
                    .controlSize(.small)
            } else {
                Button(String(localized: "meetings.qa.ask"), action: submit)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private func submit() {
        let question = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !viewModel.isAnswering else { return }
        draft = ""
        // Restore the typed question if the call fails (network error, provider misconfigured) so the
        // user can retry without retyping it (M6 review finding 4).
        Task {
            let succeeded = await viewModel.askQuestion(question, for: meeting)
            if !succeeded, draft.isEmpty { draft = question }
        }
    }
}
