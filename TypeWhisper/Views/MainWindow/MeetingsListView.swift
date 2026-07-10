import SwiftUI

/// The full meetings list shown for `MainWindowRoute.meetings` (UI Step 0, D3). Re-expresses the
/// row rendering and the New/Import toolbar menu of today's `MeetingsWindowView` sidebar, but routes
/// selections through `MainWindowCoordinator.shared` instead of a local `@State` selection.
///
/// LX-1 adds a composable filter bar (search + date-range + state + source + language facets, all
/// coordinator-held and AND-composed with the sidebar folder/tag filter through the pure
/// `MeetingsViewModel.filteredMeetings` choke point) and native multi-select via `List(selection:)`.
///
/// Owner discoverability: the New Meeting menu carries a labeled "Import transcript or audio…" item
/// alongside Start recording / Create empty, and there is a dedicated Import toolbar button.
struct MeetingsListView: View {
    @ObservedObject private var viewModel = MeetingsViewModel.shared
    @ObservedObject private var coordinator = MainWindowCoordinator.shared
    @State private var isPresentingImport = false
    @State private var customStart = Calendar.current.startOfDay(for: Date())
    // Day-aligned (start of today) so the Custom range's end bound is not pinned to the current
    // wall-clock instant — see `dayAlignedRange` (LX-1 finding #3).
    @State private var customEnd = Calendar.current.startOfDay(for: Date())
    @State private var isPresentingCustomDate = false

    /// The meetings shown after applying the coordinator's active folder + tag filters AND the LX-1
    /// filter-bar facets, which all compose (AND) through the one pure choke point (plan D8/LX-1). No
    /// active filters = the full list.
    private var displayedMeetings: [Meeting] {
        MeetingsViewModel.filteredMeetings(
            viewModel.meetings,
            folder: coordinator.activeFolder,
            tag: coordinator.activeTag,
            unfiledOnly: coordinator.unfiledOnly,
            searchText: coordinator.searchText,
            dateRange: coordinator.dateRange,
            stateFacets: coordinator.stateFacets,
            sourceFacet: coordinator.sourceFacet,
            languageFilter: coordinator.languageFilter
        )
    }

    /// True while any filter (sidebar folder/tag/unfiled or an LX-1 facet) is active (drives the
    /// combined header + filter-specific empty state).
    private var isFiltered: Bool {
        coordinator.activeFolder != nil
            || coordinator.activeTag != nil
            || coordinator.unfiledOnly
            || coordinator.hasActiveFacets
    }

    /// The on-screen selection (selection intersected with the currently displayed meetings).
    private var visibleSelectionCount: Int {
        viewModel.visibleSelection(in: displayedMeetings.map(\.id)).count
    }

    var body: some View {
        VStack(spacing: 0) {
            filterBar
            Divider()
            list
        }
        .navigationTitle(String(localized: "mainwindow.meetings.title"))
        .toolbar {
            ToolbarItem {
                newMeetingMenu
            }
            ToolbarItem {
                Button {
                    isPresentingImport = true
                } label: {
                    Label(String(localized: "meetings.import.toolbar"), systemImage: "square.and.arrow.down")
                }
            }
        }
        .sheet(isPresented: $isPresentingImport) {
            MeetingImportView(mergeTarget: nil) { meeting in
                coordinator.openMeeting(id: meeting.id)
            }
        }
    }

    // MARK: - List

    private var list: some View {
        List(selection: $viewModel.selectedMeetingIDs) {
            if let error = viewModel.captureErrorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            if isFiltered {
                filterHeader
            }
            if displayedMeetings.isEmpty {
                if isFiltered {
                    filteredEmptyState
                } else {
                    emptyState
                }
            } else {
                ForEach(displayedMeetings, id: \.id) { meeting in
                    // Non-Button row (HistoryView's idiom) so the List's NSTableView-backed selection
                    // receives ⌘/⇧-click and ⌘-A natively; a plain tap opens the meeting. A full-width
                    // Button here swallowed modified clicks and broke multi-select (LX-1 finding #1).
                    row(meeting)
                        .tag(meeting.id)
                        // A plain TapGesture has no modifier exclusion, so it would also fire on
                        // ⌘/⇧-click and steal them from the List's native NSTableView selection
                        // (breaking multi-select — LX-1 finding #1). Fall through when a select
                        // modifier is held so only an unmodified click opens the meeting.
                        .onTapGesture {
                            guard NSEvent.modifierFlags.intersection([.command, .shift]).isEmpty else { return }
                            coordinator.openMeeting(id: meeting.id)
                        }
                }
            }
        }
        // Normalize the selection to the still-visible set whenever the filtered list changes (plan
        // LX-1 D3: keep visible picks, drop hidden ones — History's "normalize, don't nuke").
        .onChange(of: displayedMeetings.map(\.id)) { _, ids in
            viewModel.selectedMeetingIDs = MeetingsViewModel.normalizedSelection(
                viewModel.selectedMeetingIDs, toVisibleIDs: ids
            )
        }
    }

