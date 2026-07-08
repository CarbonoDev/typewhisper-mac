import SwiftUI

/// [Track B] The meeting document header (plan D4): a serif title, a status line (date, LIVE chip
/// while capturing, attendee count), a chip row (output selector incl. custom templates, date +
/// attendees, folder / tags, export), the **primary prominent Start button** on scheduled meetings
/// (owner discoverability requirement #1), and the interrupted / degraded status banners.
struct MeetingDocumentHeader: View {
    @ObservedObject private var viewModel = MeetingsViewModel.shared
    @ObservedObject var model: MeetingDocumentModel
    let meeting: Meeting
    let presentation: MeetingsViewModel.DocumentPresentation

    @State private var isPresentingLanguagePicker = false
    @State private var isPresentingTagsEditor = false
    @State private var isPresentingFolderEditor = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            titleBlock
            chipRow
            if presentation.contextAction == .start {
                primaryStartButton
            }
            banners
        }
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(meeting.title)
                .font(.largeTitle)
                .fontDesign(.serif)
                .bold()
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 10) {
                if presentation.showsLiveChip {
                    liveChip
                }
                if let start = meeting.startDate {
                    Label {
                        Text(start, format: .dateTime.weekday().month().day().hour().minute())
                    } icon: {
                        Image(systemName: "calendar")
                    }
                }
                if !meeting.attendees.isEmpty {
                    Label {
                        Text("\(meeting.attendees.count)")
                    } icon: {
                        Image(systemName: "person.2")
                    }
                }
                if !presentation.showsLiveChip {
                    Text(meeting.state.displayName)
                }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
    }

    private var liveChip: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(.red)
                .frame(width: 8, height: 8)
            Text(String(localized: "meetingdoc.live"))
                .font(.caption.bold())
            Text(MeetingTranscriptPanel.timestamp(viewModel.captureElapsedSeconds))
                .font(.caption.monospacedDigit())
        }
        .foregroundStyle(.red)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(.red.opacity(0.12), in: Capsule())
    }

    // MARK: - Chip row

    private var chipRow: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) { chips }
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) { chips }
            }
        }
    }

    @ViewBuilder
    private var chips: some View {
        outputSelectorChip
        languageChip
        tagsChip
        folderChip
        exportChip
    }

    // MARK: - Tags chip (plan D9/M3 — token editor with index autocomplete)

    private var tagsChip: some View {
        Button {
            isPresentingTagsEditor = true
        } label: {
            let tags = meeting.tags
            let text = tags.isEmpty
                ? String(localized: "meetingdoc.tags.chip.empty")
                : tags.prefix(2).map { "#\($0)" }.joined(separator: " ")
            chipLabel(
                icon: "tag",
                text: text,
                trailingCount: tags.count > 2 ? tags.count : 0
            )
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isPresentingTagsEditor, arrowEdge: .bottom) {
            MeetingTagsEditorPopover(meeting: meeting)
        }
    }

    // MARK: - Language chip (plan D9; Detect wired in M2)

    private var languageChip: some View {
        Button {
            isPresentingLanguagePicker = true
        } label: {
            let text = viewModel.languageDisplayName(for: meeting)
                ?? String(localized: "meetingdoc.language.chip.unset")
            chipLabel(icon: "globe", text: text)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isPresentingLanguagePicker, arrowEdge: .bottom) {
            MeetingLanguagePickerPopover(meeting: meeting, isPresented: $isPresentingLanguagePicker)
        }
    }

    private var outputSelectorChip: some View {
        Menu {
            ForEach(MeetingsViewModel.selectableOutputKinds, id: \.self) { kind in
                Button {
                    model.selectedOutputKind = kind
                } label: {
                    if kind == model.selectedOutputKind {
                        Label(MeetingsViewModel.outputKindLabel(kind), systemImage: "checkmark")
                    } else {
                        Text(MeetingsViewModel.outputKindLabel(kind))
                    }
                }
            }
            let customTemplates = customTemplateRows
            if !customTemplates.isEmpty {
                Divider()
                Section(String(localized: "meetingdoc.output.customTemplates")) {
                    ForEach(customTemplates, id: \.id) { template in
                        // Selection-only: switch the rendered body to this template's kind (showing the
                        // latest output of that kind). Generation stays exclusively on the bottom bar's
                        // Generate ▾ — an accidental menu click here must never cost a provider call.
                        Button(template.name) {
                            model.selectedOutputKind = kind(of: template)
                        }
                    }
                }
            }
        } label: {
            chipLabel(
                icon: "doc.text",
                text: MeetingsViewModel.outputKindLabel(model.selectedOutputKind)
            )
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    // MARK: - Folder chip (plan D9/M4 — inline folder editing with tree autocomplete)

    private var folderChip: some View {
        Button {
            isPresentingFolderEditor = true
        } label: {
            let folder = meeting.folderPath?.trimmingCharacters(in: .whitespaces)
            let text = (folder?.isEmpty == false)
                ? folder!
                : String(localized: "meetingdoc.chip.noFolder")
            chipLabel(icon: "folder", text: text)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isPresentingFolderEditor, arrowEdge: .bottom) {
            MeetingFolderEditorPopover(meeting: meeting, isPresented: $isPresentingFolderEditor)
        }
    }

    private var exportChip: some View {
        Button {
            model.isPresentingExport = true
        } label: {
            chipLabel(icon: "square.and.arrow.up", text: String(localized: "meetingdoc.chip.export"))
        }
        .buttonStyle(.plain)
    }

    private func chipLabel(icon: String, text: String, trailingCount: Int = 0) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
            Text(text)
                .lineLimit(1)
            if trailingCount > 0 {
                Text("\(trailingCount)")
                    .font(.caption2)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(.secondary.opacity(0.2), in: Capsule())
            }
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.secondary.opacity(0.12), in: Capsule())
    }

    // MARK: - Primary Start button (owner requirement #1)

    private var primaryStartButton: some View {
        Button {
            Task { await viewModel.startCapture(for: meeting) }
        } label: {
            Label(String(localized: "meetingdoc.start.primary"), systemImage: "record.circle.fill")
                .font(.title3.bold())
                .padding(.vertical, 4)
                .padding(.horizontal, 8)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .tint(.red)
        .disabled(!viewModel.canStartCapture)
    }

    // MARK: - Banners

    @ViewBuilder
    private var banners: some View {
        if meeting.state == .interrupted {
            banner(String(localized: "meetings.detail.interruptedBanner"), icon: "exclamationmark.triangle")
        }
        if viewModel.finalRetranscriptionDegradedMeetingID == meeting.id {
            banner(String(localized: "meetings.finalPass.degradedStatus"), icon: "wifi.exclamationmark")
        }
        if let error = viewModel.captureErrorMessage {
            banner(error, icon: "exclamationmark.octagon", tint: .red)
        }
    }

    private func banner(_ text: String, icon: String, tint: Color = .orange) -> some View {
        Label(text, systemImage: icon)
            .font(.callout)
            .foregroundStyle(tint)
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Custom template helpers

    private var customTemplateRows: [PromptAction] {
        // Templates beyond the kind's actual default (per-meeting/rule override, AD7 — not necessarily
        // the first) surface as explicit "custom" selection rows.
        MeetingsViewModel.selectableOutputKinds.flatMap { kind -> [PromptAction] in
            let defaultID = viewModel.defaultTemplate(ofKind: kind, for: meeting)?.id
            return viewModel.templates(ofKind: kind).filter { $0.id != defaultID }
        }
    }

    private func kind(of template: PromptAction) -> MeetingOutputKind {
        for kind in MeetingsViewModel.selectableOutputKinds
        where viewModel.templates(ofKind: kind).contains(where: { $0.id == template.id }) {
            return kind
        }
        return model.selectedOutputKind
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
