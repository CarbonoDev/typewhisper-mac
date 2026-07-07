import AppKit
import Foundation
import TypeWhisperPluginSDK

private enum PassiveLoadedModelRestoreContext {
    @TaskLocal static var suppressLoadedModelDefault = false

    private static let synchronousActivationAccessKey = "com.typewhisper.host.loadedModel.synchronousActivationAccess"

    static var allowsLoadedModelDefaultInCurrentCallStack: Bool {
        Thread.current.threadDictionary[synchronousActivationAccessKey] as? Bool == true
    }

    static func withSynchronousLoadedModelDefaultAccess(_ body: () -> Void) {
        let threadDictionary = Thread.current.threadDictionary
        let previousValue = threadDictionary[synchronousActivationAccessKey]
        threadDictionary[synchronousActivationAccessKey] = true
        defer {
            if let previousValue {
                threadDictionary[synchronousActivationAccessKey] = previousValue
            } else {
                threadDictionary.removeObject(forKey: synchronousActivationAccessKey)
            }
        }

        body()
    }
}

final class HostServicesImpl: HostServices, HostModelLifecyclePolicyProviding, MeetingEventObserving, @unchecked Sendable {
    let pluginId: String
    let pluginDataDirectory: URL
    let eventBus: EventBusProtocol
    /// Meeting-event capability bus (addendum AD4). `nil` keeps `host.meetingEvents` inert on hosts
    /// constructed without a bus (e.g. legacy code paths / tests), which plugins already tolerate.
    private let meetingEventBus: MeetingEventBus?
    private let ruleNamesProvider: @MainActor () -> [String]
    private let workflowProvider: @MainActor () -> [PluginWorkflowInfo]

    init(
        pluginId: String,
        eventBus: EventBusProtocol,
        meetingEventBus: MeetingEventBus? = nil,
        ruleNamesProvider: @escaping @MainActor () -> [String],
        workflowProvider: @escaping @MainActor () -> [PluginWorkflowInfo] = { [] }
    ) {
        self.pluginId = pluginId
        self.eventBus = eventBus
        self.meetingEventBus = meetingEventBus
        self.ruleNamesProvider = ruleNamesProvider
        self.workflowProvider = workflowProvider

        self.pluginDataDirectory = AppConstants.appSupportDirectory
            .appendingPathComponent("PluginData", isDirectory: true)
            .appendingPathComponent(pluginId, isDirectory: true)

        // Create directory if needed
        try? FileManager.default.createDirectory(at: pluginDataDirectory, withIntermediateDirectories: true)
    }

    // MARK: - Keychain

    func storeSecret(key: String, value: String) throws {
        let scopedService = "\(pluginId).\(key)"
        if value.isEmpty {
            try KeychainService.delete(service: scopedService)
        } else {
            try KeychainService.save(key: value, service: scopedService)
        }
    }

    func loadSecret(key: String) -> String? {
        let scopedService = "\(pluginId).\(key)"
        return KeychainService.load(service: scopedService)
    }

    // MARK: - UserDefaults (plugin-scoped)

    func userDefault(forKey key: String) -> Any? {
        if key == "loadedModel",
           PassiveLoadedModelRestoreContext.suppressLoadedModelDefault,
           !PassiveLoadedModelRestoreContext.allowsLoadedModelDefaultInCurrentCallStack,
           !shouldRestoreLoadedModelsPassively {
            return nil
        }

        return UserDefaults.standard.object(forKey: "plugin.\(pluginId).\(key)")
    }

    func setUserDefault(_ value: Any?, forKey key: String) {
        UserDefaults.standard.set(value, forKey: "plugin.\(pluginId).\(key)")
    }

    // MARK: - Model Lifecycle Policy

    var shouldRestoreLoadedModelsPassively: Bool {
        ModelAutoUnloadPolicy.shouldRestoreLoadedModelsPassively()
    }

    func performPluginActivation(
        suppressPassiveLoadedModelRestore: Bool,
        _ body: @escaping () -> Void
    ) {
        let activation = {
            PassiveLoadedModelRestoreContext.withSynchronousLoadedModelDefaultAccess(body)
        }

        guard suppressPassiveLoadedModelRestore else {
            activation()
            return
        }

        PassiveLoadedModelRestoreContext.$suppressLoadedModelDefault.withValue(true) {
            activation()
        }
    }

    // MARK: - App Context

    var activeAppBundleId: String? {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }

    var activeAppName: String? {
        NSWorkspace.shared.frontmostApplication?.localizedName
    }

    // MARK: - Rules

    var availableRuleNames: [String] {
        readMainActor(ruleNamesProvider)
    }

    var availableWorkflows: [PluginWorkflowInfo] {
        readMainActor(workflowProvider)
    }

    // MARK: - Capabilities

    func notifyCapabilitiesChanged() {
        DispatchQueue.main.async {
            PluginManager.shared?.notifyPluginStateChanged()
        }
    }

    // MARK: - Streaming Display

    func setStreamingDisplayActive(_ active: Bool) {
        DispatchQueue.main.async {
            DictationViewModel._shared?.updateExternalStreamingDisplay(active: active)
        }
    }

    // MARK: - Meeting Events (addendum AD4)

    @discardableResult
    func subscribeMeetingEvents(
        _ handler: @escaping @Sendable (MeetingEvent) async -> Void
    ) -> UUID {
        guard let meetingEventBus else { return UUID() }
        return meetingEventBus.subscribeMeetingEvents(handler)
    }

    func unsubscribeMeetingEvents(id: UUID) {
        meetingEventBus?.unsubscribeMeetingEvents(id: id)
    }

    private func readMainActor<Value: Sendable>(_ body: @escaping @MainActor () -> Value) -> Value {
        if Thread.isMainThread {
            return MainActor.assumeIsolated {
                body()
            }
        }

        return DispatchQueue.main.sync {
            MainActor.assumeIsolated {
                body()
            }
        }
    }
}
