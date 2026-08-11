import Foundation

/// The fakeable Keychain seam for Google secrets (M1). `GoogleAccountStore` writes refresh tokens
/// and the OAuth client secret through this protocol; tests inject an in-memory fake so no unit
/// test touches the real Keychain (§7).
@MainActor
protocol GoogleSecretStoring: AnyObject {
    func save(_ secret: String, service: String) throws
    func load(service: String) -> String?
    func delete(service: String) throws
    /// Removes every secret whose service name starts with `prefix` — the disconnect sweep that
    /// also catches any future per-account secrets (D-G5).
    func deleteAll(prefix: String) throws
}

/// Production secret store delegating to the app-side `KeychainService`, which applies the
/// Debug/Release service prefix (`AppConstants.keychainServicePrefix`) so dev and release builds
/// never collide (D-G5).
@MainActor
final class KeychainGoogleSecretStore: GoogleSecretStoring {
    func save(_ secret: String, service: String) throws {
        try KeychainService.save(key: secret, service: service)
    }

    func load(service: String) -> String? {
        KeychainService.load(service: service)
    }

    func delete(service: String) throws {
        try KeychainService.delete(service: service)
    }

    func deleteAll(prefix: String) throws {
        try KeychainService.deleteAll(withServicePrefix: prefix)
    }
}
