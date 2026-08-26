import SwiftUI

/// The `.spaceFolder` route body (Track E): a **folder index** rendered in the redesign's document
/// shell — the same measure-limited column as `MeetingFolderDetailView`, on the **window ground (no
/// paper)**, deliberately withholding the meeting document's private signature (plan D4/V10). Masthead:
/// `MeetingKicker(["SPACE", "<N items>"])` + serif `pageTitle` folder name. Children are
/// `MeetingQuietRow`s (folders navigate deeper, notes open); an in-document item count on folders is
/// unambiguous (unlike a sidebar badge, plan D7).
///
/// ME-3 adds the compose-then-create quick-note: a leading "New note here" row opens an in-place
/// draft (the editor exists *before* any file) in this same shell; committing performs exactly one
/// never-clobber write via `VaultNoteWriter` and routes to the created note (plan D1).
struct SpaceFolderView: View {
    let path: String

    @ObservedObject private var viewModel = SpaceViewModel.shared
    @ObservedObject private var coordinator = MainWindowCoordinator.shared

    /// Confirm-before-discard for a **deliberate** Discard of a non-empty draft (navigate-away instead
    /// auto-commits — never-clobber makes that safe — so it needs no dialog).
    @State private var showDiscardConfirm = false

    private var folderName: String {
        SpaceTreeModel.normalize(path).split(separator: "/").last.map(String.init)
            ?? (viewModel.vaultName ?? path)
    }

    /// The draft editor owns this folder's pane when a draft targets exactly this folder path.
    private var isDrafting: Bool {
        viewModel.draft?.folderPath == path
    }

    /// A genuine monospaced system font for the draft editor — source, not prose (plan D1: "source,
    /// not prose"). `MeetingTheme.mono` is a *proportional* system font with tabular digits
    /// (`.monospacedDigit()`), not a monospaced face, so it would render the editor as ordinary prose;
    /// a `design: .monospaced` font gives the intended code-like source surface.
    private var draftFont: Font {
        .system(size: 13, design: .monospaced)
    }

    /// The `TextEditor` binding into the view model's draft (the source of truth, so commit logic and
    /// its tests live on the seam, not the view).
    private var draftTextBinding: Binding<String> {
        Binding(
            get: { viewModel.draft?.text ?? "" },
            set: { viewModel.updateDraftText($0) }
        )
    }

