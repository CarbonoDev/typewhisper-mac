# MeetingsViewModel split — inventory and slice boundaries

Date: 2026-10-06. Parent plan: `2026-10-02-perf-refactor-plan.md` (§3 finding 1, §4 item 1,
Phase 2 "split `MeetingsViewModel` by feature slice").

This is a pure observation-topology change. Every write still goes through the same
single-writer services; behaviour is identical. Not converted to `@Observable` (separate
decision). Selection (already on `MeetingSelectionModel`), the 1 Hz clock (`CaptureClock`), the
calendar wake clock (`CalendarClock`) and related-emails fetch state (`RelatedEmailsModel`) were
split earlier and are not touched.

## Mechanism

- Each slice is a `@MainActor final class … : ObservableObject` in its own file, owning its
  `@Published` state and the sinks that feed it.
- `MeetingsViewModel` holds it as a `let` (`viewModel.capture`, `viewModel.calendar`, …) and
  forwards the old names as **computed, non-`@Published`** properties, so callers and tests that
  read `viewModel.isCapturing` keep compiling.
- A change on a slice fires only that slice's `objectWillChange`. A view that reads slice state —
  directly, or through a VM method derived from it (`documentPresentation(for:)`,
  `canStartCapture`, `showsImportMergeAction(for:)`) — must observe the slice. Views that read
  nothing else from the VM observe only the slice; the rest observe both.
- `$`-projections cannot be forwarded: the one Combine consumer of VM publishers
  (`MeetingTrayIndicator`) subscribes to the slice's publishers instead.

## Inventory (`@Published` on the VM at 4db4b02c)

Readers: view/test files that read the property directly (grep `\.<name>\b`), outside
`MeetingsViewModel.swift`. "Derived" lists VM members computed from it that views read.

| Property | Slice | Mirrors | Readers | Derived (read by views) |
|---|---|---|---|---|
| `activeMeeting` | Capture | `MeetingCaptureService.$activeMeeting` (identity-gated) | HomeLiveBanner, LiveRecordingBand, MainWindowView, MeetingBottomBar, MeetingsListView, MeetingTimeline, MeetingTranscriptPanel, MeetingTrayIndicator (`$`), MenuBarView; +Document; MirrorTests | `documentPresentation(for:)` (MeetingDocumentView), `showsImportMergeAction(for:)` (MeetingDocumentHeader) |
| `isCapturing` | Capture | `.$isCapturing` | HomeLiveBanner, LiveRecordingBand, MeetingsListView, MeetingTimeline, MeetingTranscriptPanel, MeetingTrayIndicator (`$`), MenuBarView; +Document; MirrorTests | `canStartCapture` (MeetingsListView, MeetingBottomBar), the two above |
| `isFinalizing` | Capture | `.$isFinalizing` | HomeLiveBanner, LiveRecordingBand, MeetingBottomBar; +Document; MirrorTests | `documentPresentation(for:)` |
| `isDegradedLiveMode` | Capture | `.$isDegradedLiveMode` | none (kept for parity) | — |
| `captureErrorMessage` | Capture | `.$errorMessage` + written by VM capture actions | MeetingDocumentHeader, MeetingsListView; MirrorTests | — |
| `finalRetranscriptionDegraded` | Capture | `.$finalRetranscriptionDegraded` | none (kept for parity) | — |
| `finalRetranscriptionDegradedMeetingID` | Capture | `.$finalRetranscriptionDegradedMeetingID` | MeetingDocumentHeader | — |
| `calendarAuthorizationStatus` | Calendar | `CalendarService.$authorizationStatus` | CalendarSelectionSection, UpcomingMeetingsSection; MirrorTests | `isCalendarAuthorized` (CalendarSelectionSection) |
| `hasAnyCalendarSource` | Calendar | derived: auth status + `GoogleAccountStore.$accounts` (hop) | ComingUpCard, MeetingLinkEventView, UpcomingMeetingsSection | — |
| `showsSystemCalendarProblem` | Calendar | derived, same inputs + session dismissal | ComingUpCard | — |
| `calendarSelectionRevision` | Calendar | bumped by selection writes | CalendarSelectionSection | — |
| `twinCalendarPrompts` | Calendar | derived: accounts, auth, `availableCalendars()` | GoogleAccountsSection | — |
| `upcomingEvents` | Calendar | `CalendarService.$upcomingEvents` | ComingUpCard, MeetingTrayIndicator (`$`), MenuBarView, UpcomingMeetingsSection; MirrorTests | — |
| `earlierEvents` | Calendar | `.$earlierEvents` | UpcomingMeetingsSection | — |
| `calendarErrorMessage` | Calendar | `.$errorMessage` | ComingUpCard, UpcomingMeetingsSection | — |
| `meetings` | Library | `MeetingService.meetingsListPublisher` | HomeFeedView, MainWindowView, MeetingActivityPopover, MeetingFolderDetailView, MeetingRowActions, MeetingRowContextMenu, MeetingsListView, MeetingsSettingsView, MeetingTimeline, SpaceNoteView; +AutoBrief, +CalendarRefresh, +Document, +Home, +Organization, +RelatedDocs, +RelatedEmails, +Rules; PerfBenchmarkTests | `hasMeetings` (MeetingsSettingsView) |
| `templates` | Outputs | `PromptActionService.$meetingActions` (unconditional: identity rows) | MeetingBottomBar, MeetingBriefView, MeetingContextRuleEditorView, MeetingTemplateEditorView; +Rules | `defaultTemplate(ofKind:for:)` |
| `answeringMeetingIDs` | Outputs | `MeetingLLMService.$answeringMeetingIDs` | none directly | `isAnswering(for:)` (MeetingQAView, MeetingBottomBar) |
| `outputErrorMessage`, `outputErrorNeedsProvider` | Outputs | VM-written | MeetingDocumentBody | — |
| `briefErrorMessage`, `briefErrorNeedsProvider` | Outputs | VM-written | MeetingBriefView | — |
| `qaErrorMessage`, `qaErrorNeedsProvider` | Outputs | VM-written | MeetingQAView | — |
| `exportErrorMessage` | Outputs | VM-written | MeetingExportView | — |
| `importErrorMessage` | Outputs | VM-written | MeetingImportView | — |
| `diarizationErrorMessage`, `diarizationStatusMessage`, `diarizationStatusOutcome` | Outputs | VM-written | SpeakerSection | — |
| `isVaultConnected`, `vaultName` | Vault | `ObsidianVaultService.$vaultPath` (hop) | MeetingBriefView, MeetingDocumentBody, MeetingExportView, MeetingFolderDetailView, MeetingRelatedDocsSection, MeetingsSettingsView, SpaceFolderView | — |
| `isGmailConnected` | Related emails | `GoogleAccountStore.objectWillChange` (hop) | MeetingDocumentBody, MeetingRelatedEmailsSection; +RelatedEmails | — |
| `pendingFocusMeetingID` | Glue (navigation request) | VM-written | MainWindowView | — |

