import Foundation
import Combine
import AppKit
import os.log

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "TypeWhisper", category: "ObsidianVaultService")

/// A markdown note retrieved from the connected vault, ready to feed a pre-meeting brief (M5) or an
/// in-meeting Q&A answer (M6). `content` is a bounded excerpt (not necessarily the whole file).
struct VaultPassage: Sendable, Equatable {
    let id: String
    let title: String
    let tags: [String]
    let content: String
}

/// How a `retrieve` call is scoped over the vault (Amendment 1, DA5; Amendment 2, DB5/G6). The scope
/// is **computed by the services** (from a meeting's folder config) — the vault stays a pure reader.
enum VaultRetrievalScope: Equatable, Sendable {
    /// No restriction — rank every note (today's behavior; the default keeps existing callers valid).
    case wholeVault
    /// Retrieve nothing (the folder's "No vault context" toggle).
    case none
    /// Restrict to explicitly attached note paths plus every `.md` under an attached folder prefix,
    /// minus any individually excluded path. Folder prefixes match **component-wise** so `Acme` never
    /// matches `Acme2`. `excludedPaths` (Amendment 2, DB5/G6; default `[]`) subtracts a note even when
    /// it sits under a live folder prefix.
    case restricted(notePaths: Set<String>, folderPrefixes: [String], excludedPaths: Set<String> = [])

    /// Whether a vault-relative note path is in scope. Component-wise folder matching: a prefix `p`
    /// covers `rel` iff `rel == p` or `rel` starts with `p + "/"`.
    func includes(_ relativePath: String) -> Bool {
        switch self {
        case .wholeVault:
            return true
        case .none:
            return false
        case let .restricted(notePaths, folderPrefixes, excludedPaths):
            if excludedPaths.contains(relativePath) { return false }
            if notePaths.contains(relativePath) { return true }
            return folderPrefixes.contains { prefix in
                let trimmed = prefix.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
                guard !trimmed.isEmpty else { return false }
                return relativePath == trimmed || relativePath.hasPrefix(trimmed + "/")
            }
        }
    }
}

/// A single vault note read once (Track E, ME-3): the raw file text (frontmatter included) plus the
/// resolved `typewhisper-meeting` backlink, derived from the same read so the reader touches disk once.
struct VaultNoteRead: Sendable, Equatable {
    let body: String
    let meetingID: UUID?
}

/// A vault entry (note or folder) for the read-only context picker (Amendment 1, DA8). Cheaper than
/// `VaultPassage` — no body parse; just the relative path and a display name.
struct VaultEntry: Identifiable, Sendable, Equatable {
    let relativePath: String
    let displayName: String
    let isDirectory: Bool

    var id: String { (isDirectory ? "d:" : "f:") + relativePath }
}

/// First-party vault READING service (plan D9): the `ObsidianPlugin` bundle is untouched and its
/// helpers are private, so core re-implements the ~20-line `obsidian.json` vault detection plus
/// markdown enumeration, frontmatter/tag parsing, and lexical retrieval in-process. The chosen
/// vault path is persisted in the app's own UserDefaults (independent of the plugin's scoped
/// defaults); auto-detect is the default, with an `NSOpenPanel` manual override.
@MainActor
final class ObsidianVaultService: ObservableObject {
    /// A detected Obsidian vault (from `~/Library/Application Support/obsidian/obsidian.json`).
    struct VaultInfo: Identifiable, Equatable {
        let id: String
        let path: String
        let name: String
        let timestamp: Int
    }

    /// Absolute path of the connected vault, or `nil` when none is connected.
    @Published private(set) var vaultPath: String?

    var isConnected: Bool { vaultPath != nil }
    var vaultName: String? {
        guard let vaultPath else { return nil }
        return (vaultPath as NSString).lastPathComponent
    }

    private let defaults: UserDefaults
    private let fileManager = FileManager.default

    /// Scan safety bounds so retrieval over a large vault stays cheap and deterministic.
    private let maxFilesScanned = 2_000

    /// The upper bound `listEntries()` (and the retrieval scanners) enforce on entries scanned.
    /// Exposed read-only so callers that reuse the snapshot (Track E's Space browser) can honestly
    /// report a truncated index without mirroring the constant — if the cap moves, they follow.
    var maxEntriesScanned: Int { maxFilesScanned }
    private let maxFileBytes = 512 * 1024
    private let passageCharBudget = 2_000

