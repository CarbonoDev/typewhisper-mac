import AppKit
import Foundation
import Combine
import Security
import os

@MainActor
final class APIServerViewModel: ObservableObject {
    nonisolated(unsafe) static var _shared: APIServerViewModel?
    static var shared: APIServerViewModel {
        guard let instance = _shared else {
            fatalError("APIServerViewModel not initialized")
        }
        return instance
    }

    @Published var isRunning = false
    @Published var isEnabled: Bool {
        didSet { UserDefaults.standard.set(isEnabled, forKey: UserDefaultsKeys.apiServerEnabled) }
    }
    @Published var port: UInt16 {
        didSet { UserDefaults.standard.set(Int(port), forKey: UserDefaultsKeys.apiServerPort) }
    }
    @Published var requiresAuthentication: Bool {
        didSet {
            UserDefaults.standard.set(requiresAuthentication, forKey: UserDefaultsKeys.apiServerRequiresAuthentication)
            apiAuthenticator.setRequiresAuthentication(requiresAuthentication)
        }
    }
    /// Browser-extension ids allowed to call the local API (the Meet caption bridge). Empty by
    /// default — an extension origin is refused until its id is listed here, and it must send the API
    /// token besides.
    @Published var allowedExtensionIDs: String {
        didSet {
            UserDefaults.standard.set(allowedExtensionIDs, forKey: UserDefaultsKeys.apiServerAllowedExtensionIDs)
            apiAuthenticator.setAllowedExtensionIDs(allowedExtensionIDs)
        }
    }
    @Published var errorMessage: String?

    private let httpServer: HTTPServer
    private let apiAuthenticator: LocalAPIAuthenticator

    init(httpServer: HTTPServer, apiAuthenticator: LocalAPIAuthenticator) {
        self.httpServer = httpServer
        self.apiAuthenticator = apiAuthenticator
        self.isEnabled = UserDefaults.standard.bool(forKey: UserDefaultsKeys.apiServerEnabled)
        let savedPort = UserDefaults.standard.integer(forKey: UserDefaultsKeys.apiServerPort)
        self.port = savedPort > 0 ? UInt16(savedPort) : 8978
        self.requiresAuthentication = UserDefaults.standard.bool(forKey: UserDefaultsKeys.apiServerRequiresAuthentication)
        self.allowedExtensionIDs = UserDefaults.standard
            .string(forKey: UserDefaultsKeys.apiServerAllowedExtensionIDs) ?? ""
        apiAuthenticator.setRequiresAuthentication(requiresAuthentication)
        apiAuthenticator.setAllowedExtensionIDs(allowedExtensionIDs)

        httpServer.onStateChange = { [weak self] running in
            DispatchQueue.main.async {
                self?.isRunning = running
                if !running {
                    self?.errorMessage = "Server stopped unexpectedly"
                    self?.removeDiscoveryFiles()
                }
            }
        }
    }

    func startServer() {
        errorMessage = nil
        do {
            let apiToken = try apiAuthenticator.loadOrCreateToken()
            try httpServer.start(port: port)
            do {
                try writeDiscoveryFiles(apiToken: apiToken)
            } catch {
                httpServer.stop()
                throw error
            }
        } catch {
            errorMessage = error.localizedDescription
            isRunning = false
        }
    }

    func stopServer() {
        httpServer.stop()
        isRunning = false
        errorMessage = nil
        removeDiscoveryFiles()
    }

    /// Put the API token on the pasteboard so the user can paste it into the browser extension's
    /// options page. Returns `false` when there is no token yet (the server has never started).
    @discardableResult
    func copyAPITokenToPasteboard() -> Bool {
        guard let token = try? apiAuthenticator.loadOrCreateToken(), !token.isEmpty else { return false }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(token, forType: .string)
        return true
    }

    func restartIfNeeded() {
        if isEnabled {
            stopServer()
            startServer()
        }
    }

    // MARK: - Discovery Files

    private static var portFileURL: URL {
        AppConstants.appSupportDirectory
            .appendingPathComponent("api-port")
    }

    private static var discoveryFileURL: URL {
        AppConstants.appSupportDirectory
            .appendingPathComponent("api-discovery.json")
    }