Observer sites (`@ObservedObject … = MeetingsViewModel.shared`): 46 across 34 files (counted at
4db4b02c), plus `MeetingTrayIndicator`'s Combine subscriptions and `let` holders that observe
nothing (MainWindowSidebar, VaultContextPickerView, MeetingContextRulesView, MeetingRowActions,
MeetingRowContextMenu).

## Slice boundaries, decided from the reads

The plan's guess was Capture, Calendar, Library/Organization, Outputs, Vault/Export, Import,
Related. The reads collapse it:

1. **Capture** — the seven capture mirrors. Highest churn (start, stop, finalize, error,
   identity swap of `activeMeeting` on refetch) and read by the live surfaces that otherwise need
   little: LiveRecordingBand, HomeLiveBanner and MeetingTranscriptPanel read nothing else.
2. **Calendar** — the eight calendar mirrors and derived flags, plus the twin-prompt and
   source-availability logic and the `$accounts` hop that feeds them. Churns on every EventKit /
   Google snapshot change; its readers (calendar sections, ComingUpCard, settings) read little
   else.
3. **Library** — `meetings` alone. Membership/sort-key changes. Read by the list surfaces and
   heavily by the extensions (through the forward).
4. **Outputs** — templates, the Q&A in-flight set and the per-operation error/status messages.
   One per operation each; their readers are document leaves that each read one pair.
   Import is a single message read by one sheet and Export likewise: not worth their own slice.
5. **Vault**, **Gmail flag**, **pending focus** — change only on connect/disconnect or a menu
   action. Left on the VM (glue): splitting them buys nothing measurable.

Order of landing: Capture, Calendar, then Library and Outputs if the remaining VM still carries
churn worth removing.

## Load-bearing Combine hops (`MeetingsViewModel.init` at 4db4b02c)

1. Google account store `objectWillChange` → `isGmailConnected` (stays on the VM).
2. `$upcomingEvents` consumers (`calendarUpcomingDidChange`, writes other stores) — stays on the
   VM (it is orchestration, not slice state); the `$accounts` hop that feeds
   `hasAnyCalendarSource` / twin prompts moves to the Calendar slice, still hopped.
3. `$vaultPath` → `isVaultConnected` / `vaultName` (stays on the VM).
