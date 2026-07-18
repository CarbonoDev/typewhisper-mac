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
    /// filter-bar facets, which all compose (AND) through the one pure choke point (plan D8/LX-1),
    /// then sorted by effective date per the archive's sort control. No active filters = the full list.
    private var displayedMeetings: [Meeting] {
        let filtered = MeetingsViewModel.filteredMeetings(
            viewModel.meetings,
            folder: coordinator.activeFolder,
            tag: coordinator.activeTag,
            unfiledOnly: coordinator.unfiledOnly,
            searchText: coordinator.searchText,
            dateRange: coordinator.dateRange,
            stateFacets: coordinator.stateFacets,
            sourceFacet: coordinator.sourceFacet,
            languageFilter: coordinator.languageFilter,
            folderFacets: coordinator.folderFacets
        )
        let newestFirst = coordinator.meetingsSortNewestFirst
        return filtered.sorted {
            let a = Self.effectiveDate($0)
            let b = Self.effectiveDate($1)
            return newestFirst ? a > b : a < b
        }
    }

    /// The date a row sorts (and shows) by: the stored start, else the one embedded in an imported
    /// export filename, else creation.
    static func effectiveDate(_ meeting: Meeting) -> Date {
        meeting.startDate ?? ImportedMeetingTitle.parse(meeting.title).date ?? meeting.createdAt
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
        let duplicates = Self.duplicateMeetingIDs(in: displayedMeetings)
        return List(selection: $viewModel.selectedMeetingIDs) {
            if let error = viewModel.captureErrorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            if isFiltered {
                filterHeader
                    .listRowSeparator(.hidden)
            }
            if displayedMeetings.isEmpty {
                if isFiltered {
                    filteredEmptyState
                        .listRowSeparator(.hidden)
                } else {
                    emptyState
                        .listRowSeparator(.hidden)
                }
            } else {
                ForEach(displayedMeetings, id: \.id) { meeting in
                    // Non-Button row (HistoryView's idiom) so the List's NSTableView-backed selection
                    // receives ⌘/⇧-click and ⌘-A natively; a plain tap opens the meeting. A full-width
                    // Button here swallowed modified clicks and broke multi-select (LX-1 finding #1).
                    ArchiveRow(
                        meeting: meeting,
                        isLive: meeting.id == viewModel.activeMeeting?.id && viewModel.isCapturing,
                        isDuplicate: duplicates.contains(meeting.id),
                        isSelected: viewModel.selectedMeetingIDs.contains(meeting.id)
                    )
                        .tag(meeting.id)
                        .listRowSeparator(.hidden)
                        // The row draws its own card fill + selection tint (from the bound selection
                        // set) — suppress the native table highlight so the two don't stack.
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 3, leading: 12, bottom: 3, trailing: 12))
                        // A plain TapGesture has no modifier exclusion, so it would also fire on
                        // ⌘/⇧-click and steal them from the List's native NSTableView selection
                        // (breaking multi-select — LX-1 finding #1). Fall through when a select
                        // modifier is held so only an unmodified click opens the meeting.
                        .onTapGesture {
                            guard NSEvent.modifierFlags.intersection([.command, .shift]).isEmpty else { return }
                            coordinator.openMeeting(id: meeting.id)
                        }
                        // Shared row right-click menu (plan LX-2, D4): single-vs-multi branch on the
                        // native `List(selection:)` set, identical to the folder-detail rows.
                        .meetingRowContextMenu(for: meeting)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        // Normalize the selection to the still-visible set whenever the filtered list changes (plan
        // LX-1 D3: keep visible picks, drop hidden ones — History's "normalize, don't nuke").
        .onChange(of: displayedMeetings.map(\.id)) { _, ids in
            viewModel.selectedMeetingIDs = MeetingsViewModel.normalizedSelection(
                viewModel.selectedMeetingIDs, toVisibleIDs: ids
            )
        }
    }

    /// [Sprint 3] Same-day meetings whose normalized titles collide — everything but the newest in
    /// each (clean title, day) group is flagged as a possible duplicate. Display-only; nothing is
    /// merged or hidden.
    static func duplicateMeetingIDs(in meetings: [Meeting], calendar: Calendar = .current) -> Set<UUID> {
        var groups: [String: [(id: UUID, date: Date)]] = [:]
        for meeting in meetings {
            let clean = ImportedMeetingTitle.displayTitle(for: meeting.title)
                .lowercased()
                .trimmingCharacters(in: .whitespaces)
            guard !clean.isEmpty else { continue }
            let date = meeting.startDate ?? ImportedMeetingTitle.parse(meeting.title).date ?? meeting.createdAt
            let day = calendar.startOfDay(for: date)
            let key = "\(clean)|\(day.timeIntervalSinceReferenceDate)"
            groups[key, default: []].append((meeting.id, date))
        }
        var flagged = Set<UUID>()
        for (_, members) in groups where members.count > 1 {
            let sorted = members.sorted { $0.date > $1.date }
            for member in sorted.dropFirst() {
                flagged.insert(member.id)
            }
        }
        return flagged
    }

    // MARK: - Filter bar (plan LX-1)

    /// [Sprint 3] Search-first bar: the search field is the hero, and the four facet dropdowns fold
    /// into one Filter menu whose badge carries the active-facet count.
    private var filterBar: some View {
        HStack(spacing: MeetingTheme.s2) {
            HStack(spacing: MeetingTheme.s1) {
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
                .font(MeetingTheme.meta)
            }
            .padding(.horizontal, MeetingTheme.s3)
            .padding(.vertical, 6)
            .background(MeetingTheme.chipFill, in: RoundedRectangle(cornerRadius: MeetingTheme.rowRadius))
            .frame(maxWidth: 380)

            folderMenu
            sortMenu
            filterMenu

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
        .padding(.horizontal, MeetingTheme.s3)
        .padding(.vertical, MeetingTheme.s2)
    }

    /// The count the Filter button badges: every non-default facet except search (which is visible
    /// in the field itself).
    private var activeFacetCount: Int {
        var count = coordinator.stateFacets.count
        if coordinator.dateRange != .all { count += 1 }
        if coordinator.sourceFacet != .all { count += 1 }
        if coordinator.languageFilter != nil { count += 1 }
        return count
    }

    /// [Sprint 5] First-class multi-select folder filter: pick all folders or any subset. The label
    /// names a single selection outright; multiples collapse to a count.
    private var folderMenu: some View {
        let facets = coordinator.folderFacets
        return Menu {
            Button {
                coordinator.clearFolderFacets()
            } label: {
                menuCheckLabel(String(localized: "meetings.folderFilter.all"), isSelected: facets.isEmpty)
            }
            let folders = Self.flattenedFolders(MeetingOrganizationIndex.shared.folderTree)
            if !folders.isEmpty {
                Divider()
                ForEach(folders, id: \.path) { node in
                    Button {
                        coordinator.toggleFolderFacet(node.path)
                    } label: {
                        menuCheckLabel(node.path, isSelected: facets.contains(node.path))
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "folder")
                    .font(.system(size: 12))
                Text(folderMenuTitle)
                    .font(MeetingTheme.meta)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
            }
            .foregroundStyle(facets.isEmpty ? Color.secondary : Color.accentColor)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private var folderMenuTitle: String {
        let facets = coordinator.folderFacets
        switch facets.count {
        case 0:
            return String(localized: "meetings.folderFilter.all")
        case 1:
            return facets.first ?? ""
        default:
            return String(format: String(localized: "meetings.folderFilter.count"), facets.count)
        }
    }

    /// Depth-first flatten of the sidebar's folder tree — full paths keep nesting readable in a
    /// flat menu ("Binnacle/Docs").
    static func flattenedFolders(_ nodes: [MeetingFolderNode]) -> [MeetingFolderNode] {
        nodes.flatMap { [ $0 ] + flattenedFolders($0.children) }
    }

    /// [Sprint 5] Date-sort control: newest or oldest first.
    private var sortMenu: some View {
        Menu {
            Button {
                coordinator.meetingsSortNewestFirst = true
            } label: {
                menuCheckLabel(String(localized: "meetings.sort.newestFirst"), isSelected: coordinator.meetingsSortNewestFirst)
            }
            Button {
                coordinator.meetingsSortNewestFirst = false
            } label: {
                menuCheckLabel(String(localized: "meetings.sort.oldestFirst"), isSelected: !coordinator.meetingsSortNewestFirst)
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(String(localized: "meetings.sort.menu"))
    }

    private var filterMenu: some View {
        Menu {
            Section(String(localized: "meetings.filter.date")) {
                dateOption(String(localized: "meetings.filter.date.all"), .all)
                dateOption(String(localized: "meetings.filter.date.today"), .today)
                dateOption(String(localized: "meetings.filter.date.thisWeek"), .thisWeek)
                dateOption(String(localized: "meetings.filter.date.thisMonth"), .thisMonth)
                Button {
                    // Apply the current (day-aligned) custom bounds and open the editor popover.
                    // DatePickers do not work inside an NSMenu-backed Menu, so they live in a popover
                    // (LX-1 finding #4), now anchored at the Filter button.
                    coordinator.setDateRange(dayAlignedRange(start: customStart, end: customEnd))
                    isPresentingCustomDate = true
                } label: {
                    Label(String(localized: "meetings.filter.date.custom"), systemImage: isCustomDate ? "checkmark" : "calendar")
                }
            }
            Section(String(localized: "meetings.filter.state")) {
                stateOption(String(localized: "meetings.filter.state.hasTranscript"), .hasTranscript)
                stateOption(String(localized: "meetings.filter.state.hasSummary"), .hasSummary)
                stateOption(String(localized: "meetings.filter.state.hasBrief"), .hasBrief)
                stateOption(String(localized: "meetings.filter.state.hasExtended"), .hasExtended)
            }
            Section(String(localized: "meetings.filter.source")) {
                sourceOption(String(localized: "meetings.filter.source.all"), .all)
                sourceOption(String(localized: "meetings.filter.source.captured"), .captured)
                sourceOption(String(localized: "meetings.filter.source.imported"), .imported)
            }
            languageSection
            if activeFacetCount > 0 {
                Divider()
                Button {
                    // Clear only what this menu owns. `clearFacetState()` would also wipe the
                    // search text the user can see (and is likely actively using) in the field.
                    coordinator.setDateRange(.all)
                    for facet in MeetingStateFacet.allCases where coordinator.stateFacets.contains(facet) {
                        coordinator.toggleStateFacet(facet)
                    }
                    coordinator.setSourceFacet(.all)
                    coordinator.setLanguageFilter(nil)
                } label: {
                    Label(String(localized: "mainwindow.meetings.filter.clear"), systemImage: "xmark.circle")
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "line.3.horizontal.decrease.circle")
                    .font(.system(size: 15))
                if activeFacetCount > 0 {
                    Text("\(activeFacetCount)")
                        .font(.caption2.bold())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.accentColor, in: Capsule())
                }
            }
            .foregroundStyle(activeFacetCount > 0 ? Color.accentColor : Color.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(String(localized: "meetings.filter.menu"))
        .popover(isPresented: $isPresentingCustomDate, arrowEdge: .bottom) {
            customDatePopover
        }
    }

    @ViewBuilder
    private var languageSection: some View {
        let codes = MeetingsViewModel.languageCodesPresent(in: viewModel.meetings)
        if !codes.isEmpty {
            Section(String(localized: "meetings.filter.language")) {
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
            }
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

    private func stateOption(_ title: String, _ facet: MeetingStateFacet) -> some View {
        Button {
            coordinator.toggleStateFacet(facet)
        } label: {
            menuCheckLabel(title, isSelected: coordinator.stateFacets.contains(facet))
        }
    }

    private func sourceOption(_ title: String, _ facet: MeetingSourceFacet) -> some View {
        Button {
            coordinator.setSourceFacet(facet)
        } label: {
            menuCheckLabel(title, isSelected: coordinator.sourceFacet == facet)
        }
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
        ForEach(coordinator.folderFacets.sorted(), id: \.self) { path in
            facet(icon: "folder", text: path) { coordinator.toggleFolderFacet(path) }
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

    /// One clearable filter facet capsule (folder / tag / LX-1 facet) — the blessed chip recipe.
    private func facet(icon: String, text: String, onClear: @escaping () -> Void) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
            Text(text).fontWeight(.medium)
            Button(action: onClear) {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .font(.caption)
        .padding(.horizontal, MeetingTheme.s2)
        .padding(.vertical, 3)
        .background(MeetingTheme.chipFill, in: Capsule())
    }

    /// Filter-specific empty state (M3 minor 4): a filter that matches nothing must not show the
    /// generic "record your first meeting" prompt.
    private var filteredEmptyState: some View {
        MeetingEmptyStateCard(
            icon: "line.3.horizontal.decrease.circle",
            title: String(localized: "mainwindow.meetings.empty.filtered.title"),
            message: String(localized: "mainwindow.meetings.empty.filtered.message")
        ) {
            Button {
                coordinator.clearAllFilters()
            } label: {
                Text(String(localized: "mainwindow.meetings.filter.clear"))
            }
            .buttonStyle(.bordered)
        }
        .padding(.vertical, MeetingTheme.s4)
    }

    private var emptyState: some View {
        MeetingEmptyStateCard(
            icon: "person.2.wave.2",
            title: String(localized: "mainwindow.meetings.empty.title"),
            message: String(localized: "mainwindow.meetings.empty.message")
        ) {
            VStack(spacing: MeetingTheme.s2) {
                Button {
                    isPresentingImport = true
                } label: {
                    Text(String(localized: "mainwindow.newMeeting.import"))
                }
                .buttonStyle(.bordered)
                Button(String(localized: "home.next.startAdHoc")) {
                    let meeting = viewModel.createAdHocMeeting()
                    coordinator.openMeeting(id: meeting.id)
                }
                .buttonStyle(.link)
                .font(.caption)
            }
        }
        .padding(.vertical, MeetingTheme.s4)
    }

}

/// [Sprint 5] One archive row, sized to read: a mono date gutter, the normalized title (imported
/// export filenames read as the meetings they are), a second line naming the folder and tags,
/// state only when it needs saying, quiet imported/duplicate markers, and the open-action count.
/// The row paints its own card fill and selection tint (native table highlight is suppressed).
private struct ArchiveRow: View {
    let meeting: Meeting
    let isLive: Bool
    let isDuplicate: Bool
    let isSelected: Bool

    @ObservedObject private var viewModel = MeetingsViewModel.shared
    @ObservedObject private var homeViewModel = HomeFeedViewModel.shared
    // Observed so checking items off in a document updates the trailing count live.
    @ObservedObject private var checklistStore = MeetingChecklistStore.shared
    @State private var isHovering = false

    private var parsed: ImportedMeetingTitle.Parsed {
        ImportedMeetingTitle.parse(meeting.title)
    }

    private var isImported: Bool {
        meeting.source == .importedAudio || meeting.source == .importedTranscript || parsed.isImported
    }

    var body: some View {
        HStack(alignment: .top, spacing: MeetingTheme.s3) {
            Text(gutterText)
                .font(MeetingTheme.mono)
                .foregroundStyle(.secondary)
                .frame(width: 60, alignment: .leading)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: MeetingTheme.s2) {
                    if isLive {
                        Image(systemName: "record.circle.fill")
                            .foregroundStyle(.red)
                    }
                    Text(parsed.cleanTitle)
                        .font(.system(size: 14, weight: .medium))
                        .lineLimit(1)
                    if isImported {
                        Image(systemName: "square.and.arrow.down")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                            .help(String(localized: "meetings.row.imported"))
                    }
                    if isDuplicate {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                            .help(String(localized: "meetings.row.duplicate"))
                    }
                    stateWord
                    Spacer(minLength: 8)
                    trailingFacts
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .opacity(isHovering || isSelected ? 1 : 0)
                }
                organizationLine
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, MeetingTheme.s3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            isSelected
                ? Color.accentColor.opacity(0.16)
                : (isHovering ? Color.primary.opacity(0.06) : Color.primary.opacity(0.035)),
            in: RoundedRectangle(cornerRadius: MeetingTheme.rowRadius)
        )
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
    }

    /// Line 2: where the meeting lives (folder) and how it's labeled (tags) — plus attendees.
    @ViewBuilder
    private var organizationLine: some View {
        let folder = meeting.folderPath?.trimmingCharacters(in: .whitespaces)
        let tags = meeting.tags
        HStack(spacing: MeetingTheme.s2) {
            if let folder, !folder.isEmpty {
                Label(folder, systemImage: "folder")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                Label(String(localized: "mainwindow.folders.unfiled"), systemImage: "tray")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            if meeting.attendees.count > 1 {
                Label("\(meeting.attendees.count)", systemImage: "person.2")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(Array(tags.prefix(3)), id: \.self) { tag in
                Text("#\(tag)")
                    .font(.caption)
                    .lineLimit(1)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(MeetingTheme.chipFill, in: Capsule())
                    .foregroundStyle(.secondary)
            }
            if tags.count > 3 {
                Text("+\(tags.count - 3)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var gutterText: String {
        let date = MeetingsListView.effectiveDate(meeting)
        let sameYear = Calendar.current.isDate(date, equalTo: Date(), toGranularity: .year)
        return date.formatted(
            sameYear
                ? .dateTime.day(.twoDigits).month(.abbreviated)
                : .dateTime.day(.twoDigits).month(.abbreviated).year(.twoDigits)
        )
    }

    /// The state renders only when it needs saying: completed is the normal resting state.
    @ViewBuilder
    private var stateWord: some View {
        switch meeting.state {
        case .scheduled:
            Text(meeting.state.displayName)
                .font(.caption)
                .foregroundStyle(.secondary)
        case .interrupted, .processing:
            Text(meeting.state.displayName)
                .font(.caption)
                .foregroundStyle(.orange)
        case .failed:
            Text(meeting.state.displayName)
                .font(.caption)
                .foregroundStyle(.red)
        case .completed, .live:
            EmptyView()
        }
    }

    @ViewBuilder
    private var trailingFacts: some View {
        if meeting.state == .scheduled,
           viewModel.latestOutput(ofKind: .brief, for: meeting) != nil {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 11))
                .foregroundStyle(.green)
                .help(String(localized: "home.badge.briefReady"))
        }
        if meeting.state == .completed,
           let facts = homeViewModel.actionFacts(for: meeting),
           facts.totalCount > 0 {
            if facts.openCount > 0 {
                Text(String(format: String(localized: "home.recent.open"), facts.openCount))
                    .font(.caption)
                    .foregroundStyle(.tint)
            } else {
                Image(systemName: "checkmark.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(.green)
                    .help(String(localized: "home.recent.allDone"))
            }
        }
    }
}