    var body: some View {
        // Build the child list **once** per body pass (a single recursive rebuild over the cached
        // snapshot), then read it below — count, emptiness, rows — instead of recomputing the derived
        // tree on each access (plan D6 / ME-1 review).
        let children = viewModel.children(of: path)
        return ScrollView {
            VStack(alignment: .leading, spacing: MeetingTheme.sectionGap) {
                if viewModel.isConnected {
                    if isDrafting {
                        draftSection
                    } else {
                        header(children: children)
                        childrenSection(children: children)
                    }
                } else {
                    disconnectedState
                }
            }
            .padding(MeetingTheme.pagePadding)
            .frame(maxWidth: MeetingTheme.contentMaxWidth, alignment: .topLeading)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .navigationTitle(folderName)
        .toolbar { toolbarContent }
        .onAppear { viewModel.refresh() }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if isDrafting {
            ToolbarItem {
                Button {
                    requestDiscard()
                } label: {
                    Label(String(localized: "space.draft.discard"), systemImage: "xmark")
                }
            }
            ToolbarItem {
                Button {
                    commitAndOpen()
                } label: {
                    Label(String(localized: "space.draft.done"), systemImage: "checkmark")
                }
                .keyboardShortcut("s", modifiers: .command)
            }
        } else {
            ToolbarItem {
                Button {
                    viewModel.refresh()
                } label: {
                    Label(String(localized: "space.refresh"), systemImage: "arrow.clockwise")
                }
            }
            if viewModel.isConnected {
                ToolbarItem {
                    Button {
                        viewModel.revealInFinder(path)
                    } label: {
                        // A reveal-oriented glyph, not the plain `folder` used for folder *objects* in
                        // the tree, so the toolbar action reads distinctly from tree content (ME-1
                        // design review). `arrow.up.forward.app` is reserved for the "Open in Obsidian"
                        // family, so Reveal-in-Finder takes the search/locate glyph.
                        Label(String(localized: "space.reveal.finder"), systemImage: "magnifyingglass")
                    }
                }
            }
        }
    }

    // MARK: - Masthead

    private func header(children: [SpaceNode]) -> some View {
        VStack(alignment: .leading, spacing: MeetingTheme.s2) {
            MeetingKicker(parts: [
                String(localized: "space.kicker.space"),
                String(format: String(localized: "space.itemCount"), children.count),
            ])
            Text(folderName)
                .font(MeetingTheme.pageTitle)
        }
    }

    // MARK: - Children

    @ViewBuilder
    private func childrenSection(children: [SpaceNode]) -> some View {
        // The quick-note entry point: a quiet leading row (plan D1). Friction budget ≤ 2 deliberate
        // actions — tap → cursor blinking → type → Done. Creation lives here, not on a floating button.
        VStack(alignment: .leading, spacing: 0) {
            MeetingQuietRow(
                icon: "square.and.pencil",
                title: String(localized: "space.newNote"),
                detail: nil
            ) {
                viewModel.beginDraft(inFolder: path)
            }

            ForEach(children) { child in
                MeetingQuietRow(
                    icon: child.isDirectory ? "folder" : "doc.text",
                    title: child.name,
                    detail: child.isDirectory
                        ? String(format: String(localized: "space.itemCount"), child.children.count)
                        : nil
                ) {
                    if child.isDirectory {
                        coordinator.show(.spaceFolder(child.relativePath))
                    } else {
                        coordinator.show(.spaceNote(child.relativePath))
                    }
                }
            }
        }

        if children.isEmpty {
            MeetingEmptyStateCard(
                icon: "tray",
                title: String(localized: "space.folder.empty.title"),
                message: String(localized: "space.folder.empty.message")
            ) {
                EmptyView()
            }
        }

        // Truncation is a **vault-index** fact, not a per-folder one: the cap bounds the whole cached
        // snapshot, so the footnote reports the snapshot size and renders even for an empty folder —
        // it no longer claims "showing the first N" of a fully-listed 3-item folder (ME-1 review).
        if viewModel.didTruncate {
            Text(String(format: String(localized: "space.truncated"), viewModel.entries.count))
                .font(MeetingTheme.footnote)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Draft (compose-then-create, plan D1)

    private var draftSection: some View {
        VStack(alignment: .leading, spacing: MeetingTheme.sectionGap) {
            VStack(alignment: .leading, spacing: MeetingTheme.s2) {
                MeetingKicker(parts: [
                    String(localized: "space.kicker.newNote"),
                    folderName,
                ])
                // The serif title tracks the emerging note name (first typed line), so the masthead
                // reads like the meeting document's — a placeholder until the first line is typed.
                Text(SpaceDraft.firstLineTitle(viewModel.draft?.text ?? "")
                    ?? String(localized: "space.draft.untitled"))
                    .font(MeetingTheme.pageTitle)
            }

            // A plain monospaced editor over raw markdown — source, not prose; the redesign has no
            // WYSIWYG editor idiom to imitate (plan D1 / design plan §1d).
            ZStack(alignment: .topLeading) {
                if SpaceDraft.isEmpty(viewModel.draft?.text ?? "") {
                    Text(String(localized: "space.draft.placeholder"))
                        .font(draftFont)
                        .foregroundStyle(.tertiary)
                        .padding(.top, MeetingTheme.s2)
                        // NSTextView-inset compensation, aligning the placeholder to the TextEditor's
                        // internal text inset — not a spacing token (no theme equivalent exists).
                        .padding(.leading, 5)
                        .allowsHitTesting(false)
                }
                TextEditor(text: draftTextBinding)
                    .font(draftFont)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 360)
            }
        }
        // Navigate-away (sidebar click, or commit's own route change) auto-commits a non-empty draft
        // and silently discards an empty one — no dialog (plan D1). Idempotent: after Done clears the
        // draft, this is a no-op.
        .onDisappear { viewModel.commitDraft() }
        .confirmationDialog(
            String(localized: "space.draft.discardConfirm.title"),
            isPresented: $showDiscardConfirm,
            titleVisibility: .visible
        ) {
            Button(String(localized: "space.draft.discardConfirm.confirm"), role: .destructive) {
                viewModel.discardDraft()
            }
            Button(String(localized: "space.draft.discardConfirm.cancel"), role: .cancel) {}
        } message: {
            Text(String(localized: "space.draft.discardConfirm.message"))
        }
    }

    // MARK: - Draft actions

    /// Commit the draft as one never-clobber write and route to the created note in read mode. An empty
    /// draft commits to `nil` (silent discard) and simply returns to the index.
    private func commitAndOpen() {
        if let created = viewModel.commitDraft() {
            coordinator.show(.spaceNote(created))
        }
    }

    /// Deliberate Discard: confirm only when the draft has content worth losing (plan D1).
    private func requestDiscard() {
        if SpaceDraft.shouldConfirmDiscard(viewModel.draft?.text ?? "") {
            showDiscardConfirm = true
        } else {
            viewModel.discardDraft()
        }
    }

    // MARK: - Disconnected (gated, plan D8)

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
}
