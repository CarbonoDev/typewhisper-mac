import SwiftUI
import AVFoundation
import Combine
import TypeWhisperPluginSDK
@preconcurrency import Sparkle

extension UserDefaults {
    @objc dynamic var showMenuBarIcon: Bool {
        bool(forKey: UserDefaultsKeys.showMenuBarIcon)
    }

    @objc dynamic var dockIconBehaviorWhenMenuBarHidden: String {
        string(forKey: UserDefaultsKeys.dockIconBehaviorWhenMenuBarHidden)
            ?? DockIconBehavior.keepVisible.rawValue
    }
}

extension Notification.Name {
    static let openManagedAppWindow = Notification.Name("openManagedAppWindow")
    static let resetSetupWizardWindow = Notification.Name("resetSetupWizardWindow")
}

enum DockIconBehavior: String, CaseIterable {
    case keepVisible
    case onlyWhileWindowOpen
}

enum DockIconVisibility {
    static func shouldShowDockIcon(
        showMenuBarIcon: Bool,
        dockIconBehavior: DockIconBehavior,
        hasVisibleManagedWindow: Bool,
        hasInteractiveForegroundContent: Bool = false
    ) -> Bool {
        if hasVisibleManagedWindow || hasInteractiveForegroundContent {
            return true
        }

        guard !showMenuBarIcon else { return false }
        return dockIconBehavior == .keepVisible
    }
}

/// Pure launch-window precedence (UI Step 0, D2). Decides which window (if any) opens on
/// `applicationDidFinishLaunching`: first-run setup wins, then a pending post-update license prompt
/// (which lands in Settings with its startup sheet and suppresses `main` for that launch), then the
/// "show window at launch" toggle.
enum LaunchWindowDecision {
    enum Window: Equatable {
        case setup
        case settings
        case main
        case none
    }

    static func decide(
        isFirstRunSetupIncomplete: Bool,
        postUpdatePromptPending: Bool,
        showMainWindowAtLaunch: Bool
    ) -> Window {
        if isFirstRunSetupIncomplete { return .setup }
        if postUpdatePromptPending { return .settings }
        if showMainWindowAtLaunch { return .main }
        return .none
    }
}

/// Pure matching for the app's managed windows (UI Step 0, D1). Centralizes the substring-hazard
/// fix: the new `"main"` scene is matched by **prefix** (SwiftUI produces identifiers like
/// `main-AppWindow-1`), while the pre-existing scenes keep case-insensitive substring matching.
enum ManagedWindowMatching {
    /// Scene ids matched by case-insensitive substring (the pre-existing behavior).
    static let substringIDs = [
        AppWindowID.settings,
        AppWindowID.setup,
        AppWindowID.history,
        AppWindowID.errors,
        AppWindowID.meetings
    ]

    /// Whether a window identifier belongs to a managed scene (identifier check only; callers also
    /// match localized titles as a fallback).
    static func isManaged(identifier: String) -> Bool {
        let lower = identifier.lowercased()
        if lower.hasPrefix(AppWindowID.main) { return true }
        return substringIDs.contains { lower.contains($0) }
    }

    /// Whether an existing window identifier satisfies an `open(id:)` request. `main` is prefix-
    /// matched; every other id keeps case-insensitive substring matching.
    static func matches(windowIdentifier: String, requestedID: String) -> Bool {
        if requestedID == AppWindowID.main {
            return windowIdentifier.lowercased().hasPrefix(AppWindowID.main)
        }
        return windowIdentifier.range(of: requestedID, options: .caseInsensitive) != nil
    }
}

enum MenuBarIconState {
    static func isRecordingActive(
        dictationState: DictationViewModel.State,
        recorderState: AudioRecorderViewModel.RecorderState
    ) -> Bool {
        dictationState == .recording || recorderState == .recording
    }
}

private struct MenuBarExtraLabel: View {
    @Environment(\.openWindow) private var openWindow
    @ObservedObject private var dictation = DictationViewModel.shared
    @ObservedObject private var recorder = AudioRecorderViewModel.shared
    // Owner requests 3 & 4: scoped capture/calendar state for the tray meeting indicators.
    @StateObject private var meetingTray = MeetingTrayState()

