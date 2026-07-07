import Foundation

// MARK: - Provider Type

enum LLMProviderType: String, CaseIterable, Identifiable {
    case appleIntelligence

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .appleIntelligence: "Apple Intelligence"
        }
    }
}

// MARK: - Provider Protocol

protocol LLMProvider: Sendable {
    func process(systemPrompt: String, userText: String) async throws -> String
    var isAvailable: Bool { get }
}

// MARK: - Errors

enum LLMError: LocalizedError {
    case notAvailable
    case providerError(String)
    case providerNotReady(String)
    case inputTooLong
    case noProviderConfigured
    case noApiKey

    var errorDescription: String? {
        switch self {
        case .notAvailable:
            String(localized: "llm.error.notAvailable")
        case .providerError(let message):
            String(format: String(localized: "llm.error.generic"), message)
        case .providerNotReady(let message):
            message
        case .inputTooLong:
            String(localized: "llm.error.inputTooLong")
        case .noProviderConfigured:
            String(localized: "llm.error.noProviderConfigured")
        case .noApiKey:
            String(localized: "llm.error.noApiKey")
        }
    }

    /// True when the failure is specifically "no default LLM provider is configured", so callers can
    /// surface an actionable deep-link into Settings › Library › Prompts instead of a dead-end
    /// message. Matched structurally (not by localized string) so it survives translation.
    var isNoProviderConfigured: Bool {
        if case .noProviderConfigured = self { return true }
        return false
    }
}
