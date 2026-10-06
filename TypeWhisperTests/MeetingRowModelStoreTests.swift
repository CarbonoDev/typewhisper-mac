import XCTest
@testable import TypeWhisper

/// [Perf Phase 2] `MeetingRowModelStore` derives a row's stored facts once per `(id, updatedAt)` and
/// recomputes the volatile ones on every build.
@MainActor
final class MeetingRowModelStoreTests: XCTestCase {
    private func context(
        now: Date = Date(),
        facts: MeetingActionFacts? = nil,
        running: [MeetingJobKind]? = nil,
        duplicates: Set<UUID> = []
    ) -> MeetingRowModelStore.Context {
        MeetingRowModelStore.Context(
            now: now,
            actionFacts: { _ in facts },
            runningJobKinds: running.map { kinds in { _ in kinds } },
            duplicateIDs: duplicates
        )
    }

    func testStoredFactsMirrorTheMeeting() throws {
        let store = MeetingRowModelStore()
        let start = Date(timeIntervalSince1970: 1_780_000_000)
        let meeting = Meeting(
            title: "Weekly sync - 2026_07_07 16_29 CST - Notes by Gemini",
            state: .completed,
            source: .importedTranscript,
            startDate: start,
            obsidianFolder: "  Clients/Acme ",
            obsidianTagsJSON: #"["q3","acme"]"#
        )
        meeting.attendees = [Attendee(name: "A", email: "a@x.io"), Attendee(name: "B", email: "b@x.io")]

        let row = try XCTUnwrap(store.row(for: meeting, context: context()))
        XCTAssertEqual(row.title, "Weekly sync")
        XCTAssertEqual(row.startDate, start)
        XCTAssertEqual(row.effectiveDate, start)
        XCTAssertEqual(row.state, .completed)
        XCTAssertTrue(row.isImported)
        XCTAssertEqual(row.folder, "Clients/Acme")
        XCTAssertEqual(row.tags, ["q3", "acme"])
        XCTAssertEqual(row.attendeeCount, 2)
        XCTAssertFalse(row.hasTranscript)
        XCTAssertFalse(row.hasBrief)
    }

    func testUnfiledAndUndatedFallBack() throws {
        let store = MeetingRowModelStore()
        let created = Date(timeIntervalSince1970: 1_700_000_000)
        let meeting = Meeting(title: "Ad hoc", obsidianFolder: "   ", createdAt: created)
        let row = try XCTUnwrap(store.row(for: meeting, context: context()))
        XCTAssertNil(row.folder)
        XCTAssertNil(row.startDate)
        XCTAssertEqual(row.effectiveDate, created)
        XCTAssertFalse(row.isImported)
    }

    func testStoredFactsAreDerivedOncePerUpdatedAt() throws {
        let store = MeetingRowModelStore()
        let meeting = Meeting(title: "Standup", updatedAt: Date(timeIntervalSince1970: 1))
        _ = store.row(for: meeting, context: context())
        _ = store.row(for: meeting, context: context())
        XCTAssertEqual(store.derivationCount, 1)

        // What every `MeetingService` write does: change the row, bump `updatedAt`.
        meeting.title = "Renamed"
        meeting.updatedAt = Date(timeIntervalSince1970: 2)
        let row = try XCTUnwrap(store.row(for: meeting, context: context()))
        XCTAssertEqual(store.derivationCount, 2)
        XCTAssertEqual(row.title, "Renamed")
    }

    func testVolatileFactsAreRecomputedOnEveryBuild() throws {
        let store = MeetingRowModelStore()
        let meeting = Meeting(title: "Done", state: .completed)
        let open = MeetingActionFacts(openCount: 2, totalCount: 3)
        let done = MeetingActionFacts(openCount: 0, totalCount: 3)

        XCTAssertEqual(store.row(for: meeting, context: context(facts: open))?.actionFacts, open)
        XCTAssertEqual(store.row(for: meeting, context: context(facts: done))?.actionFacts, done)
        XCTAssertEqual(store.row(for: meeting, context: context(duplicates: [meeting.id]))?.isDuplicate, true)
        XCTAssertNil(store.row(for: meeting, context: context())?.workingBadge)
        XCTAssertNotNil(store.row(for: meeting, context: context(running: [.summary]))?.workingBadge)
        XCTAssertEqual(store.derivationCount, 1)
    }

