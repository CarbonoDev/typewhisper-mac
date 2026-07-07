import Foundation

/// Persisted selection of which macOS calendars feed the meetings feature (M11 calendar
/// selection). Injected into `CalendarService` so a single choke point filters every consumer
/// (upcoming list, Earlier section, auto-brief scheduler, start notifications, capture-context
/// rules) consistently.
///
/// **Storage shape:** the *deselected* calendar identifiers are persisted, not the selected ones.
/// This is what makes "default all-selected, and calendars appearing later default to selected"
/// correct by construction: an identifier absent from the deselected set — including one never seen
/// before — is selected. Persisting the selected set instead would silently hide any calendar the
/// user adds after their first toggle.
@MainActor
protocol CalendarSelectionStoring: AnyObject {
    /// Whether events from the calendar with this identifier should be shown. Unknown identifiers
    /// (new calendars) are selected by default.
    func isSelected(_ calendarID: String) -> Bool
    /// Select or deselect a calendar and persist the change.
    func setSelected(_ selected: Bool, for calendarID: String)
    /// The identifiers the user has explicitly deselected (for tests / diagnostics).
    var deselectedCalendarIDs: Set<String> { get }
}

@MainActor
final class CalendarSelectionStore: CalendarSelectionStoring {
    private let defaults: UserDefaults
    private let key: String

    init(
        defaults: UserDefaults = .standard,
        key: String = UserDefaultsKeys.meetingsCalendarDeselectedIDs
    ) {
        self.defaults = defaults
        self.key = key
    }

    private(set) var cachedDeselected: Set<String>?

    var deselectedCalendarIDs: Set<String> {
        if let cachedDeselected { return cachedDeselected }
        let stored = defaults.stringArray(forKey: key) ?? []
        let set = Set(stored)
        cachedDeselected = set
        return set
    }

    func isSelected(_ calendarID: String) -> Bool {
        !deselectedCalendarIDs.contains(calendarID)
    }

    func setSelected(_ selected: Bool, for calendarID: String) {
        var set = deselectedCalendarIDs
        if selected {
            set.remove(calendarID)
        } else {
            set.insert(calendarID)
        }
        cachedDeselected = set
        defaults.set(Array(set).sorted(), forKey: key)
    }
}

/// One row of the "Calendars" settings list: a calendar plus its current selection state. Pure
/// value type so the list-rendering logic is unit-testable without EventKit or the view model.
struct CalendarSelectionRow: Identifiable, Equatable {
    let calendar: CalendarInfo
    var isSelected: Bool
    var id: String { calendar.id }
}
