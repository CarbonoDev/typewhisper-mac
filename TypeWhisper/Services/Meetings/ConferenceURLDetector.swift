import Foundation

/// [Google Phase 1 · M5] Pure detector for video-conference join links (spec §5 M5).
///
/// The EventKit provider has no structured `conferenceData` like Google's API, so the join URL is
/// recovered heuristically: the event's `url` field when it points at a known conference host,
/// else the first such link found in the event's notes (the EventKit-world precedent — Meet/Zoom
/// invitations usually land their link in the notes body). Pure + static, so it is unit-testable
/// without an `EKEventStore`.
enum ConferenceURLDetector {
    /// Hosts recognized as video-conference services (spec §5 M5). Matched as the exact host or
    /// any subdomain (`us02web.zoom.us`, `company.webex.com`), never as a bare suffix — so
    /// `notzoom.us` does not match.
    static let knownHosts: [String] = [
        "meet.google.com",
        "zoom.us",
        "teams.microsoft.com",
        "webex.com"
    ]

    /// The event's join URL as a string: `url` wins when it is a conference link; otherwise the
    /// first conference link scanned out of `notes`. `nil` when neither yields one.
    static func detect(url: URL?, notes: String?) -> String? {
        if let url, isConferenceURL(url) {
            return url.absoluteString
        }
        if let notes {
            return firstConferenceLink(in: notes)
        }
        return nil
    }

    /// Whether a URL points at a known conference host over http(s).
    static func isConferenceURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else {
            return false
        }
        guard let host = url.host?.lowercased() else { return false }
        return knownHosts.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    /// The first known-host link in free text. `NSDataDetector` keeps this robust to surrounding
    /// punctuation and angle-bracket/markdown wrapping, instead of hand-rolling URL regexes.
    static func firstConferenceLink(in text: String) -> String? {
        guard let detector = try? NSDataDetector(
            types: NSTextCheckingResult.CheckingType.link.rawValue
        ) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        var found: String?
        detector.enumerateMatches(in: text, options: [], range: range) { match, _, stop in
            if let url = match?.url, isConferenceURL(url) {
                found = url.absoluteString
                stop.pointee = true
            }
        }
        return found
    }
}
