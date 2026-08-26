import SwiftUI

/// Retained as an inert stub. TypeWhisper is free and open source; the post-update
/// licensing prompt has been removed and this view is never presented. The closure
/// properties are kept so existing call sites continue to compile.
struct PostUpdateLicensePromptView: View {
    let onPersonalOSS: () -> Void
    let onWorkUsage: () -> Void
    let onExistingKey: () -> Void
    let onBecomeSupporter: () -> Void
    let onNotNow: () -> Void

    var body: some View {
        EmptyView()
    }
}
