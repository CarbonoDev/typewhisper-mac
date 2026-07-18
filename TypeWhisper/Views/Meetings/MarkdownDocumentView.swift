import SwiftUI

/// [Track B] A lightweight markdown document renderer built on the OS-native
/// `AttributedString(markdown:)` — **no third-party dependency** (plan D4). Owned by Track B and
/// reused by Track E for Space note rendering.
///
/// Rendering is per-block: the source is split into headings, bullet / ordered lists, and
/// paragraphs (`MarkdownBlock.parse`), and each block is rendered with inline emphasis handled by
/// `AttributedString`. Block parsing is pure and unit-tested (`MarkdownRenderTests`).
struct MarkdownDocumentView: View {
    /// Typography voice: `.standard` keeps the original system-font map (Space notes, Track E);
    /// `.article` is the meeting document's serif reading voice (Sprint 1, `MeetingTheme`).
    enum Style {
        case standard
        case article
    }

    let markdown: String
    var style: Style = .standard

    private var blocks: [MarkdownBlock] { MarkdownBlock.parse(markdown) }

    private var bodyFont: Font {
        style == .article ? MeetingTheme.articleBody : .body
    }

    private var bodyLineSpacing: CGFloat {
        style == .article ? MeetingTheme.articleLineSpacing : 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: style == .article ? 12 : 10) {
            ForEach(blocks) { block in
                render(block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func render(_ block: MarkdownBlock) -> some View {
        switch block {
        case let .heading(level, text):
            Text(MarkdownBlock.inlineAttributed(text))
                .font(headingFont(level: level))
                .bold()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, style == .article ? 6 : 0)
        case let .paragraph(text):
            Text(MarkdownBlock.inlineAttributed(text))
                .font(bodyFont)
                .lineSpacing(bodyLineSpacing)
                .frame(maxWidth: .infinity, alignment: .leading)
        case let .bullet(items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    listRow(marker: "•", text: item)
                }
            }
        case let .ordered(items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    listRow(marker: "\(index + 1).", text: item)
                }
            }
        case let .table(header, rows):
            tableView(header: header, rows: rows)
        }
    }

