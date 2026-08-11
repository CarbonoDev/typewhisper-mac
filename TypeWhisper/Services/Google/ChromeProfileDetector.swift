import Foundation

/// One Chrome browser profile as read from Chrome's `Local State` file ([Google Phase 1 · join
/// links]). `directory` is the profile's on-disk folder name ("Default", "Profile 1", …) — the
/// value Chrome's `--profile-directory=` launch argument expects; `email` is the profile's
/// signed-in Google account (`user_name`), the auto-match key against a connected account.
struct ChromeProfile: Equatable, Identifiable, Sendable {
    let directory: String
    let email: String?
    let displayName: String
    var id: String { directory }
}

/// Detection of installed Chrome profiles ([Google Phase 1 · join links]): parse
/// `~/Library/Application Support/Google/Chrome/Local State` — a JSON file whose
/// `profile.info_cache` maps profile directory names to metadata including `name` (display name)
/// and `user_name` (signed-in Google email).
///
/// The parse and the auto-match rule are pure over injected data (`ChromeProfileDetectorTests`
/// feeds fixture JSON); only `detectProfiles()` touches the filesystem, and every failure mode —
/// Chrome not installed, file missing, malformed JSON, absent keys — degrades to an empty list,
/// never an error surfaced to UI.
enum ChromeProfileDetector {
    /// Chrome's per-user state file. Stable across Chrome versions; absent when Chrome was never
    /// installed for this user.
    nonisolated static var defaultLocalStateURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Google/Chrome/Local State")
    }

    /// The installed profiles, or `[]` when Chrome (or its state file) is absent/unreadable.
    /// The file-read is the sole IO; parsing is delegated to the pure overload below.
    static func detectProfiles(localStateURL: URL = defaultLocalStateURL) -> [ChromeProfile] {
        guard let data = try? Data(contentsOf: localStateURL) else { return [] }
        return profiles(fromLocalStateData: data)
    }

    /// Pure parse of a `Local State` payload. Unknown/malformed shapes yield `[]`; entries
    /// missing `name` fall back to the directory name; empty `user_name` reads as no email.
    /// Sorted by directory name for a stable picker order ("Default" first, then "Profile N").
    static func profiles(fromLocalStateData data: Data) -> [ChromeProfile] {
        guard
            let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            let profile = root["profile"] as? [String: Any],
            let infoCache = profile["info_cache"] as? [String: Any]
        else { return [] }
        return infoCache
            .compactMap { directory, value -> ChromeProfile? in
                guard let info = value as? [String: Any] else { return nil }
                let name = (info["name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                let email = (info["user_name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                return ChromeProfile(
                    directory: directory,
                    email: email,
                    displayName: name ?? directory
                )
            }
            .sorted { $0.directory.localizedStandardCompare($1.directory) == .orderedAscending }
    }

    /// The single profile signed into `accountEmail` (case-insensitive `user_name` equality), or
    /// `nil` when zero or two-plus profiles match — an ambiguous match must never silently pick a
    /// profile, so "Auto" falls back to the system browser instead.
    static func autoMatch(profiles: [ChromeProfile], accountEmail: String) -> ChromeProfile? {
        let needle = accountEmail.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return nil }
        let matches = profiles.filter { $0.email?.lowercased() == needle }
        return matches.count == 1 ? matches.first : nil
    }
}
