import Foundation
import SwiftData
import os.log

enum AppConstants {
    enum ReleaseChannel: String, CaseIterable {
        case stable
        case releaseCandidate = "release-candidate"
        case daily

        var sparkleChannels: Set<String> {
            switch self {
            case .stable:
                return []
            case .releaseCandidate:
                return ["release-candidate"]
            case .daily:
                return ["release-candidate", "daily"]
            }
        }

        var selectionDisplayName: String {
            switch self {
            case .stable:
                return String(localized: "Stable")
            case .releaseCandidate:
                return String(localized: "Release Candidate")
            case .daily:
                return String(localized: "Daily")
            }
        }

        var versionDisplayName: String? {
            switch self {
            case .stable:
                return nil
            case .releaseCandidate, .daily:
                return selectionDisplayName
            }
        }

        var updateDescription: String {
            switch self {
            case .stable:
                return String(localized: "Stable gets production releases only.")
            case .releaseCandidate:
                return String(localized: "Release Candidate includes stable and preview builds.")
            case .daily:
                return String(localized: "Daily includes stable, release candidate, and daily builds.")
            }
        }
    }

    nonisolated(unsafe) static var testAppSupportDirectoryOverride: URL?

    static let appSupportDirectoryName: String = {
        #if DEBUG
        return "TypeWhisper-Dev"
        #else
        return "TypeWhisper"
        #endif
    }()

    static let keychainServicePrefix: String = {
        #if DEBUG
        return "com.typewhisper.mac.dev.apikey."
        #else
        return "com.typewhisper.mac.apikey."
        #endif
    }()

    static let loggerSubsystem: String = Bundle.main.bundleIdentifier ?? "com.typewhisper.mac"

    static var appSupportDirectory: URL {
        if let override = testAppSupportDirectoryOverride {
            return override
        }
        return defaultAppSupportDirectory
    }

    static let defaultAppSupportDirectory: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent(appSupportDirectoryName, isDirectory: true)
    }()

    static let appVersion: String = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    static let buildVersion: String = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
    static let currentReleaseFingerprint: String = {
        let channel = bundledReleaseChannel()
        return "\(appVersion)+\(buildVersion)@\(channel.rawValue)"
    }()
    static func bundledReleaseChannel(infoDictionary: [String: Any]? = Bundle.main.infoDictionary) -> ReleaseChannel {
        guard let rawValue = infoDictionary?["TypeWhisperReleaseChannel"] as? String,
              let channel = ReleaseChannel(rawValue: rawValue) else {
            return .stable
        }
        return channel
    }

    static func selectedUpdateChannel(
        defaults: UserDefaults = .standard,
        infoDictionary: [String: Any]? = Bundle.main.infoDictionary
    ) -> ReleaseChannel {
        guard let rawValue = defaults.string(forKey: UserDefaultsKeys.updateChannel),
              let channel = ReleaseChannel(rawValue: rawValue) else {
            return bundledReleaseChannel(infoDictionary: infoDictionary)
        }
        return channel
    }

    static var releaseChannel: ReleaseChannel {
        bundledReleaseChannel()
    }

    static var effectiveUpdateChannel: ReleaseChannel {
        selectedUpdateChannel()
    }

    static let defaultReleaseChannel: ReleaseChannel = {
        guard let rawValue = Bundle.main.infoDictionary?["TypeWhisperReleaseChannel"] as? String,
              let channel = ReleaseChannel(rawValue: rawValue) else {
            return .stable
        }
        return channel
    }()

    static let isRunningTests: Bool = {
        let environment = ProcessInfo.processInfo.environment
        if environment["XCTestConfigurationFilePath"] != nil ||
            environment["XCTestBundlePath"] != nil ||
            environment["XCTestSessionIdentifier"] != nil {
            return true
        }

        if NSClassFromString("XCTestCase") != nil {
            return true
        }

        return Bundle.allBundles.contains { $0.bundlePath.hasSuffix(".xctest") }
    }()

    static let isDevelopment: Bool = {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }()

    // TypeWhisper is free and open source (GPLv3); there is no licensing, purchase,
    // supporter, or Discord-claim configuration.
}

private let factoryLogger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "TypeWhisper", category: "SwiftDataStoreFactory")

@MainActor
struct SwiftDataStoreFactory {
    static func create(
        for modelTypes: [any PersistentModel.Type],
        storeName: String,
        in directory: URL
    ) throws -> (ModelContainer, ModelContext) {
        let schema = Schema(modelTypes)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let storeURL = directory.appendingPathComponent("\(storeName).store")
        let config = ModelConfiguration(url: storeURL)

        var container: ModelContainer
        do {
            container = try ModelContainer(for: schema, configurations: [config])
        } catch {
            factoryLogger.error("Incompatible schema for \(storeName) store. Resetting store.")
            // Incompatible schema — delete old store and retry
            for suffix in ["", "-wal", "-shm"] {
                let url = directory.appendingPathComponent("\(storeName).store\(suffix)")
                try? FileManager.default.removeItem(at: url)
            }
            do {
                container = try ModelContainer(for: schema, configurations: [config])
            } catch {
                // If it still fails, there's a fundamental issue
                fatalError("Failed to create \(storeName) ModelContainer after reset: \(error)")
            }
        }

        let context = ModelContext(container)
        context.autosaveEnabled = true
        return (container, context)
    }
}