    private var title: String {
        AppConstants.isDevelopment ? "TypeWhisper Dev" : "TypeWhisper"
    }

    private var isRecordingActive: Bool {
        MenuBarIconState.isRecordingActive(
            dictationState: dictation.state,
            recorderState: recorder.state
        )
    }

    var body: some View {
        Group {
            switch MeetingTrayIndicator.display(
                isRecording: meetingTray.isRecording,
                recordingTitle: meetingTray.meetingTitle,
                elapsedSeconds: meetingTray.elapsedSeconds,
                // An unrelated dictation/recorder capture owns the icon (red glyph), so suppress the
                // upcoming title while it is active — recording state always takes precedence.
                upcoming: isRecordingActive ? nil : meetingTray.upcomingEvent,
                now: meetingTray.trayNow
            ) {
            case .recording(let label):
                // Owner request 3: recording glyph + truncated meeting title + elapsed time.
                Label {
                    Text(label)
                } icon: {
                    Image(systemName: "record.circle")
                }
                .accessibilityLabel(Text(String(localized: "Recording...")))
            case .upcoming(let label):
                // Owner requests 1 & 2: Granola-style tray title — glyph + truncated meeting title +
                // countdown ("test · in 39m"). `meetingTray.trayNow` is the ticked clock so the
                // countdown re-renders while visible (no always-on timer).
                Label {
                    Text(label)
                } icon: {
                    Image(systemName: "calendar")
                }
                .accessibilityLabel(Text(verbatim: label))
            case .idle:
                Image(nsImage: MenuBarLogoMarkImage.image(isRecordingActive: isRecordingActive))
                    .resizable()
                    .renderingMode(isRecordingActive ? .original : .template)
                    .frame(width: 18, height: 18)
                    .accessibilityLabel(Text(verbatim: title))
                    .accessibilityValue(
                        isRecordingActive
                            ? Text(String(localized: "Recording..."))
                            : Text(String(localized: "Idle"))
                    )
            }
        }
        .onAppear {
            ManagedAppWindowOpener.shared.openWindow = openWindow
        }
        .onReceive(NotificationCenter.default.publisher(for: .openManagedAppWindow)) { notification in
            guard let id = notification.userInfo?["id"] as? String else { return }
            ManagedAppWindowOpener.shared.openWindow = openWindow
            openWindow(id: id)
        }
    }
}

private struct ManagedWindowOpenerRegistrar: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        EmptyView()
            .onAppear {
                ManagedAppWindowOpener.shared.openWindow = openWindow
            }
    }
}

enum MenuBarLogoMarkImage {
    static let size = CGSize(width: 18, height: 18)
    private static let relativeBarHeights: [CGFloat] = [0.5, 0.75, 1.0, 0.75, 0.5]

    static func image(isRecordingActive: Bool) -> NSImage {
        let image = NSImage(size: size)
        image.lockFocus()

        NSGraphicsContext.current?.shouldAntialias = true
        (isRecordingActive ? NSColor.systemRed : NSColor.black).setFill()

        for rect in barRects(in: CGRect(origin: .zero, size: size)) {
            NSBezierPath(
                roundedRect: rect,
                xRadius: rect.width / 2,
                yRadius: rect.width / 2
            ).fill()
        }

        image.unlockFocus()
        image.isTemplate = !isRecordingActive
        return image
    }

    static func barRects(in rect: CGRect) -> [CGRect] {
        let side = min(rect.width, rect.height) * 0.875
        let barWidth = side / 7
        let spacing = barWidth / 2
        let totalWidth = (barWidth * CGFloat(relativeBarHeights.count))
            + (spacing * CGFloat(relativeBarHeights.count - 1))
        var x = rect.midX - (totalWidth / 2)

        return relativeBarHeights.map { relativeHeight in
            let height = side * relativeHeight
            defer {
                x += barWidth + spacing
            }

            return CGRect(
                x: x,
                y: rect.midY - (height / 2),
                width: barWidth,
                height: height
            )
        }
    }
}

