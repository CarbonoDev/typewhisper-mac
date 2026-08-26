import XCTest
@testable import TypeWhisper

/// Meeting merge tests: the pure `MeetingMergePlanner` rules (primary selection, title precedence,
/// time range, segment re-anchoring, conflict detection) plus integration through a real
/// `MeetingService` on a temp directory (`applyMerge` and the `MeetingMergeService` orchestration
/// with a fake conflict resolver — the LLM never runs in CI).
@MainActor
final class MeetingMergeTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_700_000_000)

    private func date(_ offset: TimeInterval) -> Date { base.addingTimeInterval(offset) }

    private func snap(
        id: UUID = UUID(),
        title: String = "Untitled",
        generated: Bool = true,
        state: MeetingState = .completed,
        start: TimeInterval? = nil,
        end: TimeInterval? = nil,
        calendarEventID: String? = nil,
        seriesID: String? = nil,
        calendarNotes: String? = nil,
        conferencingURL: String? = nil,
        externalSessionKey: String? = nil,
        folderPath: String? = nil,
        languageCode: String? = nil,
        languageProvenance: MeetingLanguageProvenance? = nil,
        createdAt: TimeInterval = 0,
        segments: [MeetingMergeSegmentSnapshot] = []
    ) -> MeetingMergeSnapshot {
        MeetingMergeSnapshot(
            id: id,
            title: title,
            titleIsGenerated: generated,
            state: state,
            startDate: start.map(date),
            endDate: end.map(date),
            calendarEventID: calendarEventID,
            seriesID: seriesID,
            calendarNotes: calendarNotes,
            conferencingURL: conferencingURL,
            externalSessionKey: externalSessionKey,
            folderPath: folderPath,
            languageCode: languageCode,
            languageProvenance: languageProvenance,
            createdAt: date(createdAt),
            segments: segments
        )
    }

    private func seg(_ start: Double, _ end: Double, source: MeetingSegmentSource = .liveCapture) -> MeetingMergeSegmentSnapshot {
        MeetingMergeSegmentSnapshot(start: start, end: end, source: source)
    }

    // MARK: - Eligibility

    func testPlanRequiresAtLeastTwoMeetings() {
        XCTAssertNil(MeetingMergePlanner.plan([]))
        XCTAssertNil(MeetingMergePlanner.plan([snap()]))
        XCTAssertNotNil(MeetingMergePlanner.plan([snap(), snap()]))
    }

    func testLiveOrProcessingMeetingsAreNotMergeable() {
        XCTAssertTrue(MeetingMergePlanner.isMergeable([.completed, .interrupted]))
        XCTAssertFalse(MeetingMergePlanner.isMergeable([.completed, .live]))
        XCTAssertFalse(MeetingMergePlanner.isMergeable([.processing, .completed]))
        XCTAssertFalse(MeetingMergePlanner.isMergeable([.completed]))
    }

    // MARK: - Primary selection ladder

    func testCalendarLinkedMeetingWinsPrimaryEvenWhenLater() {
        let linked = snap(start: 600, calendarEventID: "ev-1")
        let earlier = snap(start: 0, segments: [seg(0, 100)])
        let plan = MeetingMergePlanner.plan([earlier, linked])!
        XCTAssertEqual(plan.primaryID, linked.id)
        XCTAssertEqual(plan.absorbedIDs, [earlier.id])
    }

    func testEmptyCalendarEventIDDoesNotCountAsLink() {
        let blankLink = snap(start: 600, calendarEventID: "  ")
        let earlier = snap(start: 0)
        let plan = MeetingMergePlanner.plan([blankLink, earlier])!
        XCTAssertEqual(plan.primaryID, earlier.id)
    }

    func testEarliestStartDateWinsWithoutCalendarLink() {
        let early = snap(start: 0)
        let late = snap(start: 3600, segments: [seg(0, 10), seg(10, 20)])
        XCTAssertEqual(MeetingMergePlanner.plan([late, early])!.primaryID, early.id)
    }

    func testDatedMeetingBeatsUndated() {
        let dated = snap(start: 0)
        let undated = snap(segments: [seg(0, 10)])
        XCTAssertEqual(MeetingMergePlanner.plan([undated, dated])!.primaryID, dated.id)
    }

    func testMostSegmentsWinsWithoutDates() {
        let rich = snap(segments: [seg(0, 10), seg(10, 20)])
        let sparse = snap(segments: [seg(0, 10)])
        XCTAssertEqual(MeetingMergePlanner.plan([sparse, rich])!.primaryID, rich.id)
    }

    func testPlanIsDeterministicForAnyInputOrder() {
        let a = snap(createdAt: 0)
        let b = snap(createdAt: 100)
        let forward = MeetingMergePlanner.plan([a, b])!
        let backward = MeetingMergePlanner.plan([b, a])!
        XCTAssertEqual(forward, backward)
        XCTAssertEqual(forward.primaryID, a.id) // earliest createdAt wins the tie-break
    }

    // MARK: - Title precedence

    func testHumanTitleBeatsGeneratedEvenOnAbsorbedMeeting() {
        let primary = snap(title: "New Meeting", generated: true, calendarEventID: "ev-1")
        let absorbed = snap(title: "Quarterly Review", generated: false)
        let plan = MeetingMergePlanner.plan([primary, absorbed])!
        XCTAssertEqual(plan.primaryID, primary.id)
        XCTAssertEqual(plan.title, "Quarterly Review")
        XCTAssertFalse(plan.hasTitleConflict)
        XCTAssertTrue(plan.conflicts.isEmpty)
    }

    func testAllGeneratedTitlesKeepPrimaryTitleWithoutConflict() {
        let primary = snap(title: "New Meeting", generated: true, start: 0)
        let absorbed = snap(title: "Imported Meeting", generated: true, start: 60)
        let plan = MeetingMergePlanner.plan([primary, absorbed])!
        XCTAssertEqual(plan.title, "New Meeting")
        XCTAssertTrue(plan.titleCandidates.isEmpty)
        XCTAssertFalse(plan.hasTitleConflict)
    }

    func testDistinctHumanTitlesAreAConflictWithDeterministicFallback() {
        let primary = snap(title: "Kickoff", generated: false, start: 0)
        let absorbed = snap(title: "Project Kickoff Call", generated: false, start: 60)
        let plan = MeetingMergePlanner.plan([primary, absorbed])!
        XCTAssertTrue(plan.hasTitleConflict)
        XCTAssertEqual(plan.titleCandidates, ["Kickoff", "Project Kickoff Call"])
        XCTAssertEqual(plan.title, "Kickoff") // deterministic fallback: highest-priority candidate
        XCTAssertTrue(plan.conflicts.contains(.title(candidates: ["Kickoff", "Project Kickoff Call"])))
    }

    func testSameHumanTitleModuloCaseAndWhitespaceIsNoConflict() {
        let primary = snap(title: "Weekly Sync", generated: false, start: 0)
        let absorbed = snap(title: "  weekly sync ", generated: false, start: 60)
        let plan = MeetingMergePlanner.plan([primary, absorbed])!
        XCTAssertFalse(plan.hasTitleConflict)
        XCTAssertEqual(plan.title, "Weekly Sync")
    }

    // MARK: - Time range and scalar adoption

    func testTimeRangeIsMinStartMaxEnd() {
        let a = snap(start: 600, end: 1800, calendarEventID: "ev-1")
        let b = snap(start: 0, end: 1200)
        let plan = MeetingMergePlanner.plan([a, b])!
        XCTAssertEqual(plan.startDate, date(0))
        XCTAssertEqual(plan.endDate, date(1800))
    }

    func testFirstNonNilScalarsFollowPriorityOrder() {
        let primary = snap(start: 0, calendarEventID: "ev-1", seriesID: nil, folderPath: nil)
        let absorbed = snap(
            start: 60,
            seriesID: "series-9",
            externalSessionKey: "abc-defg-hij",
            folderPath: "Clients/Acme"
        )
        let plan = MeetingMergePlanner.plan([primary, absorbed])!
        XCTAssertEqual(plan.calendarEventID, "ev-1")
        XCTAssertEqual(plan.seriesID, "series-9")
        XCTAssertEqual(plan.externalSessionKey, "abc-defg-hij")
        XCTAssertEqual(plan.folderPath, "Clients/Acme")
    }

    // MARK: - Event snapshot travels with the linkage (PR #7 review finding 9)

    func testEventSnapshotComesFromTheMeetingThatSuppliedTheCalendarLink() {
        let primary = snap(
            start: 0,
            calendarEventID: "ev-1",
            calendarNotes: "Agenda A",
            conferencingURL: "https://meet.google.com/aaa"
        )
        let absorbed = snap(
            start: 60,
            calendarNotes: "Agenda B",
            conferencingURL: "https://meet.google.com/bbb"
        )
        let plan = MeetingMergePlanner.plan([primary, absorbed])!
        XCTAssertEqual(plan.calendarEventID, "ev-1")
        XCTAssertEqual(plan.calendarNotes, "Agenda A", "never pair one event's link with another's agenda")
        XCTAssertEqual(plan.conferencingURL, "https://meet.google.com/aaa")
    }

    func testLinkedMeetingWithoutASnapshotDoesNotAdoptAStrayOne() {
        let primary = snap(start: 0, calendarEventID: "ev-1")
        let absorbed = snap(start: 60, calendarNotes: "Agenda B", conferencingURL: "https://meet.google.com/bbb")
        let plan = MeetingMergePlanner.plan([primary, absorbed])!
        XCTAssertNil(plan.calendarNotes, "the linked event carries no notes — a stray Join button is worse")
        XCTAssertNil(plan.conferencingURL)
    }

    func testWithoutAnyCalendarLinkTheSnapshotFallsBackToPriorityOrder() {
        let primary = snap(start: 0)
        let absorbed = snap(start: 60, calendarNotes: "Agenda B", conferencingURL: "https://meet.google.com/bbb")
        let plan = MeetingMergePlanner.plan([primary, absorbed])!
        XCTAssertEqual(plan.calendarNotes, "Agenda B", "an orphaned snapshot is not silently dropped either")
        XCTAssertEqual(plan.conferencingURL, "https://meet.google.com/bbb")
    }

    func testStrongerLanguageProvenanceWinsOverPrimary() {
        let primary = snap(start: 0, calendarEventID: "ev-1", languageCode: "en", languageProvenance: .detected)
        let absorbed = snap(start: 60, languageCode: "de", languageProvenance: .manual)
        let plan = MeetingMergePlanner.plan([primary, absorbed])!
        XCTAssertEqual(plan.languageCode, "de")
        XCTAssertEqual(plan.languageProvenance, .manual)
    }

    func testMostCompleteStateWins() {
        let scheduledTwin = snap(state: .scheduled, calendarEventID: "ev-1")
        let completedCapture = snap(state: .completed, segments: [seg(0, 10)])
        let plan = MeetingMergePlanner.plan([scheduledTwin, completedCapture])!
        XCTAssertEqual(plan.primaryID, scheduledTwin.id)
        XCTAssertEqual(plan.state, .completed)
    }

    // MARK: - Segment re-anchoring

    func testDatedMeetingsAreAnchoredByWallClockDelta() {
        let a = snap(start: 0, segments: [seg(0, 300)])
        let b = snap(start: 600, segments: [seg(0, 120)])
        let plan = MeetingMergePlanner.plan([a, b])!
        XCTAssertEqual(plan.segmentOffsets[a.id], 0)
        XCTAssertEqual(plan.segmentOffsets[b.id], 600)
    }

    func testPrimaryItselfIsReanchoredWhenNotEarliest() {
        let linkedLater = snap(start: 900, calendarEventID: "ev-1", segments: [seg(0, 60)])
        let earlierImport = snap(start: 0, segments: [seg(0, 100)])
        let plan = MeetingMergePlanner.plan([linkedLater, earlierImport])!
        XCTAssertEqual(plan.primaryID, linkedLater.id)
        XCTAssertEqual(plan.segmentOffsets[linkedLater.id], 900)
        XCTAssertEqual(plan.segmentOffsets[earlierImport.id], 0)
    }

    func testUndatedMeetingIsAppendedAfterDatedContent() {
        let dated = snap(start: 0, segments: [seg(0, 300)])
        let undated = snap(segments: [seg(0, 50)])
        let plan = MeetingMergePlanner.plan([dated, undated])!
        XCTAssertEqual(plan.segmentOffsets[dated.id], 0)
        XCTAssertEqual(plan.segmentOffsets[undated.id], 300) // after the dated timeline's max end
    }

    func testTwoUndatedMeetingsAreAppendedSequentially() {
        let first = snap(createdAt: 0, segments: [seg(0, 100)])
        let second = snap(createdAt: 50, segments: [seg(0, 40)])
        let plan = MeetingMergePlanner.plan([second, first])!
        XCTAssertEqual(plan.primaryID, first.id)
        XCTAssertEqual(plan.segmentOffsets[first.id], 0)
        XCTAssertEqual(plan.segmentOffsets[second.id], 100)
    }

    // MARK: - Overlap conflict detection

    func testOverlappingSameSourceTranscriptsAreFlagged() {
        // Both dated, both .liveCapture, spans 0–300 and 120–420 → overlap after re-anchoring.
        let a = snap(start: 0, segments: [seg(0, 300)])
        let b = snap(start: 120, segments: [seg(0, 300)])
        let plan = MeetingMergePlanner.plan([a, b])!
        XCTAssertTrue(plan.conflicts.contains(.overlappingTranscripts(.liveCapture)))
    }

    func testDisjointSameSourceTranscriptsAreNoConflict() {
        let a = snap(start: 0, segments: [seg(0, 300)])
        let b = snap(start: 600, segments: [seg(0, 120)])
        let plan = MeetingMergePlanner.plan([a, b])!
        XCTAssertTrue(plan.conflicts.isEmpty)
    }

    func testOverlappingDifferentSourcesAreNoConflict() {
        // Captions + own capture over the same minutes is the designed coexistence, not a conflict.
        let a = snap(start: 0, segments: [seg(0, 300, source: .liveCapture)])
        let b = snap(start: 60, segments: [seg(0, 300, source: .liveCaptions)])
        let plan = MeetingMergePlanner.plan([a, b])!
        XCTAssertTrue(plan.conflicts.isEmpty)
    }

    // MARK: - Integration through a real MeetingService

    func testApplyMergeCombinesAggregatesAndDeletesAbsorbed() async throws {
        let dir = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(dir) }
        let service = MeetingService(appSupportDirectory: dir)

        let primary = service.createMeeting(
            title: "Weekly Sync",
            source: .calendar,
            state: .scheduled,
            startDate: date(0),
            endDate: date(1800),
            calendarEventID: "ev-1",
            seriesID: "series-A",
            attendees: [Attendee(name: "Marco", email: "marco@example.com")]
        )
        service.appendStableSegments(
            [TranscriptionSegment(text: "Agenda first.", start: 0, end: 5)],
            to: primary
        )
        service.addOutput(to: primary, kind: .summary, content: "Old summary.")

        let duplicate = service.createMeeting(
            title: String(localized: "meetings.adHoc.defaultTitle"), // generated → never wins
            source: .adHoc,
            state: .completed,
            startDate: date(600),
            attendees: [
                Attendee(name: "Marco", email: "marco@example.com"),
                Attendee(name: "Alex", email: "alex@example.com")
            ]
        )
        service.appendStableSegments(
            [TranscriptionSegment(text: "Re-joined the call.", start: 0, end: 5)],
            to: duplicate
        )
        service.addNote(to: duplicate, text: "Ship it.", timestampOffset: 2)
        service.addOutput(to: duplicate, kind: .summary, content: "New summary.")
        service.addQATurn(to: duplicate, question: "When?", answer: "Friday.")

        let mergeService = MeetingMergeService(meetingService: service)
        let merged = await mergeService.merge([primary, duplicate])

        XCTAssertEqual(merged?.id, primary.id)
        XCTAssertEqual(service.meetings.count, 1)
        let survivor = try XCTUnwrap(service.meetings.first)
        XCTAssertEqual(survivor.id, primary.id)

        // Scalars: human title kept, min–max range, calendar identity intact, completed state wins.
        XCTAssertEqual(survivor.title, "Weekly Sync")
        XCTAssertEqual(survivor.startDate, date(0))
        XCTAssertEqual(survivor.endDate, date(1800))
        XCTAssertEqual(survivor.calendarEventID, "ev-1")
        XCTAssertEqual(survivor.seriesID, "series-A")
        XCTAssertEqual(survivor.state, .completed)

        // Attendees: union, deduped by identity.
        XCTAssertEqual(
            Set(survivor.attendees.compactMap(\.email)),
            ["marco@example.com", "alex@example.com"]
        )

        // Segments: union, duplicate's timeline re-anchored +600s, renumbered chronologically.
        let segments = survivor.segments.sorted { $0.order < $1.order }
        XCTAssertEqual(segments.map(\.text), ["Agenda first.", "Re-joined the call."])
        XCTAssertEqual(segments.map(\.order), [0, 1])
        XCTAssertEqual(segments[1].start, 600)
        XCTAssertEqual(segments[1].end, 605)

        // Notes: carried with the re-anchored offset, plus the provenance note.
        let provenanceText = String(format: String(localized: "meetings.merge.provenanceNote"), 2)
        XCTAssertEqual(survivor.notes.count, 2)
        let carriedNote = try XCTUnwrap(survivor.notes.first { $0.text == "Ship it." })
        XCTAssertEqual(carriedNote.timestampOffset, 602)
        XCTAssertTrue(survivor.notes.contains { $0.text == provenanceText })

        // Outputs: both kept; the newest is what latestOutput surfaces.
        XCTAssertEqual(survivor.outputs.count, 2)
        XCTAssertEqual(service.latestOutput(ofKind: .summary, for: survivor)?.content, "New summary.")

        // Q&A turns carried over.
        XCTAssertEqual(survivor.qaTurns.map(\.question), ["When?"])
    }

    func testMergePersistsAcrossServiceReopen() async throws {
        let dir = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(dir) }
        let mergedID: UUID
        do {
            let service = MeetingService(appSupportDirectory: dir)
            let a = service.createMeeting(title: "Sync", state: .completed, startDate: date(0))
            service.appendStableSegments([TranscriptionSegment(text: "One.", start: 0, end: 2)], to: a)
            let b = service.createMeeting(title: "Sync", state: .completed, startDate: date(300))
            service.appendStableSegments([TranscriptionSegment(text: "Two.", start: 0, end: 2)], to: b)
            let merged = await MeetingMergeService(meetingService: service).merge([a, b])
            mergedID = try XCTUnwrap(merged?.id)
        }
        let reopened = MeetingService(appSupportDirectory: dir)
        XCTAssertEqual(reopened.meetings.count, 1)
        let survivor = try XCTUnwrap(reopened.meetings.first)
        XCTAssertEqual(survivor.id, mergedID)
        XCTAssertEqual(survivor.segments.count, 2)
        XCTAssertEqual(
            survivor.segments.sorted { $0.order < $1.order }.map(\.text),
            ["One.", "Two."]
        )
    }

    func testApplyMergeCarriesTheEventSnapshotOntoTheSurvivor() async throws {
        // PR #7 review finding 9: `applyMerge` never wrote `calendarNotes`/`conferencingURL`, so a
        // snapshot living on the absorbed meeting was lost with the deleted row.
        let dir = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(dir) }
        let service = MeetingService(appSupportDirectory: dir)

        let primary = service.createMeeting(title: "Live capture", state: .completed, startDate: date(0))
        let duplicate = service.createMeeting(
            title: String(localized: "meetings.adHoc.defaultTitle"),
            state: .completed,
            startDate: date(600),
            calendarNotes: "Agenda: budget",
            conferencingURL: "https://meet.google.com/abc-defg-hij"
        )

        let merged = await MeetingMergeService(meetingService: service).merge([primary, duplicate])
        let survivor = try XCTUnwrap(merged)

        XCTAssertEqual(survivor.id, primary.id)
        XCTAssertEqual(survivor.calendarNotes, "Agenda: budget")
        XCTAssertEqual(survivor.conferencingURL, "https://meet.google.com/abc-defg-hij")
    }

    func testApplyMergeKeepsTheLinkedPrimarysOwnSnapshot() async throws {
        let dir = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(dir) }
        let service = MeetingService(appSupportDirectory: dir)

        let linked = service.createMeeting(
            title: "Weekly Sync",
            source: .calendar,
            state: .completed,
            startDate: date(0),
            calendarEventID: "ev-1",
            calendarNotes: "Agenda A",
            conferencingURL: "https://meet.google.com/aaa"
        )
        let duplicate = service.createMeeting(
            title: String(localized: "meetings.adHoc.defaultTitle"),
            state: .completed,
            startDate: date(600),
            calendarNotes: "Agenda B",
            conferencingURL: "https://meet.google.com/bbb"
        )

        let merged = await MeetingMergeService(meetingService: service).merge([linked, duplicate])
        let survivor = try XCTUnwrap(merged)

        XCTAssertEqual(survivor.calendarEventID, "ev-1")
        XCTAssertEqual(survivor.calendarNotes, "Agenda A", "the snapshot stays paired with its own event")
        XCTAssertEqual(survivor.conferencingURL, "https://meet.google.com/aaa")
    }

    func testMergeUsesResolverForTitleConflictOnly() async throws {
        let dir = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(dir) }
        let service = MeetingService(appSupportDirectory: dir)

        let a = service.createMeeting(title: "Kickoff", state: .completed, startDate: date(0))
        let b = service.createMeeting(title: "Project Kickoff Call", state: .completed, startDate: date(60))

        let resolver = FakeMergeConflictResolver(result: "Acme Kickoff")
        let merged = await MeetingMergeService(meetingService: service, conflictResolver: resolver)
            .merge([a, b])

        XCTAssertEqual(resolver.receivedCandidates, ["Kickoff", "Project Kickoff Call"])
        XCTAssertEqual(merged?.title, "Acme Kickoff")
    }

    func testMergeKeepsDeterministicTitleWhenResolverDeclines() async throws {
        let dir = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(dir) }
        let service = MeetingService(appSupportDirectory: dir)

        let a = service.createMeeting(title: "Kickoff", state: .completed, startDate: date(0))
        let b = service.createMeeting(title: "Project Kickoff Call", state: .completed, startDate: date(60))

        let resolver = FakeMergeConflictResolver(result: nil)
        let merged = await MeetingMergeService(meetingService: service, conflictResolver: resolver)
            .merge([a, b])

        XCTAssertEqual(resolver.receivedCandidates, ["Kickoff", "Project Kickoff Call"])
        XCTAssertEqual(merged?.title, "Kickoff")
    }

    func testResolverIsNotConsultedWithoutConflict() async throws {
        let dir = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(dir) }
        let service = MeetingService(appSupportDirectory: dir)

        let a = service.createMeeting(title: "Kickoff", state: .completed, startDate: date(0))
        let b = service.createMeeting(
            title: String(localized: "meetings.adHoc.defaultTitle"),
            state: .completed,
            startDate: date(60)
        )

        let resolver = FakeMergeConflictResolver(result: "Never Used")
        let merged = await MeetingMergeService(meetingService: service, conflictResolver: resolver)
            .merge([a, b])

        XCTAssertNil(resolver.receivedCandidates)
        XCTAssertEqual(merged?.title, "Kickoff")
    }

    // MARK: - `willAbsorb` pre-apply seam (review findings: single-plan design, job-queue leaks)

    /// The seam's core guarantee: `willAbsorb` fires exactly once, with the *one* plan that is about
    /// to be applied, before `applyMerge` deletes the absorbed row — so a job holding a strong
    /// reference to that `Meeting` (exactly how `generateOutput`'s job closure captures its target)
    /// can be cancelled and awaited (`cancelAllAndWait`) from inside the callback with no window for
    /// it to resume against a deleted model afterward.
    func testWillAbsorbSeamCancelsAbsorbedJobBeforeApplyDeletesTheRow() async throws {
        let dir = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(dir) }
        let service = MeetingService(appSupportDirectory: dir)
        let queue = JobQueueService()

        let primary = service.createMeeting(title: "Weekly Sync", state: .completed, startDate: date(0))
        let duplicate = service.createMeeting(title: "Re-join", state: .completed, startDate: date(600))
        let meetings = [primary, duplicate]

        // A job "in flight" for the meeting about to be absorbed, closing over the live `Meeting` row
        // exactly like `MeetingsViewModel.generateOutput`'s enqueue does. Reference type because a
        // `@Sendable` job operation cannot capture a mutable local var (same reasoning as this file's
        // `Recorder`).
        let ranFlag = RanFlag()
        queue.enqueue(kind: .summary, meetingID: duplicate.id) {
            ranFlag.mark()
            _ = duplicate.title // would trap post-merge if this ever actually ran
        }

        var receivedAbsorbedIDs: [UUID]?
        let merged = await MeetingMergeService(meetingService: service).merge(meetings) { absorbedIDs in
            receivedAbsorbedIDs = absorbedIDs
            for id in absorbedIDs {
                await queue.cancelAllAndWait(for: id)
            }
        }

        XCTAssertEqual(receivedAbsorbedIDs, [duplicate.id]) // earlier start ⇒ primary; duplicate absorbed
        XCTAssertEqual(merged?.id, primary.id)
        XCTAssertFalse(ranFlag.ran, "a cancelled job must never touch the absorbed meeting")
        XCTAssertEqual(service.meetings.count, 1)
    }

    /// The other half of the single-plan design (review finding): when the merge itself refuses
    /// (`canMerge` false on the actual pre-flight — e.g. a meeting flipped `.live` between the
    /// caller's decision to merge and this call), `willAbsorb` must never fire. A caller wiring
    /// cancellation/navigation through this seam therefore can never produce a side effect for a
    /// merge that didn't happen — the exact bug the old "plan locally, then call merge separately"
    /// shape had (cancel/navigate already run by the time a since-refused `merge` returned `nil`).
    func testMergeAbortsWithoutInvokingWillAbsorbWhenNotMergeable() async throws {
        let dir = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(dir) }
        let service = MeetingService(appSupportDirectory: dir)

        let a = service.createMeeting(title: "Weekly Sync", state: .completed, startDate: date(0))
        // Simulates "state flipped between the caller's decision and the actual merge call" — e.g. a
        // capture resumed on this meeting in the main-actor window before `merge` runs.
        let b = service.createMeeting(title: "Re-join", state: .live, startDate: date(600))

        let calledFlag = RanFlag()
        let merged = await MeetingMergeService(meetingService: service).merge([a, b]) { _ in
            calledFlag.mark()
        }

        XCTAssertNil(merged)
        XCTAssertFalse(calledFlag.ran, "willAbsorb must not fire when the merge itself is refused")
        XCTAssertEqual(service.meetings.count, 2, "neither meeting is touched when the merge aborts")
    }

    func testMergeRefusesLiveMeeting() async throws {
        let dir = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(dir) }
        let service = MeetingService(appSupportDirectory: dir)

        let live = service.createMeeting(title: "In progress", state: .live)
        let done = service.createMeeting(title: "Done", state: .completed)

        XCTAssertFalse(MeetingMergeService.canMerge([live, done]))
        let merged = await MeetingMergeService(meetingService: service).merge([live, done])
        XCTAssertNil(merged)
        XCTAssertEqual(service.meetings.count, 2)
    }
}

/// Reference-type flag a `@Sendable` job operation can mutate (a `var` capture is not allowed).
@MainActor
private final class RanFlag {
    private(set) var ran = false
    func mark() { ran = true }
}

/// Fake LLM seam: records the candidates it was asked to resolve and returns a canned answer.
@MainActor
private final class FakeMergeConflictResolver: MeetingMergeConflictResolving {
    private(set) var receivedCandidates: [String]?
    private let result: String?

    init(result: String?) {
        self.result = result
    }

    func resolveMergedTitle(candidates: [String]) async -> String? {
        receivedCandidates = candidates
        return result
    }
}
