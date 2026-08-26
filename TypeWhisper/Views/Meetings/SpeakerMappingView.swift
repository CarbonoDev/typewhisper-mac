import SwiftUI

/// Editor that maps diarization `SPEAKER_xx` labels to real attendee names (plan M9). The mapping
/// persists to `Meeting.speakerMapJSON`; mapped names then render in the transcript, exports, and
/// LLM context. Rendered as a section inside `MeetingDetailView`; shown only once the meeting's
/// transcript carries at least one speaker label.
struct SpeakerMappingView: View {
    @ObservedObject private var viewModel = MeetingsViewModel.shared
    let meeting: Meeting

    /// Working copy of `label → name`, committed on Save so typing is not persisted per keystroke.
    @State private var names: [String: String] = [:]

    private var labels: [String] { viewModel.speakerLabels(in: meeting) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(String(localized: "meetings.diarization.mapping.title"))
                .font(.headline)

            if labels.isEmpty {
                Text(String(localized: "meetings.diarization.mapping.empty"))
                    .foregroundStyle(.secondary)
            } else {
                Text(String(localized: "meetings.diarization.mapping.hint"))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                ForEach(labels, id: \.self) { label in
                    row(for: label)
                }

                Button(String(localized: "meetings.diarization.mapping.save")) {
                    viewModel.setSpeakerMap(names, for: meeting)
                }
                .disabled(Self.cleaned(names) == meeting.speakerMap)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { names = meeting.speakerMap }
        // Re-sync when the persisted map changes underneath the editor (e.g. re-running speaker
        // identification seeds Me/Others names, or a Save drops emptied fields) so stale local
        // fields never write back over freshly-persisted names.
        .onChange(of: meeting.speakerMapJSON) { names = meeting.speakerMap }
    }

    /// Normalize the working copy the same way `MeetingService.setSpeakerMap` persists it (trim
    /// whitespace, drop empties) so the Save button reflects whether a real change is pending —
    /// a field typed-then-cleared, or a no-op re-save, leaves nothing to write.
    private static func cleaned(_ map: [String: String]) -> [String: String] {
        map.reduce(into: [String: String]()) { result, pair in
            let name = pair.value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty { result[pair.key] = name }
        }
    }

    @ViewBuilder
    private func row(for label: String) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.callout.monospaced())
                .foregroundStyle(.secondary)
                .frame(width: 150, alignment: .leading)

            TextField(
                String(localized: "meetings.diarization.mapping.namePlaceholder"),
                text: binding(for: label)
            )
            .textFieldStyle(.roundedBorder)

            let suggestions = viewModel.attendeeNameSuggestions(for: meeting)
            if !suggestions.isEmpty {
                Menu {
                    ForEach(suggestions, id: \.self) { suggestion in
                        Button(suggestion) { names[label] = suggestion }
                    }
                } label: {
                    Image(systemName: "person.crop.circle.badge.plus")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help(String(localized: "meetings.diarization.mapping.suggestAttendee"))
            }
        }
    }

    private func binding(for label: String) -> Binding<String> {
        Binding(
            get: { names[label] ?? "" },
            set: { names[label] = $0 }
        )
    }
}
