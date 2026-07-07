import Foundation

/// Describes how someone uses TypeWhisper. Retained only because a couple of call
/// sites and tests still reference it; it no longer drives any licensing behavior.
enum UsageIntent: String, CaseIterable, Sendable {
    case personalOSS
    case workSolo
    case team
    case enterprise
}

/// TypeWhisper is free and open source (GPLv3). Every feature is unlocked for
/// everyone, so this service is a thin compatibility shim: the feature-gate
/// accessors are constants and there is no purchase, license-key, supporter, or
/// networking machinery. It is kept as an `ObservableObject` singleton so the
/// wider codebase (view models, service container, tests) keeps compiling.
@MainActor
final class LicenseService: ObservableObject {
    nonisolated(unsafe) static var shared: LicenseService!

    init(defaults: UserDefaults = .standard) {}

    // MARK: - Feature gates (all unlocked)

    var isSupporter: Bool { false }
    var hasCommercialLicense: Bool { true }
    var canUseProTranscriptionFallback: Bool { true }

    // MARK: - Prompts / reminders (all suppressed)

    var needsWelcomeSheet: Bool { false }
    var shouldShowReminder: Bool { false }
    var requiresCommercialLicense: Bool { false }
    var shouldShowWorkUsagePrompt: Bool { false }

    // MARK: - No-op hooks retained for existing call sites

    func setUsageIntent(_ intent: UsageIntent) {}
    func markWelcomeSheetShown() {}
}
