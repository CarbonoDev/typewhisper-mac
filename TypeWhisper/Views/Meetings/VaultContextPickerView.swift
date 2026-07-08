import SwiftUI

/// Read-only vault attachment picker (Amendment 1, DA8, M7). A modal search-as-you-type selector over
/// the connected vault's notes/folders (`ObsidianVaultService.searchEntries`): multi-select notes
/// and/or folders, confirm to attach their paths. No drag-drop; the picker is a *selector* — Track E's
/// Space is the full read-write browser, and both consume the same enumeration primitive (plan §4).
struct VaultContextPickerView: View {
    /// Called with the chosen entries on confirm.
    let onSelect: ([VaultEntry]) -> Void

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var viewModel = MeetingsViewModel.shared

    @State private var query = ""
    @State private var selectedIDs: Set<String> = []

    /// Live search results; a blank query lists the leading entries.
    private var results: [VaultEntry] {
        viewModel.searchVaultEntries(query)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            searchField
            Divider()
            content
            Divider()
            footer
        }
        .frame(minWidth: 420, minHeight: 480)
    }

    private var header: some View {
        HStack {
            Text(String(localized: "meetingfolder.picker.title"))
                .font(.headline)
            Spacer()
        }
        .padding()
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField(String(localized: "meetingfolder.picker.search.placeholder"), text: $query)
                .textFieldStyle(.plain)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var content: some View {
        let entries = results
        if entries.isEmpty {
            ContentUnavailableView {
                Label(
                    String(localized: query.isEmpty
                        ? "meetingfolder.picker.empty"
                        : "meetingfolder.picker.noResults"),
                    systemImage: "doc.text.magnifyingglass"
                )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(entries) { entry in
                row(entry)
                    .contentShape(Rectangle())
                    .onTapGesture { toggle(entry) }
            }
            .listStyle(.inset)
        }
    }

    private func row(_ entry: VaultEntry) -> some View {
        HStack(spacing: 8) {
            Image(systemName: selectedIDs.contains(entry.id) ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(selectedIDs.contains(entry.id) ? Color.accentColor : Color.secondary)
            Image(systemName: entry.isDirectory ? "folder" : "doc.text")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.displayName)
                    .lineLimit(1)
                Text(entry.relativePath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(.vertical, 2)
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button(String(localized: "meetingfolder.picker.cancel")) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button {
                onSelect(selectedEntries())
                dismiss()
            } label: {
                Text(String(
                    format: String(localized: "meetingfolder.picker.add"),
                    selectedIDs.count
                ))
            }
            .keyboardShortcut(.defaultAction)
            .disabled(selectedIDs.isEmpty)
        }
        .padding()
    }

    private func toggle(_ entry: VaultEntry) {
        if selectedIDs.contains(entry.id) {
            selectedIDs.remove(entry.id)
        } else {
            selectedIDs.insert(entry.id)
        }
    }

    /// Resolve the selected ids back to `VaultEntry` values across the full (unfiltered) vault listing
    /// so a selection survives the user narrowing/clearing the query between picks.
    private func selectedEntries() -> [VaultEntry] {
        viewModel.searchVaultEntries("", limit: Int.max).filter { selectedIDs.contains($0.id) }
    }
}
