import XCTest
@testable import TypeWhisper

/// Regression guard for settings-pane reachability.
///
/// `settingsDestinationSections` is the single source of truth both settings shells consume to
/// build their sidebars, so every `SettingsTab` case must land in exactly one of its sections to be
/// reachable at all. This is the invariant that broke when the `.prompts` and `.profiles` panes
/// lost their rows: the detail switch still handled them, but they were placed in no section, so
/// their sidebar rows vanished and their deep links dead-ended on Workflows.
final class SettingsDestinationCoverageTests: XCTestCase {
    /// One destination per tab; only the `tab` identity drives placement, so the title and image
    /// are filler.
    private var allDestinations: [SettingsDestination] {
        SettingsTab.allCases.map { tab in
            SettingsDestination(tab: tab, title: "\(tab)", systemImage: "circle", badge: nil)
        }
    }

    private var placedTabs: [SettingsTab] {
        settingsDestinationSections(allDestinations).flatMap { $0.destinations.map(\.tab) }
    }

    func testEverySettingsTabAppearsInExactlyOneSidebarSection() {
        let placed = placedTabs

        // No tab is placed in more than one section.
        XCTAssertEqual(placed.count, Set(placed).count, "A SettingsTab is listed in more than one section")

        // Every case has a row and no stray tab is introduced: the placed set equals every case.
        XCTAssertEqual(
            Set(placed),
            Set(SettingsTab.allCases),
            "Every SettingsTab must appear in exactly one sidebar section"
        )
    }

    /// The Prompts and Rules panes each own a sidebar row and are no longer collapsed onto
    /// Workflows — the specific dead-end this guards against.
    func testPromptsAndRulesHaveTheirOwnRows() {
        let placed = placedTabs
        XCTAssertTrue(placed.contains(.prompts), "Prompts pane has no sidebar row")
        XCTAssertTrue(placed.contains(.profiles), "Rules pane has no sidebar row")
    }
}