struct TypeWhisperApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @AppStorage(UserDefaultsKeys.showMenuBarIcon) private var showMenuBarIcon = true
    @State private var startupSheet: StartupSheetRoute?
    @State private var lastPresentedStartupSheet: StartupSheetRoute?
    @State private var ignoreNextStartupSheetDismiss = false

    private var postUpdatePromptCoordinator: PostUpdatePromptCoordinator {
        PostUpdatePromptCoordinator.shared
    }

    private var settingsNavigation: SettingsNavigationCoordinator {
        SettingsNavigationCoordinator.shared
    }

    var body: some Scene {
        MenuBarExtra(isInserted: $showMenuBarIcon) {
            menuBarContent
        } label: {
            if AppConstants.isRunningTests {
                EmptyView()
            } else {
                MenuBarExtraLabel()
            }
        }
        .menuBarExtraStyle(.menu)
        .commands {
            CommandGroup(after: .appInfo) {
                ManagedWindowOpenerRegistrar()
            }
        }

        settingsScene

        Window(String(localized: "TypeWhisper Setup"), id: "setup") {
            setupContent
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultSize(width: 820, height: 560)

        Window(String(localized: "History"), id: "history") {
            historyContent
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 900, height: 500)

        Window(String(localized: "Error Log"), id: "errors") {
            errorLogContent
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 500, height: 400)

        // Meetings-first main window (UI Step 2, D1/D10): now the app's primary window. The legacy
        // `Window(id: AppWindowID.meetings)` + `MeetingsWindowView` were deleted here; all meeting
        // navigation goes through this scene via `MainWindowCoordinator`.
        Window(String(localized: "mainwindow.title"), id: AppWindowID.main) {
            mainWindowContent
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1100, height: 720)
    }

    private var settingsScene: some Scene {
        Window(String(localized: "Settings"), id: "settings") {
            settingsContent
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1050, height: 600)
    }

    @ViewBuilder
    private var menuBarContent: some View {
        if AppConstants.isRunningTests {
            EmptyView()
        } else {
            MenuBarView()
        }
    }

    @ViewBuilder
    private var settingsContent: some View {
        if AppConstants.isRunningTests {
            EmptyView()
        } else {
            SettingsView()
                .sheet(item: $startupSheet, onDismiss: handleStartupSheetDismissed) { route in
                    switch route {
                    case .welcome:
                        WelcomeSheet()
                    case .postUpdateLicensing:
                        PostUpdateLicensePromptView(
                            onPersonalOSS: handlePersonalOSSSelection,
                            onWorkUsage: handleWorkUsageSelection,
                            onExistingKey: handleExistingKeySelection,
                            onBecomeSupporter: handleSupporterSelection,
                            onNotNow: handlePromptDismissalAction
                        )
                    }
                }
                .task {
                    refreshStartupSheet()
                }
        }
    }

    @ViewBuilder
    private var setupContent: some View {
        if AppConstants.isRunningTests {
            EmptyView()
        } else {
            SetupWizardView()
        }
    }

    @ViewBuilder
    private var historyContent: some View {
        if AppConstants.isRunningTests {
            EmptyView()
        } else {
            HistoryView()
        }
    }

    @ViewBuilder
    private var errorLogContent: some View {
        if AppConstants.isRunningTests {
            EmptyView()
        } else {
            ErrorLogView()
        }
    }

    @ViewBuilder
    private var mainWindowContent: some View {
        if AppConstants.isRunningTests {
            EmptyView()
        } else {
            MainWindowView()
        }
    }

    init() {
        guard !AppConstants.isRunningTests else { return }

        // Trigger ServiceContainer initialization
        _ = ServiceContainer.shared
        SettingsNavigationCoordinator.shared = SettingsNavigationCoordinator()
        WorkflowsNavigationCoordinator.shared = WorkflowsNavigationCoordinator()
        MainWindowCoordinator.shared = MainWindowCoordinator()
        PostUpdatePromptCoordinator.shared = PostUpdatePromptCoordinator()

        Task { @MainActor in
            await ServiceContainer.shared.initialize()
        }
    }

    private func refreshStartupSheet() {
        if HomeViewModel.shared.showSetupWizard {
            startupSheet = nil
            return
        }

        let nextRoute: StartupSheetRoute?
        if LicenseService.shared.needsWelcomeSheet {
            nextRoute = .welcome
        } else {
            nextRoute = postUpdatePromptCoordinator.activeSheetRoute
        }

        startupSheet = nextRoute
        if let nextRoute {
            lastPresentedStartupSheet = nextRoute
        }
    }

    private func handleStartupSheetDismissed() {
        let dismissedRoute = lastPresentedStartupSheet
        defer {
            lastPresentedStartupSheet = nil
        }

        if dismissedRoute == .postUpdateLicensing {
            if ignoreNextStartupSheetDismiss {
                ignoreNextStartupSheetDismiss = false
            } else {
                postUpdatePromptCoordinator.handleSheetDismissedWithoutExplicitAction()
            }
        }

        refreshStartupSheet()
    }

    private func dismissStartupPrompt(after action: () -> Void) {
        ignoreNextStartupSheetDismiss = true
        action()
        startupSheet = nil
    }

    private func handlePersonalOSSSelection() {
        dismissStartupPrompt {
            postUpdatePromptCoordinator.handlePersonalOSSSelection()
        }
    }

    private func handleWorkUsageSelection() {
        dismissStartupPrompt {
            postUpdatePromptCoordinator.handleWorkUsageSelection()
            settingsNavigation.navigateToLicense(target: .top)
        }
    }

    private func handleExistingKeySelection() {
        dismissStartupPrompt {
            postUpdatePromptCoordinator.handleExistingKeySelection()
            settingsNavigation.navigateToLicense(target: .activationKey)
        }
    }

    private func handleSupporterSelection() {
        dismissStartupPrompt {
            postUpdatePromptCoordinator.handleSupporterSelection()
            settingsNavigation.navigateToLicense(target: .supporter)
        }
    }

    private func handlePromptDismissalAction() {
        dismissStartupPrompt {
            postUpdatePromptCoordinator.handleNotNowSelection()
        }
    }
}

