import Foundation

/// First-party folder-context surface (Amendment 1, DA7/DA8, M7). Thin MainActor pass-throughs to the
/// single-writer `MeetingFolderMetadataStore` (description, vault attachments, "No vault context"
/// toggle) plus the read-only vault search the attachment picker consumes. Extension-file discipline:
/// no stored state is added here — the config map lives on `MeetingFolderMetadataStore`, which the
/// folder detail view observes directly.
@MainActor
extension MeetingsViewModel {
    // MARK: - Reads

    /// The context config for a folder path (an empty default when none is stored).
    func folderContextConfig(for folderPath: String) -> FolderContextConfig {
        folderMetadataStore.config(for: folderPath)
    }

    // MARK: - Description

    func setFolderDescription(_ description: String, for folderPath: String) {
        folderMetadataStore.setDescription(description, for: folderPath)
    }

    // MARK: - Vault attachments

    /// Attach the picked vault entries (notes and/or folders) to a folder's context. Notes and folders
    /// are routed to the matching config list.
    func attachVaultEntries(_ entries: [VaultEntry], to folderPath: String) {
        let notePaths = entries.filter { !$0.isDirectory }.map(\.relativePath)
        let folderPaths = entries.filter(\.isDirectory).map(\.relativePath)
        if !notePaths.isEmpty { folderMetadataStore.attachNotes(notePaths, to: folderPath) }
        if !folderPaths.isEmpty { folderMetadataStore.attachFolders(folderPaths, to: folderPath) }
    }

    func removeAttachedNote(_ path: String, from folderPath: String) {
        folderMetadataStore.removeAttachedNote(path, from: folderPath)
    }

    func removeAttachedFolder(_ path: String, from folderPath: String) {
        folderMetadataStore.removeAttachedFolder(path, from: folderPath)
    }

    // MARK: - No-vault-context toggle

    func setFolderNoVaultContext(_ value: Bool, for folderPath: String) {
        folderMetadataStore.setNoVaultContext(value, for: folderPath)
    }

    // MARK: - Read-only vault search (attachment picker)

    /// Search-as-you-type over the connected vault's notes/folders (case-insensitive over path +
    /// display name), bounded. Empty when no vault is connected.
    func searchVaultEntries(_ query: String, limit: Int = 50) -> [VaultEntry] {
        guard vaultService.isConnected else { return [] }
        return vaultService.searchEntries(query, limit: limit)
    }
}
