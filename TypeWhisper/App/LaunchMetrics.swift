import Foundation
import os

/// Cheap launch instrumentation (perf plan Phase 3, finding 16). Logs milestones as milliseconds
/// since **process start** (the kernel's start time for this pid, so it includes dyld and
/// everything before `main`) and emits matching signposts, so a launch's before/after reads straight
/// from the dev build's log:
///
///     log stream --predicate 'category == "Launch"' --info
///
/// or as intervals in Instruments' os_signpost track. Every call is a timestamp plus one log line —
/// nothing here does work proportional to app data.
enum LaunchMetrics {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "TypeWhisper", category: "Launch")
    private static let signposter = OSSignposter(logger: logger)

    /// The process start time, read once from the kernel. `nil` only if `sysctl` fails.
    private static let processStart: Date? = {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0 else { return nil }
        let start = info.kp_proc.p_un.__p_starttime
        return Date(timeIntervalSince1970: TimeInterval(start.tv_sec) + TimeInterval(start.tv_usec) / 1_000_000)
    }()

    /// Milliseconds elapsed since the process started (`-1` when the start time is unknown).
    static func millisecondsSinceProcessStart() -> Int {
        guard let processStart else { return -1 }
        return Int(Date().timeIntervalSince(processStart) * 1_000)
    }

    /// Log a launch milestone (e.g. "services constructed", "first frame").
    static func mark(_ milestone: StaticString) {
        signposter.emitEvent(milestone)
        logger.notice("launch: \(milestone, privacy: .public) at \(millisecondsSinceProcessStart()) ms since process start")
    }

    /// Log how long one SwiftData store took to open (called by `SwiftDataStoreFactory`).
    static func storeOpened(_ storeName: String, duration: Duration) {
        let ms = Double(duration.components.attoseconds) / 1e15 + Double(duration.components.seconds) * 1_000
        signposter.emitEvent("store opened", "\(storeName, privacy: .public)")
        logger.notice("launch: store \(storeName, privacy: .public) opened in \(Int(ms.rounded())) ms")
    }

    /// Suspends until the main run loop next goes idle — after AppKit / SwiftUI have committed the
    /// pending frame. The observer is ordered after Core Animation's commit observer (order
    /// 2,000,000), so resuming here means whatever was on screen to draw has been handed off. Work
    /// awaited behind this no longer delays the first frame.
    @MainActor
    static func mainRunLoopIdle() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            // Non-repeating: the run loop invalidates the observer after its one callout.
            let observer = CFRunLoopObserverCreateWithHandler(
                kCFAllocatorDefault, CFRunLoopActivity.beforeWaiting.rawValue, false, 2_000_001
            ) { _, _ in
                continuation.resume()
            }
            CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        }
    }
}
