import Foundation
import Security
import os.log

// MARK: - Injection seams
//
// The migration is written against three narrow protocols so every step can be exercised with
// in-memory fakes in deterministic tests. Production implementations wrap `FileManager`,
// `UserDefaults`, and the Keychain (`SecItem*`). No test ever touches the developer's real data:
// tests call the internal step functions with fakes, and `runIfNeeded()` hard-guards on
// `AppConstants.isRunningTests`.

/// File-system operations the app-support move depends on.
protocol MigrationFileSystem {
    func fileExists(at url: URL) -> Bool
    /// Returns `true` when `url` is a directory with no visible children. Only called after
    /// `fileExists(at:)` returns `true`.
    func isDirectoryEmpty(at url: URL) -> Bool
    func moveItem(at src: URL, to dst: URL) throws
    func removeItem(at url: URL) throws
}

/// `UserDefaults` persistent-domain operations.
protocol MigrationDefaults {
    func persistentDomain(forName name: String) -> [String: Any]?
    func setPersistentDomain(_ domain: [String: Any], forName name: String)
}

/// Keychain operations, expressed over *full* generic-password service names (prefix included).
protocol MigrationKeychain {
    /// Enumerate the service names of every generic-password item whose service starts with `prefix`.
    /// Throws when the Keychain query itself fails (as opposed to simply finding nothing).
    func servicesWithPrefix(_ prefix: String) throws -> [String]
    func secretExists(service: String) -> Bool
    func readSecret(service: String) throws -> Data
    func writeSecret(_ data: Data, service: String) throws
}

// MARK: - DataMigrationService

/// One-time, idempotent migration of legacy `TypeWhisper` on-disk state to the renamed
/// `MeetingWhisper` locations (app-support directory, `UserDefaults` persistent domains, and
/// Keychain API-key items).
///
/// Design guarantees:
/// - **Atomic**: the app-support directory is moved with `rename(2)` (same volume), never
///   copied-then-deleted, so there is no partial state and no window for data loss.
/// - **Idempotent**: every step is a no-op once the new location holds data / the old is absent,
///   so re-running (including on every launch) changes nothing.
/// - **Non-destructive**: old data is left in place as a rollback safety net; new items are never
///   overwritten.
/// - **Degrades gracefully**: a failed step (e.g. an unreadable Keychain after the bundle-id change)
///   is logged and skipped — never a crash, never a wipe. The user re-enters affected secrets.
enum DataMigrationService {

    struct KeychainSummary: Equatable {
        var migrated: Int
        var skipped: Int
        var total: Int
    }

    struct Summary: Equatable {
        var appSupportMoved: Bool
        var defaultsCopied: Bool
        var keychain: KeychainSummary
    }

    // MARK: Step A — app-support directory (atomic move)

    /// Moves `src` to `dst` when appropriate. Returns whether a move happened.
    ///
    /// No-op (returns `false`) when the destination already holds data (already migrated) or the
    /// source does not exist (nothing to migrate). An *empty* destination placeholder is removed
    /// first so the rename cannot fail with "already exists".
    static func migrateAppSupport(src: URL, dst: URL, fileSystem: MigrationFileSystem) throws -> Bool {
        let destinationExists = fileSystem.fileExists(at: dst)

        // Already migrated: destination present and non-empty.
        if destinationExists && !fileSystem.isDirectoryEmpty(at: dst) {
            return false
        }

        // Nothing to migrate.
        guard fileSystem.fileExists(at: src) else {
            return false
        }

        // Clear an empty placeholder so `moveItem` (rename) doesn't collide.
        if destinationExists {
            try fileSystem.removeItem(at: dst)
        }

        // rename(2): atomic on the same volume (both under ~/Library/Application Support).
        try fileSystem.moveItem(at: src, to: dst)
        return true
    }

    // MARK: Step B — UserDefaults persistent domains

    /// Copies the old bundle-id persistent domain to the new one when the new domain is empty.
    /// The old domain is intentionally left intact (rollback safety; inert under the new id).
    static func migrateDefaults(oldDomain: String, newDomain: String, defaults: MigrationDefaults) -> Bool {
        guard let old = defaults.persistentDomain(forName: oldDomain), !old.isEmpty else {
            return false
        }
        let existing = defaults.persistentDomain(forName: newDomain) ?? [:]
        guard existing.isEmpty else {
            // Never clobber post-migration edits.
            return false
        }
        defaults.setPersistentDomain(old, forName: newDomain)
        return true
    }

