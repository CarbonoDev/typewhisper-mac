import Foundation

/// Pure extraction of LLM-ready body text from a Gmail `format=full` payload ([Google Phase 3 ·
/// M1], D-M1 step 5): prefer the first `text/plain` MIME part (base64url-decoded), else tag-strip
/// + entity-decode the first `text/html` part, else the snippet. Deliberately naive HTML handling
/// (spec §8) — brief/Q&A prompts tolerate messy context, and everything is capped.
enum GmailBodyText {
    /// Mirrors `ObsidianVaultService.passageCharBudget` (D-M1).
    static let contentCharCap = 2000

    /// The extracted body text, capped at `contentCharCap`. `snippet` is the fallback when the
    /// payload has no text part that decodes to actual content — a part whose decoded form is
    /// whitespace-only is NOT content (review finding: a `multipart/alternative` whose
    /// `text/plain` alternative is just `"\r\n"` used to win the search and blank the passage,
    /// hiding the real `text/html` sibling and the snippet).
    static func extract(payload: GmailAPI.GmailPayload?, snippet: String) -> String {
        var text: String?
        if let payload {
            text = firstDecodedPart(withMimePrefix: "text/plain", in: payload)
            if text == nil, let html = firstDecodedPart(withMimePrefix: "text/html", in: payload) {
                // Tag-stripping can itself yield nothing (markup-only body) — fall through to the
                // snippet rather than returning "".
                let stripped = plainText(fromHTML: html)
                text = stripped.isEmpty ? nil : stripped
            }
        }
        let trimmed = (text ?? snippet).trimmingCharacters(in: .whitespacesAndNewlines)
        return String(trimmed.prefix(contentCharCap))
    }

    /// Gmail's `body.data` is base64url (RFC 4648 §5: `-`/`_` alphabet, padding often stripped).
    /// `charset` is the declared charset of the part carrying the data (`Content-Type:
    /// text/plain; charset=iso-8859-1`), when the wire model exposes one.
    static func decodeBase64URL(_ data: String, charset: String? = nil) -> String? {
        var base64 = data
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder > 0 {
            base64 += String(repeating: "=", count: 4 - remainder)
        }
        guard let decoded = Data(base64Encoded: base64) else { return nil }
        return decodeText(decoded, charset: charset)
    }

    /// Charset fallback chain (review finding: UTF-8-only decoding silently dropped every
    /// legacy-charset body — still common in German business mail, and this app ships DE).
    ///
    /// UTF-8 is tried **first, ahead of the declared charset**, deliberately: a mislabeled UTF-8
    /// body (`charset=iso-8859-1` on real UTF-8 bytes) is the common mailer bug, while the reverse
    /// mistake is self-correcting — Latin-1/CP1252 high bytes (0xFC "ü", 0xE4 "ä") are almost never
    /// valid UTF-8 sequences, so UTF-8 decoding *fails* on genuine legacy bytes and the declared
    /// charset takes over. CP1252 precedes Latin-1 because mailers emit its 0x80–0x9F range (smart
    /// quotes, en dashes) and Latin-1 — which decodes every byte sequence and therefore never fails
    /// — must stay last or nothing after it is ever reached.
    static func decodeText(_ data: Data, charset: String?) -> String? {
        var chain: [String.Encoding] = [.utf8]
        if let declared = encoding(forCharset: charset) { chain.append(declared) }
        chain.append(contentsOf: [.windowsCP1252, .isoLatin1])
        for encoding in chain {
            if let text = String(data: data, encoding: encoding) { return text }
        }
        return nil
    }

    /// The MIME charset names worth mapping; anything else (or nothing) falls through to the
    /// chain's defaults.
    static func encoding(forCharset charset: String?) -> String.Encoding? {
        guard let charset else { return nil }
        switch charset.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "utf-8", "utf8": return .utf8
        case "us-ascii", "ascii": return .ascii
        case "iso-8859-1", "iso8859-1", "latin1", "latin-1": return .isoLatin1
        case "iso-8859-2", "iso8859-2", "latin2", "latin-2": return .isoLatin2
        case "windows-1252", "cp1252", "cp-1252": return .windowsCP1252
        case "utf-16", "utf16": return .utf16
        default: return nil
        }
    }

    /// Naive HTML → text: drop `<style>`/`<script>` blocks, break on the common block-level
    /// closers, strip remaining tags, decode the frequent entities, collapse whitespace runs.
    static func plainText(fromHTML html: String) -> String {
        var text = html
        for container in ["style", "script", "head"] {
            // `(?is)`: dot-matches-newline is essential — real HTML mail carries multi-line
            // style/script blocks, and without `s` their raw CSS/JS would survive into the
            // passage text (review finding, M1).
            text = text.replacingOccurrences(
                of: "(?is)<\(container)[^>]*>.*?</\(container)>",
                with: " ",
                options: .regularExpression
            )
        }
        text = text.replacingOccurrences(
            of: "<br[^>]*>|</p>|</div>|</tr>|</li>|</h[1-6]>",
            with: "\n",
            options: [.regularExpression, .caseInsensitive]
        )
        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        // `&amp;` decodes LAST so double-escaped text ("&amp;lt;") yields the literal "&lt;"
        // instead of being re-decoded to "<".
        let entities: [(String, String)] = [
            ("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"),
            ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"),
            ("&amp;", "&"),
        ]
        for (entity, replacement) in entities {
            text = text.replacingOccurrences(of: entity, with: replacement)
        }
        // Collapse runs: spaces/tabs within lines, 3+ newlines to a blank line.
        text = text.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: " ?\\n ?", with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Private

    /// Depth-first, in wire order: a leaf whose `mimeType` matches and whose `body.data` decodes
    /// to non-whitespace text wins — so `multipart/alternative`'s plain part beats its HTML sibling
    /// when the caller asks for `text/plain` first, while a whitespace-only alternative (a real and
    /// common mailer shape) falls through to that sibling instead of blanking the extraction.
    /// Decoding honors the part's own declared charset.
    private static func firstDecodedPart(
        withMimePrefix prefix: String,
        in payload: GmailAPI.GmailPayload
    ) -> String? {
        if payload.mimeType?.lowercased().hasPrefix(prefix) == true,
           let data = payload.body?.data,
           let decoded = decodeBase64URL(data, charset: charset(of: payload)),
           !decoded.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return decoded
        }
        for part in payload.parts ?? [] {
            if let found = firstDecodedPart(withMimePrefix: prefix, in: part) {
                return found
            }
        }
        return nil
    }

    /// The `charset=` parameter of a part's own `Content-Type` header (`format=full` carries per-part
    /// headers), unquoted. `nil` when the part declares none — the decode chain then relies on its
    /// UTF-8 → CP1252 → Latin-1 fallbacks.
    static func charset(of payload: GmailAPI.GmailPayload) -> String? {
        guard let contentType = payload.headers?.first(where: {
            $0.name.caseInsensitiveCompare("Content-Type") == .orderedSame
        })?.value else { return nil }
        for parameter in contentType.split(separator: ";") {
            let trimmed = parameter.trimmingCharacters(in: .whitespaces)
            guard trimmed.lowercased().hasPrefix("charset") else { continue }
            guard let equals = trimmed.firstIndex(of: "=") else { continue }
            let value = trimmed[trimmed.index(after: equals)...]
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            return value.isEmpty ? nil : value
        }
        return nil
    }
}
