import Foundation

/// Extracts action items and decisions out of LLM-generated meeting-output markdown so the completed
/// meeting document can lead with structured outcomes instead of a prose blob (Sprint 1).
///
/// The parser is deliberately **strict-match-or-passthrough**: it only lifts a section out when it
/// finds a recognizable EN/ES outcome heading with at least one list item or markdown-table row
/// under it, and otherwise returns the input untouched. Generated markdown varies by provider and
/// template, so the worst case must always degrade to "render the summary as before", never to a
/// mangled document.
enum MeetingOutputParser {
    struct ActionItem: Equatable, Sendable {
        var text: String
        var assignee: String?
        /// Deterministic identity for done-state persistence (`MeetingChecklistStore`). Derived from
        /// the normalized text with FNV-1a rather than `Hashable` so it is stable across processes
        /// and regenerations that reproduce the same item wording.
        var stableID: String
    }

    struct ExtractedOutcomes: Equatable, Sendable {
        var actions: [ActionItem]
        var decisions: [String]
        /// The input markdown with successfully extracted sections (heading + list items) removed,
        /// so the article body doesn't repeat what the outcome cards already show. Equal to the
        /// input when nothing was extracted.
        var strippedMarkdown: String
    }

    // MARK: - Parse

    static func parse(markdown: String) -> ExtractedOutcomes {
        guard !markdown.isEmpty else {
            return ExtractedOutcomes(actions: [], decisions: [], strippedMarkdown: markdown)
        }

        let lines = markdown.components(separatedBy: "\n")
        var actions: [ActionItem] = []
        var decisions: [String] = []
        var removed = Set<Int>()

        var i = 0
        while i < lines.count {
            guard let heading = headingInfo(lines[i]), let kind = classify(heading.title) else {
                i += 1
                continue
            }

            // Section body: everything up to the next same-or-higher-level heading. Bold
            // pseudo-headings always terminate (LLM output uses them as peer section markers).
            var j = i + 1
            var itemLines: [Int] = []
            var pipeLines: [Int] = []
            var subheadingLines: [Int] = []
            while j < lines.count {
                if let next = headingInfo(lines[j]) {
                    if next.isPseudo || next.level <= heading.level {
                        break
                    }
                    // Deeper real subheading inside the section ("### Equipo A") — remembered so a
                    // fully-consumed subsection doesn't leave an orphan heading in the stripped text.
                    subheadingLines.append(j)
                }
                if listItemText(lines[j]) != nil {
                    itemLines.append(j)
                } else if lines[j].trimmingCharacters(in: .whitespaces).hasPrefix("|") {
                    pipeLines.append(j)
                }
                j += 1
            }

            var sectionActions: [ActionItem] = []
            var sectionDecisions: [String] = []
            for idx in itemLines {
                guard let raw = listItemText(lines[idx]) else { continue }
                switch kind {
                case .actions:
                    let (text, assignee) = splitAssignee(raw)
                    let trimmed = text.trimmingCharacters(in: .whitespaces)
                    guard !trimmed.isEmpty else { continue }
                    sectionActions.append(
                        ActionItem(
                            text: trimmed,
                            assignee: assignee,
                            stableID: stableID(for: trimmed, assignee: assignee)
                        )
                    )
                case .decisions:
                    let trimmed = raw.trimmingCharacters(in: .whitespaces)
                    guard !trimmed.isEmpty else { continue }
                    sectionDecisions.append(trimmed)
                }
            }

            // Markdown tables inside a matched section: extract rows from every consecutive run of
            // `|`-prefixed lines that parses to usable rows. Only yielding runs are removed, so a
            // stray or unparsable table passes through untouched.
            var tableLines: [Int] = []
            for run in consecutiveRuns(pipeLines) {
                guard let rows = parseTable(lines: lines, runIndices: run) else { continue }
                for row in rows {
                    switch kind {
                    case .actions:
                        var text = row.task
                        var assignee = row.owner
                        if assignee == nil {
                            let split = splitAssignee(text)
                            text = split.text
                            assignee = split.assignee
                        }
                        if let due = row.due {
                            text += " — \(due)"
                        }
                        guard !text.isEmpty else { continue }
                        sectionActions.append(
                            ActionItem(
                                text: text,
                                assignee: assignee,
                                stableID: stableID(for: text, assignee: assignee)
                            )
                        )
                    case .decisions:
                        sectionDecisions.append(row.task)
                    }
                }
                tableLines.append(contentsOf: run)
            }

            if sectionActions.isEmpty && sectionDecisions.isEmpty {
                // Matched heading but no usable items (prose section): leave it in place and keep
                // scanning inside it — a deeper heading may still match.
                i += 1
            } else {
                actions.append(contentsOf: sectionActions)
                decisions.append(contentsOf: sectionDecisions)
                removed.insert(i)
                removed.formUnion(itemLines)
                removed.formUnion(tableLines)
                // A subheading whose entire subsection was consumed (only extracted/blank lines up
                // to the next heading) must go too, or the stripped article shows empty orphan
                // headings; one with surviving prose stays to head that prose.
                let consumedSet = Set(itemLines).union(tableLines)
                for subheading in subheadingLines {
                    var k = subheading + 1
                    var fullyConsumed = true
                    while k < j {
                        if headingInfo(lines[k]) != nil { break }
                        let isBlank = lines[k].trimmingCharacters(in: .whitespaces).isEmpty
                        if !isBlank, !consumedSet.contains(k) {
                            fullyConsumed = false
                            break
                        }
                        k += 1
                    }
                    if fullyConsumed { removed.insert(subheading) }
                }
                i = j
            }
        }

        guard !removed.isEmpty else {
            return ExtractedOutcomes(actions: [], decisions: [], strippedMarkdown: markdown)
        }

        return ExtractedOutcomes(
            actions: dedupedByStableID(actions),
            decisions: decisions,
            strippedMarkdown: strippedMarkdown(lines: lines, removed: removed)
        )
    }