    private func writeDiscoveryFiles(apiToken: String) throws {
        let url = Self.portFileURL
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let document = APIDiscoveryDocument(port: port, token: apiToken)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(document)
        try data.write(to: Self.discoveryFileURL, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Self.discoveryFileURL.path)

        try String(port).write(to: url, atomically: true, encoding: .utf8)
    }

    private func removeDiscoveryFiles() {
        try? FileManager.default.removeItem(at: Self.portFileURL)
        try? FileManager.default.removeItem(at: Self.discoveryFileURL)
    }
}

private struct APIDiscoveryDocument: Encodable {
    let version = 1
    let port: UInt16
    let token: String
}

final class LocalAPIAuthenticator: @unchecked Sendable {
    private static let keychainService = "local-api-token"
    private static let tokenByteCount = 32

    private let token: OSAllocatedUnfairLock<String?>
    private let requiresAuthentication: OSAllocatedUnfairLock<Bool>
    private let allowedExtensionOrigins: OSAllocatedUnfairLock<Set<String>>

    init(
        initialToken: String? = nil,
        requiresAuthentication: Bool = UserDefaults.standard.bool(forKey: UserDefaultsKeys.apiServerRequiresAuthentication),
        allowedExtensionIDs: String = UserDefaults.standard.string(forKey: UserDefaultsKeys.apiServerAllowedExtensionIDs) ?? ""
    ) {
        token = OSAllocatedUnfairLock<String?>(initialState: initialToken)
        self.requiresAuthentication = OSAllocatedUnfairLock<Bool>(initialState: requiresAuthentication)
        allowedExtensionOrigins = OSAllocatedUnfairLock<Set<String>>(
            initialState: APIRouter.parseAllowedExtensionOrigins(allowedExtensionIDs)
        )

        if initialToken == nil,
           let existingToken = KeychainService.load(service: Self.keychainService),
           !existingToken.isEmpty {
            token.withLock { $0 = existingToken }
        }
    }

    func currentToken() -> String? {
        token.withLock { $0 }
    }

    func tokenForEnforcedRequests() -> String? {
        guard requiresAuthentication.withLock({ $0 }) else { return nil }
        return currentToken()
    }

    func setRequiresAuthentication(_ enabled: Bool) {
        requiresAuthentication.withLock { $0 = enabled }
    }

    func setAllowedExtensionIDs(_ raw: String) {
        let origins = APIRouter.parseAllowedExtensionOrigins(raw)
        allowedExtensionOrigins.withLock { $0 = origins }
    }

    /// The policy `APIRouter` applies to browser-extension callers. The token here is the *current*
    /// token, not `tokenForEnforcedRequests()`: an extension authenticates even when the loopback
    /// "Require API Token" toggle is off, because it is browser code, not a tool the user launched.
    func extensionOriginPolicy() -> APIRouter.ExtensionOriginPolicy {
        APIRouter.ExtensionOriginPolicy(
            allowedOrigins: allowedExtensionOrigins.withLock { $0 },
            token: currentToken()
        )
    }

    func loadOrCreateToken() throws -> String {
        if let existingToken = currentToken(), !existingToken.isEmpty {
            return existingToken
        }

        if let storedToken = KeychainService.load(service: Self.keychainService), !storedToken.isEmpty {
            token.withLock { $0 = storedToken }
            return storedToken
        }

        let newToken = try Self.makeToken()
        try KeychainService.save(key: newToken, service: Self.keychainService)
        token.withLock { $0 = newToken }
        return newToken
    }

    private static func makeToken() throws -> String {
        var bytes = [UInt8](repeating: 0, count: tokenByteCount)
        let status = bytes.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, tokenByteCount, buffer.baseAddress!)
        }
        guard status == errSecSuccess else {
            throw LocalAPIAuthenticatorError.randomGenerationFailed(status)
        }

        return Data(bytes)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

private enum LocalAPIAuthenticatorError: LocalizedError {
    case randomGenerationFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .randomGenerationFailed(let status):
            return "Failed to create API token (status: \(status))"
        }
    }
}