@MainActor
final class ActivationSourceTracker {
    static let shared = ActivationSourceTracker()

    private(set) var lastExternalApplication: NSRunningApplication?

    func recordActivation(_ application: NSRunningApplication?) {
        guard let application else { return }
        if application.processIdentifier == NSRunningApplication.current.processIdentifier {
            return
        }
        lastExternalApplication = application
    }
}

@MainActor
final class ManagedAppWindowOpener {
    static let shared = ManagedAppWindowOpener()

    var openWindow: OpenWindowAction?

    func open(id: String) {
        open(id: id, remainingAttempts: 10)
    }

    private func open(id: String, remainingAttempts: Int) {
        let sourceApplication = sourceApplicationForActivation()
        NSApp.setActivationPolicy(.regular)

        if let existingWindow = managedWindow(id: id) {
            reopenExistingWindow(existingWindow, sourceApplication: sourceApplication)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                self.reopenExistingWindow(existingWindow, sourceApplication: sourceApplication)
            }
            return
        }

        if let openWindow {
            openWindow(id: id)
        } else {
            NotificationCenter.default.post(
                name: .openManagedAppWindow,
                object: nil,
                userInfo: ["id": id]
            )
            if remainingAttempts > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    self.open(id: id, remainingAttempts: remainingAttempts - 1)
                }
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            guard let window = self.managedWindow(id: id) else { return }
            self.reopenExistingWindow(window, sourceApplication: sourceApplication)
        }
    }

    private func sourceApplicationForActivation() -> NSRunningApplication? {
        ActivationSourceTracker.shared.lastExternalApplication
            ?? NSWorkspace.shared.frontmostApplication
    }

    private func managedWindow(id: String) -> NSWindow? {
        NSApp.windows.first(where: { window in
            guard let identifier = window.identifier?.rawValue else { return false }
            return ManagedWindowMatching.matches(windowIdentifier: identifier, requestedID: id)
        })
    }

    private func reopenExistingWindow(_ window: NSWindow, sourceApplication: NSRunningApplication?) {
        NSApp.unhide(nil)
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        window.orderFrontRegardless()
        window.makeKeyAndOrderFront(nil)
        requestActivation(from: sourceApplication)
    }

    private func requestActivation(from sourceApplication: NSRunningApplication?) {
        let currentApplication = NSRunningApplication.current

        guard let sourceApplication,
              sourceApplication.processIdentifier != currentApplication.processIdentifier else {
            forceActivateCurrentApplication(currentApplication)
            return
        }

        let activated = currentApplication.activate(from: sourceApplication)
        if !activated {
            forceActivateCurrentApplication(currentApplication)
        }
    }

    private func forceActivateCurrentApplication(_ application: NSRunningApplication) {
        _ = application.activate()
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - App Delegate

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, SPUUpdaterDelegate {
    private var indicatorCoordinator: IndicatorCoordinator?
    private var translationHostWindow: NSWindow?
    private var menuBarIconObserver: NSKeyValueObservation?
    private var dockIconBehaviorObserver: NSKeyValueObservation?
    private var appActivationObserver: NSObjectProtocol?
    private var workspaceWakeObserver: NSObjectProtocol?
    private var hasInteractiveForegroundContent = false
    private lazy var updaterController = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: nil)

    var updateChecker: UpdateChecker {
        .sparkle(updaterController.updater)
    }

    private var showMenuBarIconPreference: Bool {
        UserDefaults.standard.object(forKey: UserDefaultsKeys.showMenuBarIcon) as? Bool ?? true
    }

    private var dockIconBehaviorPreference: DockIconBehavior {
        DockIconBehavior(rawValue: UserDefaults.standard.dockIconBehaviorWhenMenuBarHidden) ?? .keepVisible
    }

    private var shouldShowDockIcon: Bool {
        DockIconVisibility.shouldShowDockIcon(
            showMenuBarIcon: showMenuBarIconPreference,
            dockIconBehavior: dockIconBehaviorPreference,
            hasVisibleManagedWindow: hasVisibleManagedWindow,
            hasInteractiveForegroundContent: hasInteractiveForegroundContent
        )
    }

    static func registerDefaultUserDefaults(_ defaults: UserDefaults = .standard) {
        defaults.register(defaults: [
            UserDefaultsKeys.showMenuBarIcon: true,
            UserDefaultsKeys.showMainWindowAtLaunch: true,
            UserDefaultsKeys.dockIconBehaviorWhenMenuBarHidden: DockIconBehavior.keepVisible.rawValue,
            UserDefaultsKeys.updateChannel: AppConstants.defaultReleaseChannel.rawValue,
            UserDefaultsKeys.appFormattingEnabled: true,
            UserDefaultsKeys.transcriptionNumberNormalizationEnabled: true,
            UserDefaultsKeys.targetAppCorrectionLearningEnabled: false,
            // Meetings export root folder (plan D7/M4): meeting notes nest under "Meetings" in the
            // vault by default; clearing the field restores pre-root paths (the escape hatch).
            UserDefaultsKeys.meetingsObsidianRootFolder: "Meetings",
            // Speaker-recognition amendment (D-A7): adopt provider speaker labels by default.
            UserDefaultsKeys.meetingsPreferProviderSpeakerLabels: true
        ])
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.registerDefaultUserDefaults()

        guard !AppConstants.isRunningTests else {
            return
        }

        UpdateChecker.shared = updateChecker
        applyActivationPolicy()

        let coordinator = IndicatorCoordinator()
        coordinator.startObserving()
        indicatorCoordinator = coordinator

        #if canImport(Translation)
        if #available(macOS 15, *), let ts = ServiceContainer.shared.translationService as? TranslationService {
            translationHostWindow = TranslationHostWindow(translationService: ts)
            ts.setInteractiveHostMode = { [weak self] enabled in
                guard let self else { return }
                (self.translationHostWindow as? TranslationHostWindow)?.setInteractiveMode(enabled)
                self.hasInteractiveForegroundContent = enabled
                self.applyActivationPolicy(activate: enabled)
            }
        }
        #endif

        // Workflow palette hotkey - opens the standalone workflow palette panel
        ServiceContainer.shared.hotkeyService.onPromptPaletteToggle = {
            DictationViewModel.shared.triggerWorkflowPalette()
        }
        ServiceContainer.shared.hotkeyService.onRecentTranscriptionsToggle = {
            DictationViewModel.shared.triggerRecentTranscriptionsPalette()
        }
        ServiceContainer.shared.hotkeyService.onCopyLastTranscription = {
            DictationViewModel.shared.copyLastTranscriptionToClipboard()
        }
        ServiceContainer.shared.hotkeyService.onRecorderToggle = {
            AudioRecorderViewModel.shared.toggleRecording()
        }

        // Launch-window precedence (D2): first-run setup > post-update license prompt > main window.
        let launchDecision = LaunchWindowDecision.decide(
            isFirstRunSetupIncomplete: HomeViewModel.shared.showSetupWizard,
            postUpdatePromptPending: PostUpdatePromptCoordinator.shared.shouldAutoOpenSettingsOnLaunch,
            showMainWindowAtLaunch: UserDefaults.standard.bool(forKey: UserDefaultsKeys.showMainWindowAtLaunch)
        )
        switch launchDecision {
        case .setup:
            // Auto-open the standalone setup assistant while first-run setup is incomplete.
            UserDefaults.standard.set(false, forKey: UserDefaultsKeys.setupWizardCompleted)
            HomeViewModel.shared.showSetupWizard = true
            NSApp.setActivationPolicy(.regular)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.openSetupWindow()
            }
        case .settings:
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                self.openSettingsWindow()
            }
        case .main:
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                self.openMainWindow()
            }
        case .none:
            break
        }

        // Observe appearance preference changes
        menuBarIconObserver = UserDefaults.standard.observe(\.showMenuBarIcon, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in
                self?.applyActivationPolicy()
            }
        }
        dockIconBehaviorObserver = UserDefaults.standard.observe(\.dockIconBehaviorWhenMenuBarHidden, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in
                self?.applyActivationPolicy()
            }
        }

        appActivationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { notification in
            let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            Task { @MainActor in
                ActivationSourceTracker.shared.recordActivation(application)
            }
        }

        workspaceWakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { _ in
            PluginHTTPClient.resetSharedSession(reason: "macOS wake")
        }

        // Observe settings window lifecycle
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidBecomeKey(_:)),
            name: NSWindow.didBecomeKeyNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowWillClose(_:)),
            name: NSWindow.willCloseNotification,
            object: nil
        )
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleManagedWindow {
            if HomeViewModel.shared.showSetupWizard {
                openSetupWindow()
            } else {
                // Reopen (Dock click) opens the meetings-first main window (D2).
                openMainWindow()
            }
        }
        return true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            handleIncomingURL(url)
        }
    }

    private func openSettingsWindow() {
        ManagedAppWindowOpener.shared.open(id: AppWindowID.settings)
    }

    private func openSetupWindow() {
        ManagedAppWindowOpener.shared.open(id: AppWindowID.setup)
    }

    private func openMainWindow() {
        ManagedAppWindowOpener.shared.open(id: AppWindowID.main)
    }

    private func handleIncomingURL(_ url: URL) {
        // TypeWhisper is free and open source; there are no supporter/Discord
        // callback URLs to handle.
    }

    private func isManagedWindow(_ window: NSWindow) -> Bool {
        if let identifier = window.identifier?.rawValue,
           ManagedWindowMatching.isManaged(identifier: identifier) {
            return true
        }

        let title = window.title
        return title == String(localized: "Settings")
            || title == String(localized: "TypeWhisper Setup")
            || title == String(localized: "History")
            || title == String(localized: "Error Log")
            || title == String(localized: "meetings.window.title")
            || title == String(localized: "mainwindow.title")
    }

    private var hasVisibleManagedWindow: Bool {
        NSApp.windows.contains { isManagedWindow($0) && $0.isVisible }
    }

    private func applyActivationPolicy(activate: Bool = false) {
        let targetPolicy: NSApplication.ActivationPolicy = shouldShowDockIcon ? .regular : .accessory
        if NSApp.activationPolicy() != targetPolicy {
            NSApp.setActivationPolicy(targetPolicy)
        }

        if activate {
            NSApp.activate()
        }
    }

    @objc nonisolated private func windowDidBecomeKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isManagedWindow(window), window.isVisible else { return }
            self.applyActivationPolicy(activate: true)
        }
    }

    @objc nonisolated private func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isManagedWindow(window) else { return }
            self.applyActivationPolicy()
        }
    }

    nonisolated func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        AppConstants.effectiveUpdateChannel.sparkleChannels
    }
}
