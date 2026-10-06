import SwiftUI

/// A row-menu action that needs a dialog before it runs. Carries the target ids captured when the
/// menu item was chosen.
enum MeetingRowPendingAction: Equatable {
    case rename(UUID)
    case delete([UUID])
    case merge([UUID])
    case newFolder([UUID])
    case linkEvent(UUID)
}

/// [Perf Phase 2] The list-level half of the meeting row menu (plan LX-2, D4). Every row used to
/// mount its own modifier with seven `@State`s, five dialog presenters and three observed objects;
/// now a row's menu only records *what* the user picked here, and the owning list presents the one
/// matching alert / confirmation / sheet (`meetingRowActionPresenters`). One instance per list.
@MainActor
final class MeetingRowActions: ObservableObject {
    @Published var pending: MeetingRowPendingAction?
    /// The text field of the rename / new-folder alert.
    @Published var draftText = ""

    /// Where targets are resolved from (the published meetings; a fake in tests).
    private let meetingSource: @MainActor () -> [Meeting]

    init(meetingSource: @escaping @MainActor () -> [Meeting] = { MeetingsViewModel.shared.meetings }) {
        self.meetingSource = meetingSource
    }

    /// Live meetings for `ids`, in the given order (absent ids are skipped — a row can be deleted
    /// while its menu or dialog is open).
    func meetings(for ids: [UUID]) -> [Meeting] {
        let all = meetingSource()
        return ids.compactMap { id in all.first { $0.id == id } }
    }

    func meeting(for id: UUID) -> Meeting? {
        meetings(for: [id]).first
    }

    func beginRename(_ id: UUID) {
        draftText = meeting(for: id)?.title ?? ""
        pending = .rename(id)
    }

    func beginNewFolder(_ ids: [UUID]) {
        draftText = ""
        pending = .newFolder(ids)
    }
}

extension View {
    /// Attach the single set of row-action dialogs for a meeting list (see `MeetingRowActions`).
    func meetingRowActionPresenters(_ actions: MeetingRowActions) -> some View {
        modifier(MeetingRowActionPresenters(actions: actions))
    }
}

private struct MeetingRowActionPresenters: ViewModifier {
    @ObservedObject var actions: MeetingRowActions

    private var viewModel: MeetingsViewModel { MeetingsViewModel.shared }

    func body(content: Content) -> some View {
        // Targets are captured here, not read inside the button actions: a dialog may clear
        // `pending` (its dismissal) before the chosen button's action runs.
        let renameID = actions.pending?.renameID
        let deleteIDs = deleteIDs
        let mergeIDs = actions.pending?.mergeIDs ?? []
        let newFolderIDs = actions.pending?.newFolderIDs ?? []
        return content
            .alert(String(localized: "meetings.menu.rename.title"), isPresented: presenting(\.renameID)) {
                TextField(String(localized: "meetings.menu.rename.placeholder"), text: $actions.draftText)
                Button(String(localized: "meetings.menu.rename.confirm")) {
                    if let renameID, let meeting = actions.meeting(for: renameID) {
                        viewModel.renameMeeting(meeting, to: actions.draftText)
                    }
                }
                Button(String(localized: "Cancel"), role: .cancel) {}
            }
            .confirmationDialog(deleteTitle, isPresented: presenting(\.deleteIDs), titleVisibility: .visible) {
                Button(deleteConfirmLabel, role: .destructive) {
                    viewModel.deleteMeetings(actions.meetings(for: deleteIDs))
                }
                Button(String(localized: "Cancel"), role: .cancel) {}
            } message: {
                Text(deleteMessage)
            }
            .confirmationDialog(
                String(localized: "meetings.merge.confirm.title"),
                isPresented: presenting(\.mergeIDs),
                titleVisibility: .visible
            ) {
                Button(String(localized: "meetings.merge.confirm.action")) {
                    viewModel.mergeMeetings(actions.meetings(for: mergeIDs))
                }
                Button(String(localized: "Cancel"), role: .cancel) {}
            } message: {
                Text(String(
                    format: String(localized: "meetings.merge.confirm.message"),
                    mergeIDs.count
                ))
            }
            .alert(String(localized: "meetings.menu.newFolder.title"), isPresented: presenting(\.newFolderIDs)) {
                TextField(String(localized: "meetings.menu.newFolder.placeholder"), text: $actions.draftText)
                Button(String(localized: "meetings.menu.newFolder.confirm")) {
                    let trimmed = actions.draftText.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        viewModel.setMeetingFolder(trimmed, for: actions.meetings(for: newFolderIDs))
                    }
                    actions.draftText = ""
                }
                Button(String(localized: "Cancel"), role: .cancel) { actions.draftText = "" }
            }
            .sheet(item: linkEventItem) { item in
                if let meeting = actions.meeting(for: item.id) {
                    MeetingLinkEventView(meeting: meeting, isPresented: presenting(\.linkEventID))
                }
            }
    }

    private struct LinkEventItem: Identifiable {
        let id: UUID
    }

    /// `sheet(item:)` keeps the sheet's content through its dismissal animation.
    private var linkEventItem: Binding<LinkEventItem?> {
        Binding(
            get: { actions.pending?.linkEventID.map(LinkEventItem.init) },
            set: { item in
                if item == nil, actions.pending?.linkEventID != nil { actions.pending = nil }
            }
        )
    }

    /// True while `pending` is the action `key` extracts; dismissal clears only that action.
    private func presenting<Value>(_ key: KeyPath<MeetingRowPendingAction, Value?>) -> Binding<Bool> {
        Binding(
            get: { actions.pending?[keyPath: key] != nil },
            set: { isPresented in
                if !isPresented, actions.pending?[keyPath: key] != nil { actions.pending = nil }
            }
        )
    }

    // MARK: - Delete confirmation copy (count-aware)

    private var deleteIDs: [UUID] { actions.pending?.deleteIDs ?? [] }

    private var deleteTitle: String {
        deleteIDs.count > 1
            ? String(localized: "meetings.menu.delete.title.count")
            : String(localized: "meetings.menu.delete.title")
    }

    private var deleteConfirmLabel: String {
        deleteIDs.count > 1
            ? String(format: String(localized: "meetings.menu.deleteCount"), deleteIDs.count)
            : String(localized: "meetings.menu.delete")
    }

    private var deleteMessage: String {
        if deleteIDs.count > 1 {
            return String(format: String(localized: "meetings.menu.delete.message.count"), deleteIDs.count)
        }
        let title = deleteIDs.first.flatMap { actions.meeting(for: $0)?.title } ?? ""
        return String(format: String(localized: "meetings.menu.delete.message"), title)
    }
}

extension MeetingRowPendingAction {
    var renameID: UUID? { if case let .rename(id) = self { return id }; return nil }
    var deleteIDs: [UUID]? { if case let .delete(ids) = self { return ids }; return nil }
    var mergeIDs: [UUID]? { if case let .merge(ids) = self { return ids }; return nil }
    var newFolderIDs: [UUID]? { if case let .newFolder(ids) = self { return ids }; return nil }
    var linkEventID: UUID? { if case let .linkEvent(id) = self { return id }; return nil }
}
