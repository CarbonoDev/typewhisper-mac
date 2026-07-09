import SwiftUI

/// The "Link to calendar event…" picker sheet (meeting-identity milestone, requirement 3). Lists
/// historical calendar events within a search window around the meeting's date, ranked by title
/// similarity + date proximity, with search-as-you-type and an adjustable window. Picking a row
/// links the meeting to that event (adopting its id/series/attendees and start date, without
/// clobbering a user title). This powers the owner's bulk archive import: old imported meetings get
/// matched back to their historical events so prior-meeting briefs can see them.
struct MeetingLinkEventView: View {
    @ObservedObject private var viewModel = MeetingsViewModel.shared
    let meeting: Meeting
    @Binding var isPresented: Bool

    @State private var query = ""
    /// Half-window in days (± around the meeting's date). Adjustable per the spec.
    @State private var windowDays: Double = 7

    private var window: TimeInterval { windowDays * 24 * 60 * 60 }

    private var candidates: [CalendarEventDTO] {
        viewModel.linkCandidates(for: meeting, query: query, window: window)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if viewModel.isCalendarAuthorized {
                content
            } else {
                accessDenied
            }
        }
        .frame(width: 480, height: 560)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(String(localized: "meetingdoc.link.picker.title"))
                    .font(.headline)
                Spacer()
                Button(String(localized: "meetingdoc.link.picker.close")) { isPresented = false }
            }
            TextField(String(localized: "meetingdoc.link.picker.search"), text: $query)
                .textFieldStyle(.roundedBorder)
            windowControl
        }
        .padding()
    }

    private var windowControl: some View {
        HStack(spacing: 8) {
            Image(systemName: "calendar.badge.clock")
                .foregroundStyle(.secondary)
            Text(String(localized: "meetingdoc.link.picker.window"))
                .font(.callout)
                .foregroundStyle(.secondary)
            Stepper(
                value: $windowDays,
                in: 1...90,
                step: 1
            ) {
                Text(String(format: String(localized: "meetingdoc.link.picker.windowDays"), Int(windowDays)))
                    .font(.callout.monospacedDigit())
            }
            .fixedSize()
        }
    }

    @ViewBuilder
    private var content: some View {
        let rows = candidates
        if rows.isEmpty {
            ContentUnavailableView {
                Label(String(localized: "meetingdoc.link.picker.empty.title"), systemImage: "calendar.badge.exclamationmark")
            } description: {
                Text(String(localized: "meetingdoc.link.picker.empty.message"))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(rows) { event in
                        candidateRow(event)
                    }
                }
                .padding()
            }
        }
    }

    private func candidateRow(_ event: CalendarEventDTO) -> some View {
        Button {
            viewModel.linkMeeting(meeting, to: event)
            isPresented = false
        } label: {
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(event.calendarColor?.swiftUIColor ?? .secondary)
                    .frame(width: 4)
                    .frame(maxHeight: .infinity)
                VStack(alignment: .leading, spacing: 4) {
                    Text(event.title.isEmpty
                         ? String(localized: "meetings.calendar.untitledEvent")
                         : event.title)
                        .font(.body)
                        .lineLimit(1)
                    HStack(spacing: 10) {
                        Label {
                            Text(event.startDate, format: .dateTime.weekday().month().day().hour().minute())
                        } icon: {
                            Image(systemName: "calendar")
                        }
                        if !event.attendees.isEmpty {
                            Label("\(event.attendees.count)", systemImage: "person.2")
                        }
                        if let name = event.calendarName, !name.isEmpty {
                            Label(name, systemImage: "tray.full")
                                .lineLimit(1)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Image(systemName: "link")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var accessDenied: some View {
        ContentUnavailableView {
            Label(String(localized: "meetingdoc.link.picker.noAccess.title"), systemImage: "calendar.badge.exclamationmark")
        } description: {
            Text(String(localized: "meetingdoc.link.picker.noAccess.message"))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
