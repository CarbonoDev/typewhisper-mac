import Combine
import Foundation
import SwiftUI

/// The live capture's elapsed-seconds clock, split out of `MeetingsViewModel` so its 1 Hz tick only
/// invalidates the few views that render a running timer (live band, home banner, document bottom
/// bar, tray title) instead of every observer of the singleton view model.
///
/// Owned by `MeetingsViewModel` as `captureClock` (a plain `let`, never `@Published`). Mirrors
/// `MeetingCaptureService.$elapsedSeconds` and nothing else hot — keep it that way, or the narrowing
/// is lost.
@MainActor
final class CaptureClock: ObservableObject {
    /// Seconds elapsed in the current capture; `0` when idle.
    @Published private(set) var elapsedSeconds: TimeInterval

    private var cancellable: AnyCancellable?

    init(captureService: MeetingCaptureService) {
        elapsedSeconds = captureService.elapsedSeconds
        cancellable = captureService.$elapsedSeconds
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in self?.elapsedSeconds = value }
    }
}

/// Leaf text that renders the capture clock, so the 1 Hz tick re-renders only this `Text` rather than
/// the enclosing band/banner/bar. `overrideText` (e.g. "Finalizing…") replaces the timer when set.
struct CaptureElapsedText: View {
    @ObservedObject private var clock = MeetingsViewModel.shared.captureClock
    private let overrideText: String?
    private let format: (TimeInterval) -> String

    init(overrideText: String? = nil, format: @escaping (TimeInterval) -> String) {
        self.overrideText = overrideText
        self.format = format
    }

    var body: some View {
        Text(overrideText ?? format(clock.elapsedSeconds))
    }
}