    // MARK: - Agenda (pre-meeting brief)

    struct ExtractedAgenda: Equatable, Sendable {
        var items: [ActionItem]
        /// The brief markdown with the extracted talking-points section removed (heading + items);
        /// equal to the input when nothing matched.
        var strippedMarkdown: String
    }

    /// EN/ES stems for the brief's talking-points section ("Puntos de Discusión Sugeridos",
    /// "Suggested talking points", "Agenda"). Kept separate from the summary keyword sets — an
    /// "Agenda" heading inside a *summary* is minutes structure, not extractable outcomes.
    private static let agendaKeywordStems = [
        "talking point", "discussion point", "topics to discuss", "agenda",
        "puntos de discusion", "puntos sugeridos", "puntos para discutir",
        "temas a tratar", "temas sugeridos", "temas de discusion",
    ]

    /// Extract the brief's talking points as checkable agenda items (Sprint follow-up). Same
    /// strict-match-or-passthrough contract as `parse`: no recognizable section with list items →
    /// the input comes back untouched. Items carry no assignees — talking points aren't tasks —
    /// and their stableIDs feed the same `MeetingChecklistStore` so checked-off points survive the
    /// scheduled → live transition.
    static func parseAgenda(markdown: String) -> ExtractedAgenda {
        guard !markdown.isEmpty else {
            return ExtractedAgenda(items: [], strippedMarkdown: markdown)
        }

        let lines = markdown.components(separatedBy: "\n")
        var items: [ActionItem] = []
        var removed = Set<Int>()

        var i = 0
        while i < lines.count {
            guard let heading = headingInfo(lines[i]),
                  agendaKeywordStems.contains(where: { normalized(heading.title).contains($0) }) else {
                i += 1
                continue
            }

            var j = i + 1
            var itemLines: [Int] = []
            while j < lines.count {
                if let next = headingInfo(lines[j]), next.isPseudo || next.level <= heading.level {
                    break
                }
                if listItemText(lines[j]) != nil {
                    itemLines.append(j)
                }
                j += 1
            }

            var sectionItems: [ActionItem] = []
            for idx in itemLines {
                guard let raw = listItemText(lines[idx]) else { continue }
                let trimmed = raw.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { continue }
                sectionItems.append(
                    ActionItem(text: trimmed, assignee: nil, stableID: stableID(for: trimmed))
                )
            }

            if sectionItems.isEmpty {
                i += 1
            } else {
                items.append(contentsOf: sectionItems)
                removed.insert(i)
                removed.formUnion(itemLines)
                i = j
            }
        }

        guard !removed.isEmpty else {
            return ExtractedAgenda(items: [], strippedMarkdown: markdown)
        }
        return ExtractedAgenda(
            items: dedupedByStableID(items),
            strippedMarkdown: strippedMarkdown(lines: lines, removed: removed)
        )
    }

