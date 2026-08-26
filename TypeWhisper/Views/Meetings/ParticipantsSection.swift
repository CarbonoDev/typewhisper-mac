import SwiftUI

/// [M3-Participants] The in-document participants editor (plan M3), presented as a popover off the
/// meeting header's attendee chip. Lists the current roster with a per-row remove, and a type-to-add
/// field with ranked suggestions drawn from the participant directory ∪ the linked calendar event's
/// attendees ∪ a persistent "Create '<name>'" row.
///
/// Every mutation routes through `MeetingsViewModel` → the single-writer `MeetingService` attendee
/// choke points: adding folds the person into the directory, and **removing never deletes the backing
/// `Person`** (plan Part F #6). Display names are resolved at read time (plan D6), so a directory
/// rename is reflected here without ever rewriting the meeting's stored `attendeesJSON`.
struct ParticipantsSection: View {
    @ObservedObject private var viewModel = MeetingsViewModel.shared
    let meeting: Meeting

    @State private var draft = ""

    private var suggestions: [MeetingsViewModel.AttendeeSuggestion] {
        viewModel.attendeeSuggestions(for: meeting, query: draft)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(String(localized: "meetingdoc.participants.editor.title"))
                .font(.headline)

            if meeting.attendees.isEmpty {
                Text(String(localized: "meetingdoc.participants.editor.empty"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(meeting.attendees) { attendee in
                        attendeeRow(attendee)
                    }
                }
            }

            Divider()

            TextField(String(localized: "meetingdoc.participants.editor.add"), text: $draft)
                .textFieldStyle(.roundedBorder)
                .onSubmit(commitDraft)

            if !suggestions.isEmpty {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(suggestions) { suggestion in
                            suggestionRow(suggestion)
                        }
                    }
                }
                .frame(maxHeight: 200)
            }
        }
        .padding(16)
        .frame(width: 320)
    }

    // MARK: - Rows

    private func attendeeRow(_ attendee: Attendee) -> some View {
        HStack(spacing: 8) {
            Image(systemName: attendee.isSelf == true ? "person.crop.circle.badge.checkmark" : "person.crop.circle")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                // Display-time resolution (plan D6): a directory rename shows here without rewriting
                // the meeting's stored attendee snapshot.
                Text(viewModel.currentDisplayName(for: attendee))
                    .lineLimit(1)
                if let email = attendee.email, !email.isEmpty {
                    Text(email)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            // [Google Phase 1 · M5] Display-only rich attendee detail (spec §5 M5): an organizer
            // badge and a subtle RSVP glyph. Both degrade to nothing when the source (EventKit
            // pre-M5, manual entries) didn't carry them.
            if attendee.isOrganizer == true {
                Text(String(localized: "meetings.attendee.organizer"))
                    .font(.caption2)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.secondary.opacity(0.15), in: Capsule())
                    .foregroundStyle(.secondary)
            }
            if let status = attendee.responseStatus {
                Image(systemName: Self.rsvpGlyph(for: status))
                    .font(.caption)
                    .foregroundStyle(Self.rsvpTint(for: status))
                    .help(Self.rsvpHelp(for: status))
            }
            Spacer(minLength: 8)
            Button {
                viewModel.removeAttendee(attendee, from: meeting)
            } label: {
                Image(systemName: "minus.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(String(localized: "meetingdoc.participants.editor.remove.help"))
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func suggestionRow(_ suggestion: MeetingsViewModel.AttendeeSuggestion) -> some View {
        Button {
            add(suggestion)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: icon(for: suggestion.kind))
                    .foregroundStyle(.secondary)
                if suggestion.kind == .createNew {
                    Text(String(
                        format: String(localized: "meetingdoc.participants.editor.createNew"),
                        suggestion.name
                    ))
                    .lineLimit(1)
                } else {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(suggestion.name)
                            .lineLimit(1)
                        if let email = suggestion.email, !email.isEmpty {
                            Text(email)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
                Spacer(minLength: 8)
            }
            .contentShape(Rectangle())
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
    }

    private func icon(for kind: MeetingsViewModel.AttendeeSuggestion.Kind) -> String {
        switch kind {
        case .calendar: return "calendar"
        case .directory: return "person.crop.circle"
        case .createNew: return "plus.circle"
        }
    }

    // MARK: - [Google Phase 1 · M5] RSVP presentation (display-only)

    static func rsvpGlyph(for status: AttendeeResponseStatus) -> String {
        switch status {
        case .accepted: return "checkmark.circle"
        case .declined: return "xmark.circle"
        case .tentative: return "questionmark.circle"
        case .needsAction: return "circle.dotted"
        }
    }

    static func rsvpTint(for status: AttendeeResponseStatus) -> Color {
        switch status {
        case .accepted: return .green
        case .declined: return .red
        case .tentative: return .orange
        case .needsAction: return .secondary
        }
    }

    static func rsvpHelp(for status: AttendeeResponseStatus) -> String {
        switch status {
        case .accepted: return String(localized: "meetings.attendee.rsvp.accepted")
        case .declined: return String(localized: "meetings.attendee.rsvp.declined")
        case .tentative: return String(localized: "meetings.attendee.rsvp.tentative")
        case .needsAction: return String(localized: "meetings.attendee.rsvp.needsAction")
        }
    }

    // MARK: - Actions

    private func add(_ suggestion: MeetingsViewModel.AttendeeSuggestion) {
        viewModel.addSuggestedAttendee(suggestion, to: meeting)
        draft = ""
    }

    private func commitDraft() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // Prefer an exact-name suggestion (so a Return on a directory/calendar match attaches its email
        // + isSelf); otherwise create a fresh name-only participant.
        if let match = suggestions.first(where: {
            $0.kind != .createNew && $0.name.lowercased() == trimmed.lowercased()
        }) {
            viewModel.addSuggestedAttendee(match, to: meeting)
        } else {
            viewModel.addTypedAttendee(named: trimmed, to: meeting)
        }
        draft = ""
    }
}