    /// The off-main enumerate / parse / rank engine, holding the mtime-keyed parse cache.
    private let indexer: VaultIndexer

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.indexer = VaultIndexer(maxFilesScanned: maxFilesScanned, maxFileBytes: maxFileBytes)
        let stored = defaults.string(forKey: UserDefaultsKeys.meetingsObsidianVaultPath)
        if let stored, fileManager.fileExists(atPath: stored) {
            self.vaultPath = stored
        } else {
            self.vaultPath = nil
        }
    }

    // MARK: - Detection & connection

    /// Detected vaults from Obsidian's config, most-recently-opened first. Empty when Obsidian
    /// isn't installed or has no vaults.
    static func detectVaults() -> [VaultInfo] {
        let configPath = NSHomeDirectory() + "/Library/Application Support/obsidian/obsidian.json"
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: configPath)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let vaults = json["vaults"] as? [String: [String: Any]] else {
            return []
        }
        var result: [VaultInfo] = []
        for (hash, info) in vaults {
            guard let path = info["path"] as? String else { continue }
            let name = (path as NSString).lastPathComponent
            let ts = info["ts"] as? Int ?? 0
            result.append(VaultInfo(id: hash, path: path, name: name, timestamp: ts))
        }
        return result.sorted { $0.timestamp > $1.timestamp }
    }

    /// Connect to the most-recently-opened detected vault whose path still exists, if any and none
    /// is already connected. `connect(to:)` refuses a stale (deleted) path, so we iterate the
    /// detected vaults (most-recent first) until one actually connects rather than assuming the
    /// first candidate is valid (M5 review finding 1). Returns whether a vault is connected
    /// afterwards.
    @discardableResult
    func autoConnect() -> Bool {
        if isConnected { return true }
        for vault in Self.detectVaults() {
            connect(to: vault.path)
            if isConnected { break }
        }
        return isConnected
    }

    /// Connect to (and persist) a specific vault path.
    func connect(to path: String) {
        guard fileManager.fileExists(atPath: path) else {
            logger.error("Refusing to connect to non-existent vault path")
            return
        }
        vaultPath = path
        defaults.set(path, forKey: UserDefaultsKeys.meetingsObsidianVaultPath)
    }

    /// Prompt the user to pick a vault folder (`NSOpenPanel`) and connect to the choice.
    func chooseVault() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "meetings.vault.chooseButton")
        if panel.runModal() == .OK, let url = panel.url {
            connect(to: url.path)
        }
    }

    /// Forget the connected vault (retrieval returns nothing until reconnected).
    func disconnect() {
        vaultPath = nil
        defaults.removeObject(forKey: UserDefaultsKeys.meetingsObsidianVaultPath)
    }

    // MARK: - Retrieval

    /// Rank the vault's markdown notes against `query`, returning at most `limit` bounded passages,
    /// most-relevant first. Empty when no vault is connected or nothing matches. Pure lexical
    /// ranking (offline, deterministic — plan D7). The walk, parse and rank run off the main actor in
    /// `VaultIndexer`; a folder attachment still resolves live, because every call re-enumerates
    /// (Amendment 1, DA5) — only unchanged notes' parses are reused.
    func retrieve(query: String, limit: Int = 3, scope: VaultRetrievalScope = .wholeVault) async -> [VaultPassage] {
        guard let vaultPath else { return [] }
        if case .none = scope { return [] }
        return await indexer.passages(
            in: vaultPath, query: query, limit: limit, scope: scope, passageCharBudget: passageCharBudget
        )
    }

    // MARK: - Related-docs candidate generation (Amendment 2, DB2)

    typealias VaultCandidate = VaultNoteCandidate

    /// Rank the wider vault against `query` and return the top `limit` candidates, **excluding** every
    /// already-covered path — stage-(a) folder notes + existing manual/excluded paths (`excludingPaths`)
    /// and every attached folder prefix (`excludingFolderPrefixes`, component-wise so `Acme` never
    /// covers `Acme2`) (Amendment 2, DB2). Reuses the same enumerator + `LexicalRetriever` as `retrieve`;
    /// each excerpt is truncated to `excerptCap` (DB7). Empty when no vault is connected.
    func candidateNotes(
        query: String,
        limit: Int,
        excludingPaths: Set<String>,
        excludingFolderPrefixes: [String],
        excerptCap: Int
    ) async -> [VaultCandidate] {
        guard let vaultPath else { return [] }
        guard limit > 0 else { return [] }
        // Reuse the tested scope predicate to identify covered paths (a note is covered iff it is an
        // excluded/attached path or sits under an attached folder prefix).
        let covered = VaultRetrievalScope.restricted(
            notePaths: excludingPaths,
            folderPrefixes: excludingFolderPrefixes
        )
        return await indexer.candidates(
            in: vaultPath, query: query, limit: limit, covered: covered, excerptCap: excerptCap
        )
    }

    /// Whether a vault-relative `.md` path resolves to an existing file (Amendment 2, DB4 —
    /// show-as-missing). `false` when no vault is connected or the path is a directory / gone.
    func noteExists(_ relativePath: String) -> Bool {
        guard let vaultPath else { return false }
        let rel = MeetingService.normalizeVaultRelPath(relativePath)
        guard !rel.isEmpty else { return false }
        let url = URL(fileURLWithPath: vaultPath, isDirectory: true).appendingPathComponent(rel)
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) && !isDirectory.boolValue
    }

    // MARK: - Single-note read (Track E, ME-2 — off the enumeration path)

    /// The full text of one vault note, or `nil` when no vault is connected, the path is empty, escapes
    /// the vault (traversal), points at a missing file, exceeds `maxFileBytes`, or isn't UTF-8. This is
    /// a **single direct read**, deliberately off the enumeration path — it never touches
    /// `enumerateNotes`/`enumerateEntries`, so the single-enumerator rule (spec §3) stays intact. The
    /// returned string is the raw file (frontmatter included); Space strips it for display.
    func readNote(_ relativePath: String) -> String? {
        guard let url = resolvedNoteURL(for: relativePath) else { return nil }
        return Self.readBoundedFile(at: url, maxBytes: maxFileBytes)
    }

    /// The size-bounded UTF-8 read behind `readNote`, free of actor state so it can run off main.
    nonisolated private static func readBoundedFile(at url: URL, maxBytes: Int) -> String? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int, size <= maxBytes else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    /// The `typewhisper-meeting` frontmatter UUID of a vault note (Track E, ME-2, the Space↔meeting
    /// bridge). `nil` when the note is unreadable, carries no (or malformed) frontmatter, has no such
    /// field, or the value isn't a UUID — tolerant by design: a note never errors, it just doesn't
    /// offer the bridge. Existence of the referenced meeting is resolved by the caller.
    func meetingID(inNoteAt relativePath: String) -> UUID? {
        guard let raw = readNote(relativePath) else { return nil }
        guard let value = Self.frontmatterField("typewhisper-meeting", in: raw) else { return nil }
        return UUID(uuidString: value)
    }

    /// Read a note **once** and derive both its raw body and its `typewhisper-meeting` backlink from the
    /// same file access (Track E, ME-3 — folding the note reader's former two reads, `readNote` then
    /// `meetingID`, into one). `nil` on the same unreadable/missing/out-of-vault conditions as `readNote`;
    /// the `meetingID` stays tolerant (absent/malformed/non-UUID ⇒ `nil` without failing the read).
    func readNoteWithBacklink(_ relativePath: String) -> VaultNoteRead? {
        guard let raw = readNote(relativePath) else { return nil }
        return Self.noteRead(from: raw)
    }

    /// `readNoteWithBacklink` with the file read and frontmatter scan off the main actor (the Space
    /// note reader's load). Same path resolution and the same `nil` conditions.
    func loadNoteWithBacklink(_ relativePath: String) async -> VaultNoteRead? {
        guard let url = resolvedNoteURL(for: relativePath) else { return nil }
        let maxBytes = maxFileBytes
        return await Task.detached(priority: .userInitiated) {
            Self.readBoundedFile(at: url, maxBytes: maxBytes).map(Self.noteRead(from:))
        }.value
    }

    nonisolated private static func noteRead(from raw: String) -> VaultNoteRead {
        let meetingID = frontmatterField("typewhisper-meeting", in: raw).flatMap { UUID(uuidString: $0) }
        return VaultNoteRead(body: raw, meetingID: meetingID)
    }

    /// Resolve a vault-relative note path to an absolute file URL **only if it stays inside the vault**
    /// (traversal rejection). Trims via `MeetingService.normalizeVaultRelPath`, then compares the
    /// standardized (../-resolved) target against the standardized vault root — off the enumeration
    /// path, matching `noteExists`' style.
    private func resolvedNoteURL(for relativePath: String) -> URL? {
        guard let vaultPath else { return nil }
        let rel = MeetingService.normalizeVaultRelPath(relativePath)
        guard !rel.isEmpty else { return nil }
        let root = URL(fileURLWithPath: vaultPath, isDirectory: true)
        let target = root.appendingPathComponent(rel)
        let rootPath = root.standardizedFileURL.path
        let targetPath = target.standardizedFileURL.path
        guard targetPath == rootPath || targetPath.hasPrefix(rootPath + "/") else { return nil }
        return target
    }

    /// Extract a single scalar YAML frontmatter field's value from a note's raw text (Track E, ME-2).
    /// Tolerant: returns `nil` unless the file opens with a `---` line and has a matching closing `---`,
    /// then finds the first `key:`-prefixed line inside (case-insensitive key match). The value is
    /// trimmed and, when wrapped in double quotes, unquoted to mirror the exporter's `yamlScalar`
    /// quoting. Empty values yield `nil`.
    nonisolated private static func frontmatterField(_ key: String, in raw: String) -> String? {
        let lines = raw.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return nil }
        var closingIndex: Int?
        for index in 1..<lines.count where lines[index].trimmingCharacters(in: .whitespaces) == "---" {
            closingIndex = index
            break
        }
        guard let closingIndex else { return nil }
        for index in 1..<closingIndex {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            guard let colon = trimmed.firstIndex(of: ":") else { continue }
            let fieldKey = String(trimmed[..<colon]).trimmingCharacters(in: .whitespaces)
            guard fieldKey.caseInsensitiveCompare(key) == .orderedSame else { continue }
            let rawValue = String(trimmed[trimmed.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            let value = unquoteYAMLScalar(rawValue)
            return value.isEmpty ? nil : value
        }
        return nil
    }

    /// Reverse `MeetingObsidianExporter.yamlScalar`'s quoting: strip surrounding double quotes and
    /// unescape `\"`/`\\`. A plain (unquoted) scalar is returned unchanged.
    nonisolated private static func unquoteYAMLScalar(_ value: String) -> String {
        guard value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") else { return value }
        let inner = String(value.dropFirst().dropLast())
        return inner
            .replacingOccurrences(of: "\\\"", with: "\"")
            .replacingOccurrences(of: "\\\\", with: "\\")
    }

    // MARK: - Read-only listing (Amendment 1, DA8 — shared vault-enumeration primitive)

    /// Every note and folder in the vault as lightweight `VaultEntry` values — no body parse (cheaper
    /// than `retrieve`). Deterministic (folders first, then notes, each sorted by path) and bounded.
    /// Empty when no vault is connected. The single vault-enumeration primitive the attachment picker
    /// and Space consume (plan §4); the walk runs off the main actor, and callers cache the snapshot.
    func listEntries() async -> [VaultEntry] {
        guard let vaultPath else { return [] }
        let maxEntries = maxFilesScanned
        return await Task.detached(priority: .userInitiated) {
            VaultIndexer.enumerateEntries(in: vaultPath, maxEntries: maxEntries)
        }.value
    }

    /// Case-insensitive search over note/folder path + display name, bounded to `limit`. A blank query
    /// returns the leading `limit` entries. Re-enumerates; a per-keystroke caller should take one
    /// `listEntries()` snapshot and filter it with `filterEntries` instead.
    func searchEntries(_ query: String, limit: Int = 50) async -> [VaultEntry] {
        Self.filterEntries(await listEntries(), query: query, limit: limit)
    }

    /// Pure in-memory filter of an entries snapshot (the picker's search-as-you-type, DA8).
    nonisolated static func filterEntries(_ entries: [VaultEntry], query: String, limit: Int = 50) -> [VaultEntry] {
        VaultIndexer.filterEntries(entries, query: query, limit: limit)
    }
}
