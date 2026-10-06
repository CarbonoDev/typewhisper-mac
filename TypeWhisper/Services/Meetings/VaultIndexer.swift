import Foundation

/// A vault note parsed for retrieval: vault-relative path id, display title, frontmatter tags and the
/// body with frontmatter stripped. Produced by `VaultIndexer`, never by a view.
struct VaultParsedNote: Sendable, Equatable {
    let id: String
    let title: String
    let tags: [String]
    let body: String
}

/// A wider-vault lexical candidate for the relevance judge (Amendment 2, DB2): a ranked note with a
/// bounded excerpt. Cheaper to feed the judge than a full `VaultPassage` — the excerpt is capped by
/// the caller's budget (DB7). Surfaced as `ObsidianVaultService.VaultCandidate`.
struct VaultNoteCandidate: Sendable, Equatable {
    let path: String
    let title: String
    let folderPath: String
    let excerpt: String
}

/// The off-main vault reading core (perf plan Phase 2, finding 10). Enumeration, note parsing and
/// lexical ranking run here — on the actor's executor, never on the main actor — and
/// `ObsidianVaultService` awaits the results. The service stays the vault's only public reader; this
/// type is its engine.
///
/// **Parse cache.** Parsed notes are cached by vault-relative path and keyed on the file's
/// modification date, size and inode, so an unchanged note is never re-read. Every call still walks
/// the vault and stats every candidate file (a folder attachment means "all `.md` under it, live at
/// retrieval time" — Amendment 1, DA5), so a note that changed, appeared or vanished on disk is
/// always seen: the vault stays the source of truth and the cache only saves the read + parse.
/// Switching vaults drops the cache; files not seen in a scan are pruned from it.
actor VaultIndexer {
    /// Scan safety bounds so retrieval over a large vault stays cheap and deterministic.
    let maxFilesScanned: Int
    let maxFileBytes: Int

    /// The identity a cached parse is valid for. Any change (an edit bumps the mtime, a rewrite of a
    /// different length changes the size, an atomic replace changes the inode) forces a re-read.
    private struct FileStamp: Equatable {
        let modificationDate: Date?
        let size: Int
        let inode: UInt64?
    }

    private struct CachedNote {
        let stamp: FileStamp
        let note: VaultParsedNote
    }

    private var cacheRoot: String?
    private var cache: [String: CachedNote] = [:]

    /// How many notes have been read from disk and parsed (cache misses) over this indexer's life.
    /// A test seam for the cache contract; not used by the app.
    private(set) var parseCount = 0

    init(maxFilesScanned: Int = 2_000, maxFileBytes: Int = 512 * 1024) {
        self.maxFilesScanned = maxFilesScanned
        self.maxFileBytes = maxFileBytes
    }

    // MARK: - Retrieval

    /// Rank the vault's notes in `scope` against `query`, returning at most `limit` bounded passages,
    /// most-relevant first. Pure lexical ranking (offline, deterministic — plan D7).
    func passages(
        in vaultPath: String,
        query: String,
        limit: Int,
        scope: VaultRetrievalScope,
        passageCharBudget: Int
    ) -> [VaultPassage] {
        if case .none = scope { return [] }
        // Filter the fresh enumeration by scope *before* ranking (Amendment 1, DA5).
        let notes = notes(in: vaultPath).filter { scope.includes($0.id) }
        return Self.rank(notes, query: query, limit: limit).map { note in
            VaultPassage(
                id: note.id,
                title: note.title,
                tags: note.tags,
                content: TranscriptContextBuilder.truncateWords(note.body, to: passageCharBudget)
            )
        }
    }

    /// Rank the wider vault against `query`, excluding every path `covered` includes (Amendment 2, DB2),
    /// each excerpt truncated to `excerptCap` (DB7).
    func candidates(
        in vaultPath: String,
        query: String,
        limit: Int,
        covered: VaultRetrievalScope,
        excerptCap: Int
    ) -> [VaultNoteCandidate] {
        guard limit > 0 else { return [] }
        let notes = notes(in: vaultPath).filter { !covered.includes($0.id) }
        return Self.rank(notes, query: query, limit: limit).map { note in
            VaultNoteCandidate(
                path: note.id,
                title: note.title,
                folderPath: (note.id as NSString).deletingLastPathComponent,
                excerpt: TranscriptContextBuilder.truncateWords(note.body, to: excerptCap)
            )
        }
    }

    // MARK: - Enumeration + cache

    /// Every readable `.md` note in the vault, parsed, sorted by path, bounded by `maxFilesScanned`.
    /// Unchanged files come from the parse cache; changed or new ones are re-read.
    func notes(in vaultPath: String) -> [VaultParsedNote] {
        if cacheRoot != vaultPath {
            cacheRoot = vaultPath
            cache = [:]
        }
        let fileManager = FileManager.default
        let root = URL(fileURLWithPath: vaultPath, isDirectory: true)
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        var notes: [VaultParsedNote] = []
        var seen: [String: CachedNote] = [:]
        for case let url as URL in enumerator {
            guard notes.count < maxFilesScanned else { break }
            guard url.pathExtension.lowercased() == "md" else { continue }
            guard let attrs = try? fileManager.attributesOfItem(atPath: url.path),
                  let size = attrs[.size] as? Int, size <= maxFileBytes else { continue }
            let id = Self.relativePath(of: url, under: root)
            let stamp = FileStamp(
                modificationDate: attrs[.modificationDate] as? Date,
                size: size,
                inode: (attrs[.systemFileNumber] as? NSNumber)?.uint64Value
            )
            if let cached = cache[id], cached.stamp == stamp {
                seen[id] = cached
                notes.append(cached.note)
                continue
            }
            guard let raw = try? String(contentsOf: url, encoding: .utf8) else { continue }
            parseCount += 1
            let note = Self.parseNote(raw, id: id)
            seen[id] = CachedNote(stamp: stamp, note: note)
            notes.append(note)
        }
        cache = seen
        // Deterministic scan order regardless of filesystem enumeration order.
        return notes.sorted { $0.id < $1.id }
    }

    // MARK: - Pure helpers (nonisolated, I/O-free unless named `enumerate…`)

    private static func rank(_ notes: [VaultParsedNote], query: String, limit: Int) -> [VaultParsedNote] {
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
        return ranked.compactMap { byID[$0.id] }
    }

    /// Case-insensitive filter over path + display name, bounded to `limit`; a blank query keeps the
    /// leading `limit` entries. Pure, so the context picker filters a cached snapshot per keystroke.
    static func filterEntries(_ entries: [VaultEntry], query: String, limit: Int) -> [VaultEntry] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered: [VaultEntry]
        if trimmed.isEmpty {
            filtered = entries
        } else {
            filtered = entries.filter {
                $0.relativePath.localizedCaseInsensitiveContains(trimmed)
                    || $0.displayName.localizedCaseInsensitiveContains(trimmed)
            }
        }
        return Array(filtered.prefix(limit))
    }

    static func enumerateEntries(in vaultPath: String, maxEntries: Int) -> [VaultEntry] {
        let root = URL(fileURLWithPath: vaultPath, isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        var entries: [VaultEntry] = []
        for case let url as URL in enumerator {
            guard entries.count < maxEntries else { break }
            let rel = relativePath(of: url, under: root)
            guard !rel.isEmpty else { continue }
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if isDirectory {
                entries.append(VaultEntry(relativePath: rel, displayName: url.lastPathComponent, isDirectory: true))
            } else if url.pathExtension.lowercased() == "md" {
                entries.append(VaultEntry(
                    relativePath: rel,
                    displayName: url.deletingPathExtension().lastPathComponent,
                    isDirectory: false
                ))
            }
        }
        // Deterministic: folders before notes, each sorted case-insensitively by relative path.
        return entries.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            return lhs.relativePath.localizedCaseInsensitiveCompare(rhs.relativePath) == .orderedAscending
        }
    }

    static func relativePath(of url: URL, under root: URL) -> String {
        let full = url.standardizedFileURL.path
        let base = root.standardizedFileURL.path
        if full.hasPrefix(base) {
            return String(full.dropFirst(base.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        return url.lastPathComponent
    }

    /// Split an optional leading `---` YAML frontmatter block from the body, extracting `tags`.
    /// The title is the first markdown `# ` heading, else the filename stem.
    static func parseNote(_ raw: String, id: String) -> VaultParsedNote {
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
        return VaultParsedNote(
            id: id,
            title: title,
            tags: tags,
            body: body.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    private static func parseTags(_ frontmatterLines: [String]) -> [String] {
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

    private static func splitTags(_ text: String) -> [String] {
        text
            .components(separatedBy: CharacterSet(charactersIn: ", "))
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "#\"' ")) }
            .filter { !$0.isEmpty }
    }

    private static func headingTitle(in body: String) -> String? {
        for line in body.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("# ") {
                return String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }
}