    // MARK: Step C — Keychain (best-effort)

    /// Copies every old-prefixed generic-password item to the new prefix. Existing new items are
    /// preserved (reported as skipped). Read/write failures on individual items are swallowed
    /// (reported as skipped) so a partitioned or unreadable Keychain degrades gracefully.
    static func migrateKeychain(oldPrefix: String, newPrefix: String, keychain: MigrationKeychain) -> KeychainSummary {
        let services: [String]
        do {
            services = try keychain.servicesWithPrefix(oldPrefix)
        } catch {
            // Enumeration itself failed (e.g. access-group denies the renamed app). Degrade.
            return KeychainSummary(migrated: 0, skipped: 0, total: 0)
        }

        var migrated = 0
        var skipped = 0
        for old in services {
            guard old.hasPrefix(oldPrefix) else {
                skipped += 1
                continue
            }
            let newService = newPrefix + old.dropFirst(oldPrefix.count)

            // Never overwrite a secret already present under the new prefix.
            if keychain.secretExists(service: newService) {
                skipped += 1
                continue
            }

            do {
                let data = try keychain.readSecret(service: old)
                try keychain.writeSecret(data, service: newService)
                migrated += 1
            } catch {
                skipped += 1
            }
        }
        return KeychainSummary(migrated: migrated, skipped: skipped, total: services.count)
    }

    // MARK: Composition

    /// Runs all steps against injected seams and returns a summary. Each step is independent — a
    /// failure in one (logged) does not prevent the others from running.
    @discardableResult
    static func run(
        appSupportSource: URL,
        appSupportDestination: URL,
        oldDefaultsDomain: String,
        newDefaultsDomain: String,
        oldKeychainPrefix: String,
        newKeychainPrefix: String,
        fileSystem: MigrationFileSystem,
        defaults: MigrationDefaults,
        keychain: MigrationKeychain,
        log: (String) -> Void = { _ in }
    ) -> Summary {
        var appSupportMoved = false
        do {
            appSupportMoved = try migrateAppSupport(
                src: appSupportSource,
                dst: appSupportDestination,
                fileSystem: fileSystem
            )
        } catch {
            // Leave the old directory intact; the app starts fresh under the new name.
            log("migration: appSupport move failed (\(error.localizedDescription)); old data left in place")
        }

        let defaultsCopied = migrateDefaults(
            oldDomain: oldDefaultsDomain,
            newDomain: newDefaultsDomain,
            defaults: defaults
        )

        let keychainSummary = migrateKeychain(
            oldPrefix: oldKeychainPrefix,
            newPrefix: newKeychainPrefix,
            keychain: keychain
        )

        let summary = Summary(
            appSupportMoved: appSupportMoved,
            defaultsCopied: defaultsCopied,
            keychain: keychainSummary
        )
        log("migration: appSupport moved=\(appSupportMoved), defaults copied=\(defaultsCopied), " +
            "keychain \(keychainSummary.migrated)/\(keychainSummary.total) migrated (skipped \(keychainSummary.skipped))")
        return summary
    }

    // MARK: Production entry point

    /// Everything the migration needs, resolved once. Bundling it behind a factory lets the test
    /// guard be verified deterministically: the factory is *never invoked* when the test guard is
    /// engaged, so no seams (real or fake) are touched.
    struct Context {
        var appSupportSource: URL
        var appSupportDestination: URL
        var oldDefaultsDomain: String
        var newDefaultsDomain: String
        var oldKeychainPrefix: String
        var newKeychainPrefix: String
        var fileSystem: MigrationFileSystem
        var defaults: MigrationDefaults
        var keychain: MigrationKeychain
        var log: (String) -> Void
    }

    /// Called once at app startup, before any service reads the app-support directory, defaults, or
    /// keychain. Hard no-op under the test host.
    static func runIfNeeded() {
        // NEVER run against the developer's real data in unit tests (mirrors existing discipline).
        runIfNeeded(isTestEnvironment: AppConstants.isRunningTests, makeContext: productionContext)
    }