    /// A lightweight table: header row (when present) in semibold secondary over a hairline, body
    /// rows as leading-aligned wrapped text. Generated summaries frequently use tables for action
    /// items and metrics; before this they rendered as raw `|` pipe paragraphs.
    private func tableView(header: [String], rows: [[String]]) -> some View {
        Grid(alignment: .topLeading, horizontalSpacing: 12, verticalSpacing: 6) {
            if !header.isEmpty {
                GridRow {
                    ForEach(Array(header.enumerated()), id: \.offset) { _, cell in
                        Text(MarkdownBlock.inlineAttributed(cell))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                Divider()
                    .gridCellUnsizedAxes(.horizontal)
            }
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                GridRow {
                    ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                        Text(MarkdownBlock.inlineAttributed(cell))
                            .font(style == .article ? .system(size: 13) : .callout)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func listRow(marker: String, text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(marker)
                .font(.body.monospacedDigit())
                .foregroundStyle(.secondary)
            Text(MarkdownBlock.inlineAttributed(text))
                .font(bodyFont)
                .lineSpacing(bodyLineSpacing)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func headingFont(level: Int) -> Font {
        if style == .article {
            return MeetingTheme.articleHeading(level: level)
        }
        switch level {
        case 1: return .title
        case 2: return .title2
        case 3: return .title3
        default: return .headline
        }
    }
}

/// A parsed markdown block. Block classification is pure and testable; inline emphasis is deferred
/// to `AttributedString(markdown:)` at render time.
enum MarkdownBlock: Equatable, Identifiable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case bullet(items: [String])
    case ordered(items: [String])
    case table(header: [String], rows: [[String]])

    var id: String {
        switch self {
        case let .heading(level, text): return "h\(level):\(text)"
        case let .paragraph(text): return "p:\(text)"
        case let .bullet(items): return "ul:\(items.joined(separator: "|"))"
        case let .ordered(items): return "ol:\(items.joined(separator: "|"))"
        case let .table(header, rows):
            return "tbl:\(header.joined(separator: "|")):\(rows.map { $0.joined(separator: "|") }.joined(separator: ";"))"
        }
    }

    /// Split markdown source into blocks: ATX headings (`#`–`######`), bullet lists (`-`/`*`/`+`),
    /// ordered lists (`1.`), and paragraphs (consecutive plain lines joined with spaces). Blank
    /// lines separate paragraphs.
    static func parse(_ markdown: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraphLines: [String] = []
        var bulletItems: [String] = []
        var orderedItems: [String] = []
        var tableLines: [String] = []

        func flushParagraph() {
            guard !paragraphLines.isEmpty else { return }
            blocks.append(.paragraph(paragraphLines.joined(separator: " ")))
            paragraphLines.removeAll()
        }
        func flushBullets() {
            guard !bulletItems.isEmpty else { return }
            blocks.append(.bullet(items: bulletItems))
            bulletItems.removeAll()
        }
        func flushOrdered() {
            guard !orderedItems.isEmpty else { return }
            blocks.append(.ordered(items: orderedItems))
            orderedItems.removeAll()
        }
        func flushTable() {
            guard !tableLines.isEmpty else { return }
            if let table = parseTable(tableLines) {
                blocks.append(table)
            } else {
                // Not a well-formed table after all — degrade to a paragraph, never drop content.
                blocks.append(.paragraph(tableLines.joined(separator: " ")))
            }
            tableLines.removeAll()
        }
        func flushAll() {
            flushParagraph()
            flushBullets()
            flushOrdered()
            flushTable()
        }

        for rawLine in markdown.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)

            if line.isEmpty {
                flushAll()
                continue
            }
            if line.hasPrefix("|") {
                flushParagraph()
                flushBullets()
                flushOrdered()
                tableLines.append(line)
                continue
            }
            flushTable()
            if let heading = parseHeading(line) {
                flushAll()
                blocks.append(heading)
                continue
            }
            if let item = parseBulletItem(line) {
                flushParagraph()
                flushOrdered()
                bulletItems.append(item)
                continue
            }
            if let item = parseOrderedItem(line) {
                flushParagraph()
                flushBullets()
                orderedItems.append(item)
                continue
            }
            // Plain text line: part of a paragraph.
            flushBullets()
            flushOrdered()
            paragraphLines.append(line)
        }
        flushAll()
        return blocks
    }

    /// Parse consecutive `|`-prefixed lines into a table: an optional header row (recognized by an
    /// alignment separator row like `|---|:--|` directly beneath it) and body rows. Returns nil for
    /// degenerate input (no data cells), letting the caller fall back to a paragraph.
    private static func parseTable(_ lines: [String]) -> MarkdownBlock? {
        func cells(_ line: String) -> [String] {
            var trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("|") { trimmed.removeFirst() }
            if trimmed.hasSuffix("|") { trimmed.removeLast() }
            return trimmed
                .components(separatedBy: "|")
                .map { $0.trimmingCharacters(in: .whitespaces) }
        }
        func isSeparatorRow(_ line: String) -> Bool {
            let body = line.filter { !"|:- ".contains($0) }
            return body.isEmpty && line.contains("-")
        }

        var header: [String] = []
        var dataLines = lines
        if lines.count >= 2, isSeparatorRow(lines[1]), !isSeparatorRow(lines[0]) {
            header = cells(lines[0])
            dataLines = Array(lines.dropFirst(2))
        }
        let rows = dataLines
            .filter { !isSeparatorRow($0) }
            .map(cells)
            .filter { row in row.contains { !$0.isEmpty } }
        guard !rows.isEmpty || !header.isEmpty else { return nil }

        // Normalize ragged rows to the widest width so Grid rows stay aligned.
        let width = max(header.count, rows.map(\.count).max() ?? 0)
        guard width > 0 else { return nil }
        let paddedHeader = header.isEmpty ? [] : header + Array(repeating: "", count: width - header.count)
        let paddedRows = rows.map { $0 + Array(repeating: "", count: width - $0.count) }
        return .table(header: paddedHeader, rows: paddedRows)
    }

    private static func parseHeading(_ line: String) -> MarkdownBlock? {
        var level = 0
        var index = line.startIndex
        while index < line.endIndex, line[index] == "#", level < 6 {
            level += 1
            index = line.index(after: index)
        }
        guard level > 0, index < line.endIndex, line[index] == " " else { return nil }
        let text = String(line[index...]).trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        return .heading(level: level, text: text)
    }

    private static func parseBulletItem(_ line: String) -> String? {
        for marker in ["- ", "* ", "+ "] where line.hasPrefix(marker) {
            return String(line.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    private static func parseOrderedItem(_ line: String) -> String? {
        var digits = ""
        var index = line.startIndex
        while index < line.endIndex, line[index].isNumber {
            digits.append(line[index])
            index = line.index(after: index)
        }
        guard !digits.isEmpty, index < line.endIndex, line[index] == "." else { return nil }
        let afterDot = line.index(after: index)
        guard afterDot < line.endIndex, line[afterDot] == " " else { return nil }
        return String(line[afterDot...]).trimmingCharacters(in: .whitespaces)
    }

    /// Render a single line of inline markdown (emphasis, code, links) via the native parser,
    /// falling back to plain text if the source is malformed.
    static func inlineAttributed(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: text,
            options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(text)
    }
}
