import SwiftUI

/// [Sprint 1] The meeting document masthead: an uppercase kicker line (date · duration · people ·
/// state), the serif editable title, a byline (attendee avatars + natural-language sentence), quiet
/// metadata links (folder · #tags · language), a single prioritized status banner, and the `⋯`
/// overflow menu that hosts every editor the old nine-chip row used to spread across the page.
/// The primary Start button and the live timer moved to the bottom bar — the document has exactly
/// one record affordance (`MeetingBottomBar`).
struct MeetingDocumentHeader: View {
    @ObservedObject private var viewModel = MeetingsViewModel.shared
    @ObservedObject var model: MeetingDocumentModel
    let meeting: Meeting
    let presentation: MeetingsViewModel.DocumentPresentation

    /// Every metadata editor popover anchors at the overflow button — one presentation point, so a
    /// byline meta link and the menu never race two popover bindings for the same editor.
    private enum EditorPopover: String, Identifiable {
        case language
        case tags
        case folder
        case date
        case participants

        var id: String { rawValue }
    }

    @State private var activeEditor: EditorPopover?
    @State private var isPresentingParticipants = false
    @State private var isPresentingOverride = false
    /// Inline title-edit draft (folder-description idiom): committed on submit and on focus loss, so
    /// a rename never touches calendar linkage and never fetch-thrashes on every keystroke.
    @State private var titleDraft = ""
    @FocusState private var titleFieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: MeetingTheme.s3) {
            if presentation.showsLiveChip {
                liveMasthead
            } else {
                masthead
            }
            banner
        }
    }

    // MARK: - Masthead

    private var masthead: some View {
        VStack(alignment: .leading, spacing: MeetingTheme.s2) {
            HStack(alignment: .firstTextBaseline) {
                MeetingKicker(parts: kickerParts)
                Spacer(minLength: MeetingTheme.s3)
                overflowMenu
            }
            titleField(MeetingTheme.pageTitle)
            byline
            metaLinks
        }
    }

    /// While live the masthead compresses to a single row — the page belongs to the notes.
    private var liveMasthead: some View {
        HStack(alignment: .firstTextBaseline) {
            titleField(MeetingTheme.liveTitle)
            Spacer(minLength: MeetingTheme.s3)
            overflowMenu
        }
    }

    private var kickerParts: [String] {
        var parts = [String(localized: "meetingdoc.kicker.meeting")]
        // [Sprint 3] Imported meetings without a stored date still carry one in their export
        // filename — surface it so the kicker isn't a bare "MEETING".
        let start = meeting.startDate ?? ImportedMeetingTitle.parse(meeting.title).date
        if let start {
            parts.append(start.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)))
            if meeting.state == .completed {
                if let duration = durationText { parts.append(duration) }
            } else {
                parts.append(start.formatted(.dateTime.hour().minute()))
            }
        }
        if !meeting.attendees.isEmpty {
            parts.append(String(format: String(localized: "meetingdoc.kicker.people"), meeting.attendees.count))
        }
        // The state word only earns kicker space when it's surprising — scheduled reads off the
        // future date, completed off the summary; interrupted/processing/failed need saying.
        if meeting.state != .completed, meeting.state != .scheduled, meeting.state != .live {
            parts.append(meeting.state.displayName)
        }
        return parts
    }

    private var durationText: String? {
        let seconds: Double
        if let start = meeting.startDate, let end = meeting.endDate, end > start {
            seconds = end.timeIntervalSince(start)
        } else if let last = meeting.segments.map(\.end).max(), last > 0 {
            seconds = last
        } else {
            return nil
        }
        return Duration.seconds(seconds).formatted(.units(allowed: [.hours, .minutes], width: .narrow))
    }

    private func titleField(_ font: Font) -> some View {
        // Inline, single-click-to-edit title (folder-description idiom). Renaming routes through
        // the single-writer `MeetingService.setTitle`, which never clears calendar linkage.
        TextField(
            String(localized: "meetingdoc.title.placeholder"),
            text: $titleDraft,
            axis: .vertical
        )
        .textFieldStyle(.plain)
        .font(font)
        .lineLimit(1...3)
        .focused($titleFieldFocused)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onSubmit { commitTitle() }
        .onChange(of: titleFieldFocused) { _, focused in
            if !focused { commitTitle() }
        }
        .onAppear { titleDraft = meeting.title }
        .onChange(of: meeting.id) { _, _ in titleDraft = meeting.title }
        .onChange(of: meeting.title) { _, newValue in
            // Reflect external title changes (e.g. linking adopted the event title) when the
            // field isn't being actively edited.
            if !titleFieldFocused { titleDraft = newValue }
        }
    }

    private func commitTitle() {
        viewModel.renameMeeting(meeting, to: titleDraft)
        // Reflect normalization (trim) / rejected-blank back into the field.
        titleDraft = meeting.title
    }

    // MARK: - Byline (participants)

    private var otherAttendees: [Attendee] {
        meeting.attendees.filter { $0.isSelf != true }
    }

    private var otherAttendeeNames: [String] {
        otherAttendees.map(\.displayName)
    }

    private var byline: some View {
        Button {
            isPresentingParticipants = true
        } label: {
            HStack(spacing: MeetingTheme.s2) {
                if !otherAttendeeNames.isEmpty {
                    MeetingAvatarStack(names: otherAttendeeNames)
                }
                Text(bylineText)
                    .font(MeetingTheme.meta)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isPresentingParticipants, arrowEdge: .bottom) {
            ParticipantsSection(meeting: meeting)
        }
    }

    private var bylineText: String {
        let attendees = otherAttendees
        guard !attendees.isEmpty else {
            return String(localized: "meetingdoc.byline.addPeople")
        }
        // Compact given names keep the sentence one quiet line; the popover carries full rosters.
        var list = attendees.prefix(3).map(\.shortDisplayName).formatted(.list(type: .and, width: .short))
        if attendees.count > 3 {
            list += " +\(attendees.count - 3)"
        }
        return String(format: String(localized: "meetingdoc.byline.with"), list)
    }

    // MARK: - Meta links (folder · #tags · language)

    @ViewBuilder
    private var metaLinks: some View {
        let folder = meeting.folderPath?.trimmingCharacters(in: .whitespaces)
        let tags = meeting.tags
        let language = viewModel.languageDisplayName(for: meeting)
        if folder?.isEmpty == false || !tags.isEmpty || language != nil {
            HStack(spacing: MeetingTheme.s3) {
                if let folder, !folder.isEmpty {
                    MeetingMetaLink(text: folder, systemImage: "folder") { activeEditor = .folder }
                }
                if !tags.isEmpty {
                    MeetingMetaLink(text: tagSummary(tags)) { activeEditor = .tags }
                }
                if let language {
                    MeetingMetaLink(text: language, systemImage: "globe") { activeEditor = .language }
                }
            }
        }
    }

    private func tagSummary(_ tags: [String]) -> String {
        let shown = tags.prefix(2).map { "#\($0)" }.joined(separator: " ")
        return tags.count > 2 ? "\(shown) +\(tags.count - 2)" : shown
    }

    // MARK: - Overflow menu

    private var overflowMenu: some View {
        Menu {
            Button {
                model.isPresentingExport = true
            } label: {
                Label(String(localized: "meetingdoc.chip.export"), systemImage: "square.and.arrow.up")
            }
            // Merge-import must never race the live-capture writer (a merge rewrites all
            // segments): keep the old chip's `showsImportMergeAction` gate, plus the pre-meeting
            // empty state where import builds the document.
            if viewModel.showsImportMergeAction(for: meeting) || presentation.bodyMode == .scheduledEmpty {
                Button {
                    model.isPresentingImport = true
                } label: {
                    Label(String(localized: "meetingdoc.chip.import"), systemImage: "square.and.arrow.down")
                }
            }
            // One-click cleanup for meetings that kept their export filename as a title: apply the
            // normalized title and, when the meeting has no date of its own, the one parsed from
            // the filename. Both writes go through the existing single-writer setters.
            if ImportedMeetingTitle.parse(meeting.title).isImported {
                Button {
                    let parsed = ImportedMeetingTitle.parse(meeting.title)
                    viewModel.renameMeeting(meeting, to: parsed.cleanTitle)
                    if meeting.startDate == nil, let date = parsed.date {
                        viewModel.setMeetingDate(date, for: meeting)
                    }
                } label: {
                    Label(String(localized: "meetingdoc.overflow.cleanTitle"), systemImage: "wand.and.stars")
                }
            }
            Divider()
            Button {
                model.isPresentingLinkEvent = true
            } label: {
                Label(
                    meeting.calendarEventID != nil
                        ? String(localized: "meetingdoc.link.change")
                        : String(localized: "meetingdoc.link.link"),
                    systemImage: "calendar.badge.plus"
                )
            }
            if meeting.calendarEventID != nil {
                Button(role: .destructive) {
                    viewModel.unlinkMeeting(meeting)
                } label: {
                    Label(String(localized: "meetingdoc.link.unlink"), systemImage: "calendar.badge.minus")
                }
            }
            if MeetingsViewModel.showsDateEditor(calendarEventID: meeting.calendarEventID) {
                Button {
                    activeEditor = .date
                } label: {
                    Label(String(localized: "meetingdoc.date.editor.title"), systemImage: "calendar")
                }
            }
            Divider()
            // Participants stay editable in every state — the byline (the usual trigger) is hidden
            // while live, but adding the people in the room mid-recording must keep working.
            Button {
                activeEditor = .participants
            } label: {
                Label(String(localized: "meetingdoc.participants.chip"), systemImage: "person.2")
            }
            Button {
                activeEditor = .folder
            } label: {
                Label(String(localized: "meetingdoc.folder.editor.title"), systemImage: "folder")
            }
            Button {
                activeEditor = .tags
            } label: {
                Label(String(localized: "meetingdoc.tags.editor.title"), systemImage: "tag")
            }
            Button {
                activeEditor = .language
            } label: {
                Label(String(localized: "meetingdoc.language.picker.title"), systemImage: "globe")
            }
            if meeting.state == .scheduled || meeting.state == .live {
                Divider()
                Button {
                    isPresentingOverride = true
                } label: {
                    Label(String(localized: "meetingdoc.finalPass.disclosure"), systemImage: "gearshape")
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.title3)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .popover(item: $activeEditor, arrowEdge: .bottom) { editor in
            switch editor {
            case .language:
                MeetingLanguagePickerPopover(meeting: meeting, isPresented: dismissBinding(for: .language))
            case .tags:
                MeetingTagsEditorPopover(meeting: meeting)
            case .folder:
                MeetingFolderEditorPopover(meeting: meeting, isPresented: dismissBinding(for: .folder))
            case .date:
                MeetingDateEditorPopover(meeting: meeting, isPresented: dismissBinding(for: .date))
            case .participants:
                ParticipantsSection(meeting: meeting)
            }
        }
        .sheet(isPresented: $isPresentingOverride) {
            overrideSheet
        }
    }

    /// Bridges the popovers' `Binding<Bool>` dismissal contract onto the single `activeEditor` item.
    private func dismissBinding(for editor: EditorPopover) -> Binding<Bool> {
        Binding(
            get: { activeEditor == editor },
            set: { if !$0 { activeEditor = nil } }
        )
    }

    /// The per-meeting final re-transcription override, retired from the document body — it's
    /// plumbing, reachable from the overflow menu only (Sprint 1).
    private var overrideSheet: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(String(localized: "meetingdoc.finalPass.disclosure"))
                    .font(.headline)
                Spacer()
                Button(String(localized: "meetingdoc.export.done")) { isPresentingOverride = false }
            }
            .padding()
            Divider()
            ScrollView {
                MeetingFinalRetranscriptionOverrideView(meeting: meeting)
                    .padding()
            }
        }
        .frame(width: 440, height: 380)
    }

    // MARK: - Status banner (max one, highest priority wins)

    @ViewBuilder
    private var banner: some View {
        // Meeting-scoped facts outrank the global capture error: `captureErrorMessage` is one
        // published value for the whole app, and a stale error from some other meeting's failed
        // start must not hide THIS meeting's interrupted/degraded state.
        if meeting.state == .interrupted {
            bannerRow(String(localized: "meetings.detail.interruptedBanner"), icon: "exclamationmark.triangle")
        } else if viewModel.finalRetranscriptionDegradedMeetingID == meeting.id {
            bannerRow(String(localized: "meetings.finalPass.degradedStatus"), icon: "wifi.exclamationmark")
        } else if let error = viewModel.captureErrorMessage {
            bannerRow(error, icon: "exclamationmark.octagon", tint: .red)
        }
    }

    private func bannerRow(_ text: String, icon: String, tint: Color = .orange) -> some View {
        Label(text, systemImage: icon)
            .font(.callout)
            .foregroundStyle(tint)
            .padding(MeetingTheme.s2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: MeetingTheme.rowRadius))
    }
}

