import SwiftUI

/// Step 0 stub for the meetings Home feed (UI Step 0, D3/D6). Track C replaces this file wholesale
/// with the real serif "Coming up" card, live banner, and day-grouped timeline. Kept minimal here so
/// the shell compiles and the `.home` route is whole from the first merge.
struct HomeFeedView: View {
    var body: some View {
        ContentUnavailableView {
            Label(String(localized: "mainwindow.home.stub.title"), systemImage: "house")
        } description: {
            Text(String(localized: "mainwindow.home.stub.message"))
        }
    }
}