    // MARK: - Filter bar (plan LX-1)

    private var filterBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField(
                    String(localized: "meetings.filter.search.placeholder"),
                    text: Binding(
                        get: { coordinator.searchText },
                        set: { coordinator.setSearchText($0) }
                    )
                )
                .textFieldStyle(.plain)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
            .frame(maxWidth: 260)

            dateMenu
            stateMenu
            sourceMenu
            languageMenu

            Spacer()

            if visibleSelectionCount > 0 {
                Label(
                    String(format: String(localized: "meetings.selection.count"), visibleSelectionCount),
                    systemImage: "checkmark.circle"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var dateMenu: some View {
        Menu {
            dateOption(String(localized: "meetings.filter.date.all"), .all)
            dateOption(String(localized: "meetings.filter.date.today"), .today)
            dateOption(String(localized: "meetings.filter.date.thisWeek"), .thisWeek)
            dateOption(String(localized: "meetings.filter.date.thisMonth"), .thisMonth)
            Divider()
            Button {
                // Apply the current (day-aligned) custom bounds and open the editor popover. DatePickers
                // do not work inside an NSMenu-backed Menu, so they live in a popover (LX-1 finding #4).
                coordinator.setDateRange(dayAlignedRange(start: customStart, end: customEnd))
                isPresentingCustomDate = true
            } label: {
                Label(String(localized: "meetings.filter.date.custom"), systemImage: isCustomDate ? "checkmark" : "calendar")
            }
        } label: {
            facetMenuLabel(title: String(localized: "meetings.filter.date"), isActive: coordinator.dateRange != .all)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .popover(isPresented: $isPresentingCustomDate, arrowEdge: .bottom) {
            customDatePopover
        }
    }

    /// The interactive custom-range editor. DatePickers render inert inside a Menu on macOS, so the two
    /// day pickers live here in a popover anchored to the date facet (LX-1 finding #4). Each edit routes
    /// through `setCustomStart`/`setCustomEnd`, which day-align the bounds before applying the range.
    private var customDatePopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(String(localized: "meetings.filter.date.custom"))
                .font(.headline)
            DatePicker(
                String(localized: "meetings.filter.date.custom.start"),
                selection: Binding(get: { customStart }, set: { setCustomStart($0) }),
                displayedComponents: .date
            )
            DatePicker(
                String(localized: "meetings.filter.date.custom.end"),
                selection: Binding(get: { customEnd }, set: { setCustomEnd($0) }),
                displayedComponents: .date
            )
        }
        .padding()
        .frame(minWidth: 240)
    }

    private func dateOption(_ title: String, _ range: MeetingDateRange) -> some View {
        Button {
            coordinator.setDateRange(range)
        } label: {
            menuCheckLabel(title, isSelected: coordinator.dateRange == range)
        }
    }

    /// A single-choice menu-item label with a native leading checkmark when selected and a plain title
    /// otherwise. Avoids `Image(systemName: "")`, an invalid SF Symbol that logs a warning on every menu
    /// render (LX-1 finding #5).
    @ViewBuilder
    private func menuCheckLabel(_ title: String, isSelected: Bool) -> some View {
        if isSelected {
            Label(title, systemImage: "checkmark")
        } else {
            Text(title)
        }
    }

    private var stateMenu: some View {
        Menu {
            stateOption(String(localized: "meetings.filter.state.hasTranscript"), .hasTranscript)
            stateOption(String(localized: "meetings.filter.state.hasSummary"), .hasSummary)
            stateOption(String(localized: "meetings.filter.state.hasBrief"), .hasBrief)
            stateOption(String(localized: "meetings.filter.state.hasExtended"), .hasExtended)
        } label: {
            facetMenuLabel(title: String(localized: "meetings.filter.state"), isActive: !coordinator.stateFacets.isEmpty)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private func stateOption(_ title: String, _ facet: MeetingStateFacet) -> some View {
        Button {
            coordinator.toggleStateFacet(facet)
        } label: {
            menuCheckLabel(title, isSelected: coordinator.stateFacets.contains(facet))
        }
    }

    private var sourceMenu: some View {
        Menu {
            sourceOption(String(localized: "meetings.filter.source.all"), .all)
            sourceOption(String(localized: "meetings.filter.source.captured"), .captured)
            sourceOption(String(localized: "meetings.filter.source.imported"), .imported)
        } label: {
            facetMenuLabel(title: String(localized: "meetings.filter.source"), isActive: coordinator.sourceFacet != .all)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private func sourceOption(_ title: String, _ facet: MeetingSourceFacet) -> some View {
        Button {
            coordinator.setSourceFacet(facet)
        } label: {
            menuCheckLabel(title, isSelected: coordinator.sourceFacet == facet)
        }
    }

    @ViewBuilder
    private var languageMenu: some View {
        let codes = MeetingsViewModel.languageCodesPresent(in: viewModel.meetings)
        if !codes.isEmpty {
            Menu {
                Button {
                    coordinator.setLanguageFilter(nil)
                } label: {
                    menuCheckLabel(String(localized: "meetings.filter.language.any"), isSelected: coordinator.languageFilter == nil)
                }
                ForEach(codes, id: \.self) { code in
                    Button {
                        coordinator.setLanguageFilter(code)
                    } label: {
                        menuCheckLabel(code.uppercased(), isSelected: coordinator.languageFilter == code)
                    }
                }
            } label: {
                facetMenuLabel(title: String(localized: "meetings.filter.language"), isActive: coordinator.languageFilter != nil)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }

    private func facetMenuLabel(title: String, isActive: Bool) -> some View {
        HStack(spacing: 3) {
            Text(title)
            Image(systemName: "chevron.down")
                .font(.caption2)
        }
        .font(.callout)
        .fontWeight(isActive ? .semibold : .regular)
        .foregroundStyle(isActive ? Color.accentColor : Color.secondary)
    }

    private var isCustomDate: Bool {
        if case .custom = coordinator.dateRange { return true }
        return false
    }

    private func setCustomStart(_ date: Date) {
        customStart = date
        coordinator.setDateRange(dayAlignedRange(start: date, end: customEnd))
    }

    private func setCustomEnd(_ date: Date) {
        customEnd = date
        coordinator.setDateRange(dayAlignedRange(start: customStart, end: date))
    }

    /// Build a day-aligned custom range: `start` snaps to the start of its day and `end` to the last
    /// instant of its day, so `withinDateRange`'s inclusive `effective <= end` compare keeps meetings
    /// that fall later in the end day (LX-1 finding #3 — the predicate promises day-aligned bounds and
    /// the view is where they are constructed).
    private func dayAlignedRange(start: Date, end: Date) -> MeetingDateRange {
        let calendar = Calendar.current
        let alignedStart = calendar.startOfDay(for: start)
        let endDay = calendar.startOfDay(for: end)
        let alignedEnd = (calendar.date(byAdding: .day, value: 1, to: endDay) ?? endDay).addingTimeInterval(-1)
        return .custom(start: alignedStart, end: alignedEnd)
    }

    private var newMeetingMenu: some View {
        Menu {
            Button {
                Task {
                    // Guarded create+start so a rapid double-click can't leave a stray empty meeting.
                    if let meeting = await viewModel.createAndStartAdHocCapture() {
                        coordinator.openMeeting(id: meeting.id)
                    }
                }
            } label: {
                Label(String(localized: "meetings.newMeeting.startRecording"), systemImage: "record.circle")
            }
            .disabled(!viewModel.canStartCapture)

            Button {
                let meeting = viewModel.createAdHocMeeting()
                coordinator.openMeeting(id: meeting.id)
            } label: {
                Label(String(localized: "meetings.newMeeting.createEmpty"), systemImage: "doc.badge.plus")
            }

            Divider()

            Button {
                isPresentingImport = true
            } label: {
                Label(String(localized: "mainwindow.newMeeting.import"), systemImage: "square.and.arrow.down")
            }
        } label: {
            Label(String(localized: "meetings.newMeeting"), systemImage: "plus")
        }
    }

    /// The "Filtered by 📁 path · #tag · facets ✕ Clear" header shown above the list when any filter is
    /// active (plan D8/LX-1). Each active facet is individually clearable; Clear resets all.
    private var filterHeader: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Text(String(localized: "mainwindow.meetings.filteredBy"))
                    .font(.callout)
                if let folder = coordinator.activeFolder {
                    facet(icon: "folder", text: folder) { coordinator.clearFolderFilter() }
                }
                if coordinator.unfiledOnly {
                    facet(icon: "tray", text: String(localized: "mainwindow.folders.unfiled")) {
                        coordinator.clearUnfiledFilter()
                    }
                }
                if let tag = coordinator.activeTag {
                    facet(icon: "tag", text: "#\(tag)") { coordinator.clearTagFilter() }
                }
                facetChips
            }
            Spacer()
            Button {
                coordinator.clearAllFilters()
            } label: {
                Label(String(localized: "mainwindow.meetings.filter.clear"), systemImage: "xmark.circle.fill")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    /// The LX-1 facet chips (search / date / state / source / language), each individually clearable.
    @ViewBuilder
    private var facetChips: some View {
        let search = coordinator.searchText.trimmingCharacters(in: .whitespaces)
        if !search.isEmpty {
            facet(icon: "magnifyingglass", text: search) { coordinator.setSearchText("") }
        }
        if coordinator.dateRange != .all {
            facet(icon: "calendar", text: dateRangeLabel(coordinator.dateRange)) { coordinator.setDateRange(.all) }
        }
        // Iterate declaration order (not the Set) so chips render deterministically (LX-1 finding #6).
        ForEach(MeetingStateFacet.allCases.filter { coordinator.stateFacets.contains($0) }, id: \.self) { stateFacet in
            facet(icon: "checkmark.seal", text: stateFacetLabel(stateFacet)) {
                coordinator.toggleStateFacet(stateFacet)
            }
        }
        if coordinator.sourceFacet != .all {
            facet(icon: "square.and.arrow.down", text: sourceFacetLabel(coordinator.sourceFacet)) {
                coordinator.setSourceFacet(.all)
            }
        }
        if let code = coordinator.languageFilter {
            facet(icon: "globe", text: code.uppercased()) { coordinator.setLanguageFilter(nil) }
        }
    }

    private func dateRangeLabel(_ range: MeetingDateRange) -> String {
        switch range {
        case .all: return String(localized: "meetings.filter.date.all")
        case .today: return String(localized: "meetings.filter.date.today")
        case .thisWeek: return String(localized: "meetings.filter.date.thisWeek")
        case .thisMonth: return String(localized: "meetings.filter.date.thisMonth")
        case .custom: return String(localized: "meetings.filter.date.custom")
        }
    }

    private func stateFacetLabel(_ facet: MeetingStateFacet) -> String {
        switch facet {
        case .hasTranscript: return String(localized: "meetings.filter.state.hasTranscript")
        case .hasSummary: return String(localized: "meetings.filter.state.hasSummary")
        case .hasBrief: return String(localized: "meetings.filter.state.hasBrief")
        case .hasExtended: return String(localized: "meetings.filter.state.hasExtended")
        }
    }

    private func sourceFacetLabel(_ facet: MeetingSourceFacet) -> String {
        switch facet {
        case .all: return String(localized: "meetings.filter.source.all")
        case .captured: return String(localized: "meetings.filter.source.captured")
        case .imported: return String(localized: "meetings.filter.source.imported")
        }
    }

    /// One clearable filter facet capsule (folder / tag / LX-1 facet).
    private func facet(icon: String, text: String, onClear: @escaping () -> Void) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
            Text(text).fontWeight(.semibold)
            Button(action: onClear) {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .font(.callout)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(.secondary.opacity(0.12), in: Capsule())
    }

    /// Filter-specific empty state (M3 minor 4): a filter that matches nothing must not show the
    /// generic "record your first meeting" prompt.
    private var filteredEmptyState: some View {
        ContentUnavailableView {
            Label(String(localized: "mainwindow.meetings.empty.filtered.title"), systemImage: "line.3.horizontal.decrease.circle")
        } description: {
            Text(String(localized: "mainwindow.meetings.empty.filtered.message"))
        } actions: {
            Button {
                coordinator.clearAllFilters()
            } label: {
                Text(String(localized: "mainwindow.meetings.filter.clear"))
            }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label(String(localized: "mainwindow.meetings.empty.title"), systemImage: "person.2.wave.2")
        } description: {
            Text(String(localized: "mainwindow.meetings.empty.message"))
        } actions: {
            Button {
                isPresentingImport = true
            } label: {
                Text(String(localized: "mainwindow.newMeeting.import"))
            }
        }
    }

    private func row(_ meeting: Meeting) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(meeting.title)
                .lineLimit(1)
            HStack(spacing: 6) {
                if meeting.id == viewModel.activeMeeting?.id, viewModel.isCapturing {
                    Image(systemName: "record.circle")
                        .foregroundStyle(.red)
                }
                if let start = meeting.startDate {
                    Text(start, style: .date)
                }
                Text(meeting.state.displayName)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}
