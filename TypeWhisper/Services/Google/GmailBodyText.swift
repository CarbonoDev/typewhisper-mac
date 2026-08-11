import Foundation

/// Pure extraction of LLM-ready body text from a Gmail `format=full` payload ([Google Phase 3 ·
/// M1], D-M1 step 5): prefer the first `text/plain` MIME part (base64url-decoded), else tag-strip
/// + entity-decode the first `text/html` part, else the snippet. Deliberately naive HTML handling
/// (spec §8) — brief/Q&A prompts tolerate messy context, and everything is capped.
enum GmailBodyText {
    /// Mirrors `ObsidianVaultService.passageCharBudget` (D-M1).
    static let contentCharCap = 2000

    /// The extracted body text, capped at `contentCharCap`. `snippet` is the fallback when the
    /// payload has no decodable text part.
    static func extract(payload: GmailAPI.GmailPayload?, snippet: String) -> String {
        let text: String
        if let payload, let plain = firstDecodedPart(withMimePrefix: "text/plain", in: payload) {
            text = plain
        } else if let payload, let html = firstDecodedPart(withMimePrefix: "text/html", in: payload) {
            text = plainText(fromHTML: html)
        } else {
            text = snippet
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(trimmed.prefix(contentCharCap))
    }

    /// Gmail's `body.data` is base64url (RFC 4648 §5: `-`/`_` alphabet, padding often stripped).
    static func decodeBase64URL(_ data: String) -> String? {
        var base64 = data
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder > 0 {
            base64 += String(repeating: "=", count: 4 - remainder)
        }
        guard let decoded = Data(base64Encoded: base64) else { return nil }
        return String(data: decoded, encoding: .utf8)
    }

    /// Naive HTML → text: drop `<style>`/`<script>` blocks, break on the common block-level
    /// closers, strip remaining tags, decode the frequent entities, collapse whitespace runs.
    static func plainText(fromHTML html: String) -> String {
        var text = html
        for container in ["style", "script", "head"] {
            text = text.replacingOccurrences(
                of: "<\(container)[^>]*>.*?</\(container)>",
                with: " ",
                options: [.regularExpression, .caseInsensitive]
            )
        }
        text = text.replacingOccurrences(
            of: "<br[^>]*>|</p>|</div>|</tr>|</li>|</h[1-6]>",
            with: "\n",
            options: [.regularExpression, .caseInsensitive]
        )
        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        let entities: [(String, String)] = [
            ("&nbsp;", " "), ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"),
            ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"),
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
    /// wins — so `multipart/alternative`'s plain part beats its HTML sibling when the caller asks
    /// for `text/plain` first.
    private static func firstDecodedPart(
        withMimePrefix prefix: String,
        in payload: GmailAPI.GmailPayload
    ) -> String? {
        if payload.mimeType?.lowercased().hasPrefix(prefix) == true,
           let data = payload.body?.data,
           let decoded = decodeBase64URL(data),
           !decoded.isEmpty {
            return decoded
        }
        for part in payload.parts ?? [] {
            if let found = firstDecodedPart(withMimePrefix: prefix, in: part) {
                return found
            }
        }
        return nil
    }
}