    func testActionFactsOnlyForCompletedMeetings() {
        let store = MeetingRowModelStore()
        let meeting = Meeting(title: "Later", state: .scheduled)
        XCTAssertNil(
            store.row(for: meeting, context: context(facts: .init(openCount: 1, totalCount: 1)))?.actionFacts
        )
    }

    func testRunningLongAndTimelineBadges() throws {
        let store = MeetingRowModelStore()
        let now = Date()
        let overran = Meeting(title: "Live", state: .live, endDate: now.addingTimeInterval(-60))
        let onTime = Meeting(title: "Live", state: .live, endDate: now.addingTimeInterval(60))

        let row = try XCTUnwrap(store.row(for: overran, context: context(now: now)))
        XCTAssertTrue(row.isRunningLong)
        XCTAssertEqual(row.timelineBadges, [.runningLong])
        XCTAssertEqual(store.row(for: onTime, context: context(now: now))?.isRunningLong, false)
    }

    func testBriefReadyBadgeOnlyBeforeTheMeeting() throws {
        let directory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(directory) }
        let service = MeetingService(appSupportDirectory: directory)
        let store = MeetingRowModelStore()
        let meeting = service.createMeeting(title: "Kickoff", source: .adHoc)
        service.addOutput(to: meeting, kind: .brief, content: "brief")

        let scheduled = try XCTUnwrap(store.row(for: meeting, context: context()))
        XCTAssertTrue(scheduled.hasBrief)
        XCTAssertEqual(scheduled.state, .scheduled)
        XCTAssertEqual(scheduled.timelineBadges, [.briefReady])

        meeting.state = .completed
        service.update(meeting)
        XCTAssertEqual(store.row(for: meeting, context: context())?.timelineBadges, [])
    }

    func testDeletedMeetingsAreSkipped() throws {
        let directory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(directory) }
        let service = MeetingService(appSupportDirectory: directory)
        let store = MeetingRowModelStore()
        let kept = service.createMeeting(title: "Kept", source: .adHoc)
        let doomed = service.createMeeting(title: "Doomed", source: .adHoc)
        service.deleteMeeting(doomed)

        XCTAssertNotNil(store.row(for: kept, context: context()))
        XCTAssertNil(store.row(for: doomed, context: context()))
    }

    /// Fact columns are healed in place without an `updatedAt` bump; the row must follow the heal.
    func testAHealedFactColumnRebuildsTheRow() throws {
        let store = MeetingRowModelStore()
        let meeting = Meeting(title: "Drifted")
        meeting.outputs = [MeetingOutput(kind: .brief, content: "b")]
        meeting.storeOutputKinds([.summary])
        meeting.storeTranscriptFacts(MeetingTranscriptFacts(segmentCount: 2, transcriptEnd: 4, speakerLabels: []))

        let drifted = try XCTUnwrap(store.row(for: meeting, context: context()))
        XCTAssertFalse(drifted.hasBrief)
        XCTAssertTrue(drifted.hasTranscript)

        meeting.storeOutputKinds([.brief])
        meeting.storeTranscriptFacts(.empty)
        let healed = try XCTUnwrap(store.row(for: meeting, context: context()))
        XCTAssertTrue(healed.hasBrief)
        XCTAssertFalse(healed.hasTranscript)
        XCTAssertEqual(store.derivationCount, 2)
    }

    /// Rows are built per realized row (`MeetingRowCell`): a visible window of k rows over an archive
    /// of N derives k stored facts — each one the only place a row faults `segments` / `outputs`.
    func testAVisibleWindowDerivesOnlyItsRows() {
        let store = MeetingRowModelStore()
        let archive = (0..<40).map { Meeting(title: "Meeting \($0)") }
        let window = archive[10..<25]

        for meeting in window { _ = store.row(for: meeting, context: context()) }
        XCTAssertEqual(store.derivationCount, window.count)

        for meeting in window { _ = store.row(for: meeting, context: context()) }
        XCTAssertEqual(store.derivationCount, window.count, "scrolling back over cached rows derives nothing")
    }
}
