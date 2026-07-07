import SwiftUI

/// [Track B] A lightweight markdown document renderer built on the OS-native
/// `AttributedString(markdown:)` — **no third-party dependency** (plan D4). Owned by Track B and
/// reused by Track E for Space note rendering.
///
/// Rendering is per-block: the source is split into headings, bullet / ordered lists, and
/// paragraphs (`MarkdownBlock.parse`), and each block is rendered with inline emphasis handled by
/// `AttributedString`. Block parsing is pure and unit-tested (`MarkdownRenderTests`).
struct MarkdownDocumentView: View {
    let markdown: String

    private var blocks: [MarkdownBlock] { MarkdownBlock.parse(markdown) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
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
        case let .paragraph(text):
            Text(MarkdownBlock.inlineAttributed(text))
                .font(.body)
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
        }
    }

    private func listRow(marker: String, text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(marker)
                .font(.body.monospacedDigit())
                .foregroundStyle(.secondary)
            Text(MarkdownBlock.inlineAttributed(text))
                .font(.body)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func headingFont(level: Int) -> Font {
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

    var id: String {
        switch self {
        case let .heading(level, text): return "h\(level):\(text)"
        case let .paragraph(text): return "p:\(text)"
        case let .bullet(items): return "ul:\(items.joined(separator: "|"))"
        case let .ordered(items): return "ol:\(items.joined(separator: "|"))"
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
        func flushAll() {
            flushParagraph()
            flushBullets()
            flushOrdered()
        }

        for rawLine in markdown.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)

            if line.isEmpty {
                flushAll()
                continue
            }
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
