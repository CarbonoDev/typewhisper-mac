import SwiftUI

/// The `.spaceNote` route body (Track E). **ME-1 stub:** ME-1 ships the sidebar tree and folder
/// index (browse only); the full note *reader* — `MarkdownDocumentView(style: .standard)`, the
/// `typewhisper-meeting` "Open meeting" bridge, "Open in Obsidian" — lands in ME-2. Until then a note
/// tap lands on the document shell (same measure-limited column, window ground — no paper, plan
/// D4/V10) with the note's masthead and a quiet placeholder card, so the route is never a dead pane.
struct SpaceNoteView: View {
    let path: String

    @ObservedObject private var viewModel = SpaceViewModel.shared

    private var noteTitle: String {
        let name = (path as NSString).lastPathComponent
        return name.lowercased().hasSuffix(".md") ? String(name.dropLast(3)) : name
    }

    /// The parent folder rendered as short kicker metadata, **not** a full breadcrumb: the kicker
    /// uppercases and clamps to one line, so a deep chain would truncate mid-segment. Show only the
    /// last folder component, elided with a leading `…/` when the note sits deeper (ME-1 design
    /// review; ME-2's reader inherits the same idiom). Empty for a root-level note, so
    /// `MeetingKicker` drops the part.
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
                    VStack(alignment: .leading, spacing: MeetingTheme.s2) {
                        MeetingKicker(parts: [
                            String(localized: "space.kicker.note"),
                            parentKicker,
                        ])
                        Text(noteTitle)
                            .font(MeetingTheme.pageTitle)
                    }

                    MeetingEmptyStateCard(
                        icon: "doc.text",
                        title: String(localized: "space.note.stub.title"),
                        message: String(localized: "space.note.stub.message")
                    ) {
                        EmptyView()
                    }
                } else {
                    disconnectedState
                }
            }
            .padding(MeetingTheme.pagePadding)
            .frame(maxWidth: MeetingTheme.contentMaxWidth, alignment: .topLeading)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .navigationTitle(noteTitle)
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
}
