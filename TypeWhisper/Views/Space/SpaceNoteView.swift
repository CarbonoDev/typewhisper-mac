import SwiftUI

/// The `.spaceNote` route body (Track E, ME-2): the vault note **reader**. Same document shell as the
/// folder index — the measure-limited column on the **window ground (no paper), never the serif
/// `.article` voice** — so a hand-written vault note is never branded as TypeWhisper meeting prose
/// (plan D4/V9/V10). Masthead is `MeetingKicker(["NOTE", <parent>])` + serif `pageTitle`; the body is
/// `MarkdownDocumentView(style: .standard)`. Two quiet rows demote the secondary affordances (plan
/// override 2): "Open meeting" when the `typewhisper-meeting` backlink resolves to an existing
/// meeting, and "Open in Obsidian". A missing / unreadable file renders an empty-state card, never a
/// dead pane or an error. The raw note is loaded into `@State` on appear / path change — never read
/// from disk inside `body`.
struct SpaceNoteView: View {
    let path: String

    @ObservedObject private var viewModel = SpaceViewModel.shared

    /// The raw note text (frontmatter included), loaded off the disk read. `nil` after a load means
    /// the file is missing / unreadable / out of the vault (the empty-state case).
    @State private var rawContent: String?
    /// The resolved backlink meeting id, or `nil` when the note carries no valid `typewhisper-meeting`
    /// field or it points at a meeting that no longer exists (tolerant — no bridge row, no error).
    @State private var linkedMeetingID: UUID?
    /// Guards the missing-file state so it shows only *after* a load, not during the first frame.
    @State private var didLoad = false

    private var noteTitle: String {
        if let rawContent, let heading = Self.headingTitle(in: Self.strippedBody(rawContent)) {
            return heading
        }
        let name = (path as NSString).lastPathComponent
        return name.lowercased().hasSuffix(".md") ? String(name.dropLast(3)) : name
    }

    /// The parent folder rendered as short kicker metadata, **not** a full breadcrumb: the kicker
    /// uppercases and clamps to one line, so a deep chain would truncate mid-segment. Show only the
    /// last folder component, elided with a leading `…/` when the note sits deeper. Empty for a
    /// root-level note, so `MeetingKicker` drops the part.
    private var parentKicker: String {
        let parts = (path as NSString).deletingLastPathComponent
            .split(separator: "/").map(String.init)
        guard let last = parts.last else { return "" }
        return parts.count > 1 ? "…/" + last : last
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: MeetingTheme.sectionGap) {
                if viewModel.isConnected {
                    connectedBody
                } else {
                    disconnectedState
                }
            }
            .padding(MeetingTheme.pagePadding)
            .frame(maxWidth: MeetingTheme.contentMaxWidth, alignment: .topLeading)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .navigationTitle(noteTitle)
        .toolbar {
            if viewModel.isConnected {
                ToolbarItem {
                    Button {
                        viewModel.revealInFinder(path)
                    } label: {
                        Label(String(localized: "space.reveal.finder"), systemImage: "magnifyingglass")
                    }
                }
            }
        }
        // Loads on appear and re-loads whenever the routed note path changes (sidebar navigation
        // reuses this view). Synchronous read into `@State`; never inside `body`.
        .task(id: path) { load() }
    }

    // MARK: - Connected body

    @ViewBuilder
    private var connectedBody: some View {
        masthead

        if let rawContent {
            // Under the masthead, quiet rows only (the redesign demotes secondary affordances).
            if let id = linkedMeetingID {
                MeetingQuietRow(
                    icon: "person.2.wave.2",
                    title: String(localized: "space.note.openMeeting"),
                    detail: nil
                ) {
                    viewModel.openMeeting(id: id)
                }
            }
            MeetingQuietRow(
                icon: "arrow.up.forward.app",
                title: String(localized: "space.note.openInObsidian"),
                detail: nil
            ) {
                viewModel.openInObsidian(path)
            }

            MarkdownDocumentView(markdown: Self.strippedBody(rawContent), style: .standard)
        } else if didLoad {
            missingState
        }
    }

    private var masthead: some View {
        VStack(alignment: .leading, spacing: MeetingTheme.s2) {
            MeetingKicker(parts: [
                String(localized: "space.kicker.note"),
                parentKicker,
            ])
            Text(noteTitle)
                .font(MeetingTheme.pageTitle)
        }
    }

    private var missingState: some View {
        MeetingEmptyStateCard(
            icon: "questionmark.circle",
            title: String(localized: "space.note.missing.title"),
            message: String(localized: "space.note.missing.message")
        ) {
            EmptyView()
        }
    }

    // MARK: - Disconnected (gated, plan D8 — mirrors SpaceFolderView)

    private var disconnectedState: some View {
        MeetingEmptyStateCard(
            icon: "externaldrive",
            title: String(localized: "space.disconnected.title"),
            message: String(localized: "space.disconnected.message")
        ) {
            Button(String(localized: "mainwindow.space.connect")) {
                viewModel.chooseVault()
            }
            .buttonStyle(.bordered)
        }
    }

    // MARK: - Loading

    private func load() {
        rawContent = viewModel.noteBody(at: path)
        // The "Open meeting" row appears only when the backlink resolves to a meeting that still
        // exists (unknown-uuid → no row, per the tolerant-parsing rule); resolution is the pure
        // `SpaceReveal.linkedMeeting` seam over the current meeting set.
        linkedMeetingID = SpaceReveal.linkedMeeting(
            uuid: viewModel.linkedMeetingUUID(at: path),
            existingMeetingIDs: Set(MeetingsViewModel.shared.meetings.map(\.id))
        )
        didLoad = true
    }

    // MARK: - Frontmatter-aware display (mirrors ObsidianVaultService.parseNote's rules)

    /// Strip a leading `---`…`---` YAML frontmatter block so it never renders as body text. Returns the
    /// input unchanged when there's no well-formed (opened-and-closed) frontmatter.
    static func strippedBody(_ raw: String) -> String {
        let lines = raw.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return raw }
        for index in 1..<lines.count where lines[index].trimmingCharacters(in: .whitespaces) == "---" {
            return lines[(index + 1)...].joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return raw
    }

    /// The first `# ` heading in the body, else `nil` (the caller falls back to the filename stem).
    static func headingTitle(in body: String) -> String? {
        for line in body.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("# ") {
                return String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }
}
