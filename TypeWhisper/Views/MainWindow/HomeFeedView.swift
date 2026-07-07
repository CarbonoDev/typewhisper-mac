import SwiftUI

/// The meetings Home feed (plan Track C / D6): a live-recording banner while capturing, a serif
/// "Coming up" calendar card (M11 colors/labels), and a day-grouped meeting timeline with state
/// badges (absorbing M10's Earlier/running-long data through the Home seams). No usage stats — the
/// old dictation dashboard lives in Settings › Dictation › Overview. No "Ask across your meetings…"
/// bar (omitted until Phase 3 per adjudication).
struct HomeFeedView: View {
    @ObservedObject private var viewModel = MeetingsViewModel.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text(String(localized: "home.title"))
                    .font(.largeTitle)
                    .fontDesign(.serif)
                    .fontWeight(.bold)

                HomeLiveBanner()

                if let error = viewModel.calendarErrorMessage {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                ComingUpCard()

                MeetingTimeline()
            }
            .padding(24)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(String(localized: "mainwindow.sidebar.home"))
    }
}