    /// Testable core of `runIfNeeded()`. `makeContext` is only called when the guard allows the
    /// migration to proceed, and may return `nil` to signal "nothing to do".
    @discardableResult
    static func runIfNeeded(
        isTestEnvironment: Bool,
        makeContext: () -> Context?
    ) -> Summary? {
        guard !isTestEnvironment else { return nil }
        guard let context = makeContext() else { return nil }
        return run(
            appSupportSource: context.appSupportSource,
            appSupportDestination: context.appSupportDestination,
            oldDefaultsDomain: context.oldDefaultsDomain,
            newDefaultsDomain: context.newDefaultsDomain,
            oldKeychainPrefix: context.oldKeychainPrefix,
            newKeychainPrefix: context.newKeychainPrefix,
            fileSystem: context.fileSystem,
            defaults: context.defaults,
            keychain: context.keychain,
            log: context.log
        )
    }

    /// Resolves the legacy/new identifiers from `AppConstants` + the bundle id and wires production
    /// seams. Returns `nil` when nothing was actually renamed.
    static func productionContext() -> Context? {
        guard let newBundleID = Bundle.main.bundleIdentifier else { return nil }

        // Derive the legacy identifiers by reversing the rename token. Robust across the `.dev` /
        // `.widgets` suffixes because the token substitution is unambiguous.
        let oldBundleID = newBundleID.replacingOccurrences(of: "meetingwhisper", with: "typewhisper")

        let newSupportName = AppConstants.appSupportDirectoryName
        let oldSupportName = newSupportName.replacingOccurrences(of: "MeetingWhisper", with: "TypeWhisper")

        let newKeychainPrefix = AppConstants.keychainServicePrefix
        let oldKeychainPrefix = newKeychainPrefix.replacingOccurrences(of: "meetingwhisper", with: "typewhisper")

        // If nothing actually renamed (e.g. a build where the token is absent), skip.
        guard oldBundleID != newBundleID || oldSupportName != newSupportName else { return nil }

        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let logger = Logger(subsystem: newBundleID, category: "DataMigration")

        return Context(
            appSupportSource: base.appendingPathComponent(oldSupportName, isDirectory: true),
            appSupportDestination: base.appendingPathComponent(newSupportName, isDirectory: true),
            oldDefaultsDomain: oldBundleID,
            newDefaultsDomain: newBundleID,
            oldKeychainPrefix: oldKeychainPrefix,
            newKeychainPrefix: newKeychainPrefix,
            fileSystem: SystemMigrationFileSystem(),
            defaults: SystemMigrationDefaults(),
            keychain: SystemMigrationKeychain(),
            log: { logger.info("\($0, privacy: .public)") }
        )
    }
}

// MARK: - Production seam implementations

struct SystemMigrationFileSystem: MigrationFileSystem {
    private let fileManager = FileManager.default

    func fileExists(at url: URL) -> Bool {
        fileManager.fileExists(atPath: url.path)
    }

    func isDirectoryEmpty(at url: URL) -> Bool {
        let contents = try? fileManager.contentsOfDirectory(atPath: url.path)
        return (contents?.isEmpty) ?? true
    }

    func moveItem(at src: URL, to dst: URL) throws {
        try fileManager.moveItem(at: src, to: dst)
    }

    func removeItem(at url: URL) throws {
        try fileManager.removeItem(at: url)
    }
}

struct SystemMigrationDefaults: MigrationDefaults {
    private let defaults = UserDefaults.standard

    func persistentDomain(forName name: String) -> [String: Any]? {
        defaults.persistentDomain(forName: name)
    }

    func setPersistentDomain(_ domain: [String: Any], forName name: String) {
        defaults.setPersistentDomain(domain, forName: name)
    }
}

/// Wraps `SecItem*` at the level of full generic-password service names. Mirrors the enumeration
/// pattern proven in `KeychainService.deleteAll(withServicePrefix:)`. No `kSecAttrAccessGroup` is
/// set, matching how the app writes its items (they live in the default, team-scoped group).
struct SystemMigrationKeychain: MigrationKeychain {
    func servicesWithPrefix(_ prefix: String) throws -> [String] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess, let items = result as? [[String: Any]] else {
            throw KeychainMigrationError.enumerationFailed(status)
        }
        return items.compactMap { item in
            guard let service = item[kSecAttrService as String] as? String,
                  service.hasPrefix(prefix) else { return nil }
            return service
        }
    }

    func secretExists(service: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    func readSecret(service: String) throws -> Data {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            throw KeychainMigrationError.readFailed(status)
        }
        return data
    }

    func writeSecret(_ data: Data, service: String) throws {
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked,
        ]
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainMigrationError.writeFailed(status)
        }
    }
}

enum KeychainMigrationError: Error {
    case enumerationFailed(OSStatus)
    case readFailed(OSStatus)
    case writeFailed(OSStatus)
}