/// The per-meeting language picker popover (plan D9): a searchable list with the app's featured
/// languages ranked first, the current provenance tag, a Detect / Re-detect action (plan D5, M2), and
/// a Clear action. Setting a language from the list records it as `.manual`.
private struct MeetingLanguagePickerPopover: View {
    @ObservedObject private var viewModel = MeetingsViewModel.shared
    let meeting: Meeting
    @Binding var isPresented: Bool

    @State private var query = ""

    private var options: [LocalizedAppLanguageOption] {
        let all = viewModel.meetingLanguageOptions
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return all }
        return all.filter { option in
            localizedAppLanguageSearchTerms(for: option.code, preferredDisplayName: option.name)
                .contains { $0.localizedCaseInsensitiveContains(trimmed) }
        }
    }

    /// Featured languages first (by app rank), then the rest alphabetically — only when not
    /// searching, mirroring `LanguageSelectionEditor`.
    private var orderedOptions: [LocalizedAppLanguageOption] {
        let filtered = options
        guard query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return filtered.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
        let featured = filtered
            .compactMap { option -> (rank: Int, option: LocalizedAppLanguageOption)? in
                guard let rank = featuredAppLanguageRank(for: option.code) else { return nil }
                return (rank, option)
            }
            .sorted { $0.rank != $1.rank ? $0.rank < $1.rank : $0.option.name.localizedCaseInsensitiveCompare($1.option.name) == .orderedAscending }
            .map(\.option)
        let featuredCodes = Set(featured.map(\.code))
        let rest = filtered
            .filter { !featuredCodes.contains($0.code) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return featured + rest
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(String(localized: "meetingdoc.language.picker.title"))
                .font(.headline)

            if let provenance = viewModel.languageProvenanceLabel(for: meeting) {
                Text(provenance)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            TextField(String(localized: "meetingdoc.language.picker.search"), text: $query)
                .textFieldStyle(.roundedBorder)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(orderedOptions, id: \.code) { option in
                        Button {
                            viewModel.setMeetingLanguage(option.code, for: meeting)
                            isPresented = false
                        } label: {
                            HStack {
                                Text(option.name)
                                Spacer()
                                if option.code == meeting.languageCode {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.tint)
                                }
                            }
                            .contentShape(Rectangle())
                            .padding(.vertical, 4)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(maxHeight: 240)

            Divider()

            // Detect / Re-detect (plan D5, M2). Disabled while a detection is in flight, and disabled
            // with a "clear first" hint when the language is a manual pick (Decision 3 / owner-veto 3).
            detectSection

            if meeting.languageCode != nil {
                Divider()
                Button(role: .destructive) {
                    viewModel.clearMeetingLanguage(for: meeting)
                    isPresented = false
                } label: {
                    Label(String(localized: "meetingdoc.language.picker.clear"), systemImage: "xmark.circle")
                }
                .buttonStyle(.plain)
            }
        }
        .padding(16)
        .frame(width: 300)
    }

    @ViewBuilder
    private var detectSection: some View {
        let isDetecting = viewModel.isDetectingLanguage(for: meeting)
        let canDetect = viewModel.canDetectLanguage(for: meeting)
        VStack(alignment: .leading, spacing: 4) {
            Button {
                viewModel.detectMeetingLanguage(for: meeting)
                isPresented = false
            } label: {
                HStack(spacing: 6) {
                    if isDetecting {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "sparkles")
                    }
                    Text(viewModel.detectActionTitle(for: meeting))
                }
            }
            .buttonStyle(.plain)
            .disabled(!canDetect || isDetecting)

            if !canDetect {
                Text(String(localized: "meetingdoc.language.detect.manualHint"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// The per-meeting Tags token editor popover (plan D9/M3): existing tags as removable capsules, a
/// text field that commits on Return, and autocomplete suggestions drawn from the shared
/// `MeetingOrganizationIndex`. All writes go through the view model → the single-writer
/// `MeetingService.setObsidianTags`, so the sidebar, timeline capsules, and index refresh together.
private struct MeetingTagsEditorPopover: View {
    @ObservedObject private var viewModel = MeetingsViewModel.shared
    @ObservedObject private var organizationIndex = MeetingOrganizationIndex.shared
    let meeting: Meeting

    @State private var draft = ""

    private var suggestions: [String] {
        MeetingsViewModel.tagSuggestions(
            from: organizationIndex.tagCounts,
            query: draft,
            excluding: meeting
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(String(localized: "meetingdoc.tags.editor.title"))
                .font(.headline)

            if !meeting.tags.isEmpty {
                FlowingTagCapsules(tags: meeting.tags) { tag in
                    viewModel.removeMeetingTag(tag, from: meeting)
                }
            }

            TextField(String(localized: "meetingdoc.tags.editor.add"), text: $draft)
                .textFieldStyle(.roundedBorder)
                .onSubmit(commitDraft)

            if !suggestions.isEmpty {
                Divider()
                Text(String(localized: "meetingdoc.tags.editor.suggestions"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(suggestions, id: \.self) { suggestion in
                            Button {
                                viewModel.addMeetingTag(suggestion, to: meeting)
                                draft = ""
                            } label: {
                                Label("#\(suggestion)", systemImage: "tag")
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                                    .padding(.vertical, 3)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(maxHeight: 160)
            }
        }
        .padding(16)
        .frame(width: 280)
    }

    private func commitDraft() {
        // Allow comma-separated entry ("hiring, q3") in one commit.
        let parts = draft.split(separator: ",").map { String($0) }
        for part in parts {
            viewModel.addMeetingTag(part, to: meeting)
        }
        draft = ""
    }
}

/// The per-meeting Folder editor popover (plan D9/M4): a text field for a `/`-separated path (commit
/// on Return), autocomplete suggestions of existing folders drawn from the shared
/// `MeetingOrganizationIndex` tree, and a Clear action. Writes go through the view model → the
/// single-writer `MeetingService.setFolder`, so the sidebar tree, chip, and filters refresh together.
private struct MeetingFolderEditorPopover: View {
    @ObservedObject private var viewModel = MeetingsViewModel.shared
    @ObservedObject private var organizationIndex = MeetingOrganizationIndex.shared
    let meeting: Meeting
    @Binding var isPresented: Bool

    @State private var draft = ""

    private var suggestions: [String] {
        MeetingsViewModel.folderSuggestions(from: organizationIndex.folderTree, query: draft)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(String(localized: "meetingdoc.folder.editor.title"))
                .font(.headline)

            TextField(String(localized: "meetingdoc.folder.editor.field"), text: $draft)
                .textFieldStyle(.roundedBorder)
                .onSubmit(commit)

            Text(String(localized: "meetingdoc.folder.editor.hint"))
                .font(.caption)
                .foregroundStyle(.secondary)

            if !suggestions.isEmpty {
                Divider()
                Text(String(localized: "meetingdoc.folder.editor.existing"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(suggestions, id: \.self) { suggestion in
                            Button {
                                viewModel.setMeetingFolder(suggestion, for: meeting)
                                isPresented = false
                            } label: {
                                Label(suggestion, systemImage: "folder")
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                                    .padding(.vertical, 3)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(maxHeight: 160)
            }

            if meeting.folderPath?.isEmpty == false {
                Divider()
                Button(role: .destructive) {
                    viewModel.setMeetingFolder(nil, for: meeting)
                    isPresented = false
                } label: {
                    Label(String(localized: "meetingdoc.folder.editor.clear"), systemImage: "xmark.circle")
                }
                .buttonStyle(.plain)
            }
        }
        .padding(16)
        .frame(width: 300)
        .onAppear { draft = meeting.folderPath ?? "" }
    }

    private func commit() {
        viewModel.setMeetingFolder(draft, for: meeting)
        isPresented = false
    }
}

/// The per-meeting date editor popover (requirement 2), shown only for meetings not linked to a
/// calendar event. A graphical date+time picker plus Set/Clear actions; writes go through the view
/// model → the single-writer `MeetingService.setMeetingDate`, so the timeline grouping and the
/// header status line refresh together.
private struct MeetingDateEditorPopover: View {
    @ObservedObject private var viewModel = MeetingsViewModel.shared
    let meeting: Meeting
    @Binding var isPresented: Bool

    @State private var draft = Date()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(String(localized: "meetingdoc.date.editor.title"))
                .font(.headline)

            DatePicker(
                String(localized: "meetingdoc.date.editor.field"),
                selection: $draft,
                displayedComponents: [.date, .hourAndMinute]
            )
            .datePickerStyle(.graphical)
            .labelsHidden()

            HStack {
                if meeting.startDate != nil {
                    Button(role: .destructive) {
                        viewModel.setMeetingDate(nil, for: meeting)
                        isPresented = false
                    } label: {
                        Label(String(localized: "meetingdoc.date.editor.clear"), systemImage: "xmark.circle")
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
                Button(String(localized: "meetingdoc.date.editor.set")) {
                    viewModel.setMeetingDate(draft, for: meeting)
                    isPresented = false
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 320)
        .onAppear { draft = meeting.startDate ?? Date() }
    }
}

/// A wrapping row of removable tag capsules for the tags editor. Kept simple (an `HStack` per line
/// via `ViewThatFits` would over-engineer this popover), it lays capsules out with `WrapLayout`-free
/// flow using a `LazyVGrid`-style adaptive column.
private struct FlowingTagCapsules: View {
    let tags: [String]
    let onRemove: (String) -> Void

    private let columns = [GridItem(.adaptive(minimum: 70), spacing: 6, alignment: .leading)]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 6) {
            ForEach(tags, id: \.self) { tag in
                HStack(spacing: 4) {
                    Text("#\(tag)")
                        .lineLimit(1)
                    Button {
                        onRemove(tag)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
                .font(.caption)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Color.secondary.opacity(0.15), in: Capsule())
            }
        }
    }
}