    /// Stable identity for an action item: FNV-1a 64 over the case/diacritic-folded,
    /// whitespace-collapsed wording plus the assignee — two people can carry the same task text
    /// without colliding to one checkbox. Not `hashValue`, which is seeded per process.
    static func stableID(for text: String, assignee: String? = nil) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        var seed = normalized(text)
        if let assignee, !assignee.isEmpty {
            seed += "|" + normalized(assignee)
        }
        for byte in seed.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(format: "%016llx", hash)
    }

    /// Last line of defense for identity: identical text AND assignee still must not produce
    /// duplicate `ForEach` IDs, so repeats get a positional suffix. (Their done-state intentionally
    /// tracks per occurrence.)
    private static func dedupedByStableID(_ items: [ActionItem]) -> [ActionItem] {
        var occurrences: [String: Int] = [:]
        return items.map { item in
            let count = occurrences[item.stableID, default: 0]
            occurrences[item.stableID] = count + 1
            guard count > 0 else { return item }
            var copy = item
            copy.stableID = "\(item.stableID)#\(count)"
            return copy
        }
    }

    // MARK: - Section classification

    private enum SectionKind {
        case actions
        case decisions
    }

    /// EN/ES keyword stems matched by containment against the folded heading title. Actions are
    /// checked first so a mixed heading ("Tareas y acuerdos") lands on the side that produces
    /// checkable items. A bare "acuerdos" (agreements) is a decisions heading, not actions.
    private static let actionKeywordStems = [
        "action item", "next step", "task", "follow-up", "follow up",
        "accion", "tarea", "proximo paso", "proximos pasos", "pendiente", "por hacer", "to-do", "to do",
    ]

    private static let decisionKeywordStems = [
        "decision", "acuerdo", "resolucion",
    ]

    private static func classify(_ title: String) -> SectionKind? {
        let folded = normalized(title)
        guard !folded.isEmpty else { return nil }
        if actionKeywordStems.contains(where: { folded.contains($0) }) { return .actions }
        if decisionKeywordStems.contains(where: { folded.contains($0) }) { return .decisions }
        return nil
    }

    // MARK: - Line scanning

    private struct Heading {
        let level: Int
        let title: String
        let isPseudo: Bool
    }

    private static func headingInfo(_ line: String) -> Heading? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)

        if trimmed.hasPrefix("#") {
            let hashes = trimmed.prefix(while: { $0 == "#" })
            guard hashes.count <= 6 else { return nil }
            var title = trimmed.dropFirst(hashes.count).trimmingCharacters(in: .whitespaces)
            while title.hasSuffix("#") {
                title = String(title.dropLast()).trimmingCharacters(in: .whitespaces)
            }
            return Heading(level: hashes.count, title: title, isPseudo: false)
        }

        // Bold pseudo-heading: `**Acuerdos**`, `**Acuerdos:**` or `**Acuerdos**:` alone on a line.
        for marker in ["**", "__"] where trimmed.hasPrefix(marker) && trimmed.count > 4 {
            var inner = trimmed.dropFirst(marker.count)
            if inner.hasSuffix(":") { inner = inner.dropLast() }
            guard inner.hasSuffix(marker) else { continue }
            inner = inner.dropLast(marker.count)
            if inner.hasSuffix(":") { inner = inner.dropLast() }
            let title = inner.trimmingCharacters(in: .whitespaces)
            guard !title.isEmpty, !title.contains("**"), !title.contains("__") else { continue }
            return Heading(level: 6, title: title, isPseudo: true)
        }

        return nil
    }

    private static func listItemText(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)

        for bullet in ["- ", "* ", "+ "] where trimmed.hasPrefix(bullet) {
            var rest = String(trimmed.dropFirst(bullet.count)).trimmingCharacters(in: .whitespaces)
            for box in ["[ ]", "[x]", "[X]"] where rest.hasPrefix(box) {
                rest = String(rest.dropFirst(box.count)).trimmingCharacters(in: .whitespaces)
                break
            }
            return rest
        }

        let digits = trimmed.prefix(while: { $0.isNumber })
        if !digits.isEmpty, digits.count <= 3 {
            let after = trimmed.dropFirst(digits.count)
            if after.hasPrefix(". ") || after.hasPrefix(") ") {
                return String(after.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            }
        }

        return nil
    }

    // MARK: - Table scanning

    private struct ParsedTableRow {
        var task: String
        var owner: String?
        var due: String?
    }

    /// EN/ES header stems for locating table columns, matched by containment against the folded
    /// header cell. The task column is checked first per cell so a header that could match two
    /// classes lands on the side that produces item text.
    private static let tableTaskStems = [
        "task", "tarea", "action", "accion", "item", "description", "descripcion",
        // A decisions-section table heads its text column "Decisión"/"Acuerdo" — without these the
        // widest-column fallback could pick a longer context column instead.
        "decision", "acuerdo", "resolucion",
    ]

    private static let tableOwnerStems = [
        "owner", "assignee", "responsable", "quien", "asignado", "encargado",
    ]

    private static let tableDueStems = [
        "due", "fecha", "plazo", "deadline",
    ]

    private static func consecutiveRuns(_ indices: [Int]) -> [[Int]] {
        var runs: [[Int]] = []
        var current: [Int] = []
        for idx in indices {
            if let last = current.last, idx == last + 1 {
                current.append(idx)
            } else {
                if !current.isEmpty { runs.append(current) }
                current = [idx]
            }
        }
        if !current.isEmpty { runs.append(current) }
        return runs
    }

    /// Parse one run of consecutive `|`-prefixed lines into rows. A header row is recognized by the
    /// standard alignment-separator second line; its cells locate the task/owner/due columns by
    /// stem containment. Without a header (or without a task-stem match) the widest column by total
    /// text is the task column and owner/due stay unknown. Returns nil when no usable row survives
    /// so the caller leaves the run in place.
    private static func parseTable(lines: [String], runIndices: [Int]) -> [ParsedTableRow]? {
        let allRows = runIndices.map { tableCells(lines[$0]) }
        let hasHeader = allRows.count >= 2 && isSeparatorRow(allRows[1]) && !isSeparatorRow(allRows[0])

        var dataRows: [[String]] = []
        for (offset, cells) in allRows.enumerated() {
            if hasHeader && offset == 0 { continue }
            if isSeparatorRow(cells) { continue }
            dataRows.append(cells)
        }
        guard !dataRows.isEmpty else { return nil }

        var taskCol: Int?
        var ownerCol: Int?
        var dueCol: Int?
        if hasHeader {
            for (idx, cell) in allRows[0].enumerated() {
                let folded = normalized(cell.replacingOccurrences(of: "*", with: ""))
                if taskCol == nil, tableTaskStems.contains(where: { folded.contains($0) }) {
                    taskCol = idx
                    continue
                }
                if ownerCol == nil, tableOwnerStems.contains(where: { folded.contains($0) }) {
                    ownerCol = idx
                    continue
                }
                if dueCol == nil, tableDueStems.contains(where: { folded.contains($0) }) {
                    dueCol = idx
                    continue
                }
            }
        }
        if taskCol == nil {
            taskCol = widestColumn(of: dataRows)
        }
        guard let taskIndex = taskCol else { return nil }

        var result: [ParsedTableRow] = []
        for cells in dataRows {
            guard taskIndex < cells.count else { continue }
            let task = cells[taskIndex]
            guard !task.isEmpty, !isDashOnly(task) else { continue }

            var owner: String?
            if let ownerCol, ownerCol < cells.count {
                let cleaned = cells[ownerCol]
                    .replacingOccurrences(of: "**", with: "")
                    .trimmingCharacters(in: .whitespaces)
                if !cleaned.isEmpty, !isDashOnly(cleaned) { owner = cleaned }
            }

            var due: String?
            if let dueCol, dueCol < cells.count {
                let cleaned = cells[dueCol].trimmingCharacters(in: .whitespaces)
                if !cleaned.isEmpty, !isDashOnly(cleaned) { due = cleaned }
            }

            result.append(ParsedTableRow(task: task, owner: owner, due: due))
        }
        return result.isEmpty ? nil : result
    }

    private static func tableCells(_ line: String) -> [String] {
        var trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("|") { trimmed.removeFirst() }
        if trimmed.hasSuffix("|") { trimmed.removeLast() }
        return trimmed
            .components(separatedBy: "|")
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func isSeparatorRow(_ cells: [String]) -> Bool {
        guard !cells.isEmpty else { return false }
        return cells.allSatisfy { cell in
            !cell.isEmpty && cell.contains("-") && cell.allSatisfy { $0 == "-" || $0 == ":" }
        }
    }

    private static func widestColumn(of rows: [[String]]) -> Int? {
        guard let maxCount = rows.map(\.count).max(), maxCount > 0 else { return nil }
        var best: (index: Int, width: Int)?
        for col in 0..<maxCount {
            let width = rows.reduce(0) { $0 + (col < $1.count ? $1[col].count : 0) }
            if best == nil || width > best!.width {
                best = (col, width)
            }
        }
        return best?.index
    }

    /// "Empty" markers LLMs put in table cells: any run of hyphens/em/en dashes.
    private static func isDashOnly(_ string: String) -> Bool {
        !string.isEmpty && string.allSatisfy { $0 == "-" || $0 == "—" || $0 == "–" }
    }

    // MARK: - Assignee heuristic

    /// Leading `**Name:**` / `**Name**:` / `Name:` (1–3 capitalized words) or an `@name` token
    /// anywhere. The marker is stripped from the returned text. Lowercase prefixes ("http:", times)
    /// fail the capitalization check and pass through untouched.
    private static func splitAssignee(_ raw: String) -> (text: String, assignee: String?) {
        var text = raw.trimmingCharacters(in: .whitespaces)

        if text.hasPrefix("**"), text.count > 4 {
            let innerStart = text.index(text.startIndex, offsetBy: 2)
            if let closeRange = text.range(of: "**", range: innerStart..<text.endIndex) {
                let inner = String(text[innerStart..<closeRange.lowerBound])
                var name: String?
                var restStart: String.Index?
                if inner.hasSuffix(":") {
                    name = String(inner.dropLast())
                    restStart = closeRange.upperBound
                } else if text[closeRange.upperBound...].hasPrefix(":") {
                    name = inner
                    restStart = text.index(after: closeRange.upperBound)
                }
                if let name = name?.trimmingCharacters(in: .whitespaces),
                   let restStart,
                   isPlausibleName(name) {
                    let rest = String(text[restStart...]).trimmingCharacters(in: .whitespaces)
                    if !rest.isEmpty { return (rest, name) }
                }
            }
        }

        if let colon = text.firstIndex(of: ":") {
            let name = String(text[..<colon]).trimmingCharacters(in: .whitespaces)
            if isPlausibleName(name) {
                let rest = String(text[text.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                if !rest.isEmpty { return (rest, name) }
            }
        }

        // `@` must start a token (start of text or after whitespace/paren) so email addresses in the
        // task text ("send to client@acme.com") are never mistaken for mentions. The boundary is
        // captured and re-inserted (Swift's regex engine has no lookbehind).
        if let match = text.firstMatch(of: /(^|[\s(])@([\p{L}][\p{L}\d._\-]*)/) {
            let name = String(match.2)
            text.replaceSubrange(match.range, with: String(match.1))
            let cleaned = text
                .split(separator: " ", omittingEmptySubsequences: true)
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespaces)
            return (cleaned, name)
        }

        return (text, nil)
    }

    private static func isPlausibleName(_ name: String) -> Bool {
        guard !name.isEmpty, !name.contains("*") else { return false }
        let words = name.split(separator: " ")
        guard (1...3).contains(words.count) else { return false }
        return words.allSatisfy { word in
            guard let first = word.first, first.isUppercase else { return false }
            return word.allSatisfy { $0.isLetter || $0 == "." || $0 == "'" || $0 == "’" || $0 == "-" }
        }
    }

    // MARK: - Stripping

    /// Rebuild the document without the removed lines, collapsing the doubled blank lines a splice
    /// leaves behind while keeping untouched runs byte-for-byte.
    private static func strippedMarkdown(lines: [String], removed: Set<Int>) -> String {
        var out: [String] = []
        var lastEmittedIndex: Int?

        for (idx, line) in lines.enumerated() {
            if removed.contains(idx) { continue }
            let isBlank = line.trimmingCharacters(in: .whitespaces).isEmpty
            let removalBetween = lastEmittedIndex.map { $0 != idx - 1 } ?? (idx != 0)
            if isBlank, removalBetween {
                guard let last = lastEmittedIndex else { continue }
                if lines[last].trimmingCharacters(in: .whitespaces).isEmpty { continue }
            }
            out.append(line)
            lastEmittedIndex = idx
        }

        var result = out.joined(separator: "\n")
        while result.hasSuffix("\n\n") {
            result.removeLast()
        }
        return result
    }

    // MARK: - Normalization

    private static func normalized(_ string: String) -> String {
        string
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }
}
