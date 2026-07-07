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
    private let maxFileBytes = 512 * 1024
    private let passageCharBudget = 2_000

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
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

    /// Connect to the most-recently-opened detected vault, if any and none is already connected.
    /// Returns whether a vault is connected afterwards.
    @discardableResult
    func autoConnect() -> Bool {
        if isConnected { return true }
        guard let latest = Self.detectVaults().first else { return false }
        connect(to: latest.path)
        return true
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
    /// ranking (offline, deterministic — plan D7).
    func retrieve(query: String, limit: Int = 3) -> [VaultPassage] {
        guard let vaultPath else { return [] }
        let notes = enumerateNotes(in: vaultPath)
        guard !notes.isEmpty else { return [] }

        let documents = notes.map { note in
            // Title and tags are weighted only by inclusion in the searchable text (kept simple).
            LexicalRetriever.Document(
                id: note.id,
                text: ([note.title] + note.tags + [note.body]).joined(separator: " ")
            )
        }
        let ranked = LexicalRetriever.rank(query: query, documents: documents, limit: limit)
        let byID = Dictionary(uniqueKeysWithValues: notes.map { ($0.id, $0) })
        return ranked.compactMap { result in
            guard let note = byID[result.id] else { return nil }
            return VaultPassage(
                id: note.id,
                title: note.title,
                tags: note.tags,
                content: TranscriptContextBuilder.truncateWords(note.body, to: passageCharBudget)
            )
        }
    }

    // MARK: - Note parsing

    private struct ParsedNote {
        let id: String
        let title: String
        let tags: [String]
        let body: String
    }

    private func enumerateNotes(in vaultPath: String) -> [ParsedNote] {
        let root = URL(fileURLWithPath: vaultPath, isDirectory: true)
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        var notes: [ParsedNote] = []
        for case let url as URL in enumerator {
            guard notes.count < maxFilesScanned else { break }
            guard url.pathExtension.lowercased() == "md" else { continue }
            guard let attrs = try? fileManager.attributesOfItem(atPath: url.path),
                  let size = attrs[.size] as? Int, size <= maxFileBytes else { continue }
            guard let raw = try? String(contentsOf: url, encoding: .utf8) else { continue }
            notes.append(parseNote(raw, id: relativePath(of: url, under: root)))
        }
        // Deterministic scan order regardless of filesystem enumeration order.
        return notes.sorted { $0.id < $1.id }
    }

    private func relativePath(of url: URL, under root: URL) -> String {
        let full = url.standardizedFileURL.path
        let base = root.standardizedFileURL.path
        if full.hasPrefix(base) {
            return String(full.dropFirst(base.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        return url.lastPathComponent
    }

    /// Split an optional leading `---` YAML frontmatter block from the body, extracting `tags`.
    /// The title is the first markdown `# ` heading, else the filename stem.
    private func parseNote(_ raw: String, id: String) -> ParsedNote {
        var tags: [String] = []
        var body = raw

        let lines = raw.components(separatedBy: "\n")
        if lines.first?.trimmingCharacters(in: .whitespaces) == "---" {
            var frontmatterLines: [String] = []
            var closingIndex: Int?
            for index in 1..<lines.count {
                if lines[index].trimmingCharacters(in: .whitespaces) == "---" {
                    closingIndex = index
                    break
                }
                frontmatterLines.append(lines[index])
            }
            if let closingIndex {
                tags = parseTags(frontmatterLines)
                body = lines[(closingIndex + 1)...].joined(separator: "\n")
            }
        }

        let title = headingTitle(in: body) ?? (id as NSString).lastPathComponent.replacingOccurrences(of: ".md", with: "")
        return ParsedNote(
            id: id,
            title: title,
            tags: tags,
            body: body.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    private func parseTags(_ frontmatterLines: [String]) -> [String] {
        var tags: [String] = []
        var index = 0
        while index < frontmatterLines.count {
            let line = frontmatterLines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.lowercased().hasPrefix("tags:") {
                let remainder = trimmed.dropFirst("tags:".count).trimmingCharacters(in: .whitespaces)
                if remainder.hasPrefix("[") {
                    // Inline list: tags: [a, b, c]
                    let inner = remainder.dropFirst().dropLast(remainder.hasSuffix("]") ? 1 : 0)
                    tags.append(contentsOf: splitTags(String(inner)))
                } else if !remainder.isEmpty {
                    // Space/comma-separated on the same line: tags: a b, c
                    tags.append(contentsOf: splitTags(remainder))
                } else {
                    // Multi-line YAML list of `- tag` entries following the key.
                    var next = index + 1
                    while next < frontmatterLines.count {
                        let itemLine = frontmatterLines[next].trimmingCharacters(in: .whitespaces)
                        guard itemLine.hasPrefix("-") else { break }
                        let tag = itemLine.dropFirst().trimmingCharacters(in: .whitespaces)
                        if !tag.isEmpty { tags.append(tag) }
                        next += 1
                    }
                    index = next - 1
                }
            }
            index += 1
        }
        return tags
    }

    private func splitTags(_ text: String) -> [String] {
        text
            .components(separatedBy: CharacterSet(charactersIn: ", "))
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "#\"' ")) }
            .filter { !$0.isEmpty }
    }

    private func headingTitle(in body: String) -> String? {
        for line in body.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("# ") {
                return String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }
}
