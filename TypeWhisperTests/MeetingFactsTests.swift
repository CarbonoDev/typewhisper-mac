import XCTest
import SwiftData
@testable import TypeWhisper

/// Perf plan Phase 2: the denormalised fact columns on `Meeting` match the relationships after
/// every kind of write, a missing or stale column never under-reports, and the reconcile pass
/// backfills old rows and heals drift (the relationship always wins).
@MainActor
final class MeetingFactsTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = try TestSupport.makeTemporaryDirectory()
    }

    override func tearDown() {
        TestSupport.remove(dir)
        super.tearDown()
    }

    private func segment(_ text: String, _ start: Double, end: Double? = nil, speaker: String? = nil) -> TranscriptionSegment {
        TranscriptionSegment(text: text, start: start, end: end ?? start + 1, speakerLabel: speaker)
    }

    /// The stored columns are set and equal to what the relationships say.
    private func assertFactsMatch(_ meeting: Meeting, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(meeting.hasStoredFacts, "columns unset", file: file, line: line)
        XCTAssertEqual(meeting.storedTranscriptFacts, meeting.computedTranscriptFacts(), file: file, line: line)
        XCTAssertEqual(meeting.storedOutputKinds, meeting.computedOutputKinds(), file: file, line: line)
    }

    private func clearFacts(_ meeting: Meeting) {
        meeting.factSegmentCount = nil
        meeting.factTranscriptEnd = nil
        meeting.factSpeakerLabelsRaw = nil
        meeting.factOutputKindsRaw = nil
    }

    // MARK: - Maintenance at every write

    func testNewMeetingStartsWithEmptyComputedFacts() {
        let service = MeetingService(appSupportDirectory: dir)
        let meeting = service.createMeeting(title: "New")
        assertFactsMatch(meeting)
        XCTAssertFalse(meeting.hasTranscript)
        XCTAssertEqual(meeting.outputKinds, [])
    }

    func testLiveAppendKeepsFactsIncrementally() {
        let service = MeetingService(appSupportDirectory: dir)
        let meeting = service.createMeeting(title: "Live", state: .live)
        service.appendStableSegments([segment("a", 0, end: 2, speaker: "SPEAKER_00")], source: .liveCaptions, to: meeting)
        service.appendStableSegments([segment("b", 2, end: 7.5, speaker: " SPEAKER_01 "), segment("c", 3, end: 4)], to: meeting)

        assertFactsMatch(meeting)
        let facts = meeting.transcriptFacts
        XCTAssertEqual(facts.segmentCount, 3)
        XCTAssertEqual(facts.transcriptDuration, 7.5)
        XCTAssertEqual(facts.speakerLabels, ["SPEAKER_00", "SPEAKER_01"])
    }

    func testOutputAddAndDeleteKeepKinds() {
        let service = MeetingService(appSupportDirectory: dir)
        let meeting = service.createMeeting(title: "Outputs")
        let summary = service.addOutput(to: meeting, kind: .summary, content: "s")
        service.addOutput(to: meeting, kind: .brief, content: "b")
        assertFactsMatch(meeting)
        XCTAssertEqual(meeting.outputKinds, [.summary, .brief])
        XCTAssertTrue(meeting.hasContent)

        service.deleteOutput(summary)
        assertFactsMatch(meeting)
        XCTAssertEqual(meeting.outputKinds, [.brief])
        XCTAssertFalse(meeting.hasContent, "a brief alone is not document content")
    }

    func testReplaceMergeImportAndTimingEditsRecompute() {
        let service = MeetingService(appSupportDirectory: dir)
        let meeting = service.createMeeting(title: "Rewrite", state: .completed, startDate: Date())
        service.appendStableSegments([segment("a", 0), segment("b", 1), segment("c", 2)], to: meeting)

        service.replaceSegments(of: meeting, source: .liveCapture, with: [segment("final", 0, end: 9)])
        assertFactsMatch(meeting)
        XCTAssertEqual(meeting.transcriptFacts.segmentCount, 1)

        _ = service.mergeImport(
            into: meeting,
            segments: (0..<4).map { segment("imported \($0)", Double(100 + $0 * 10)) },
            source: .importedTranscript
        )
        assertFactsMatch(meeting)

        let first = meeting.segments.sorted { $0.order < $1.order }[0]
        service.updateSegmentTimings([(id: first.id, start: 0, end: 999)], for: meeting)
        assertFactsMatch(meeting)
        XCTAssertEqual(meeting.transcriptFacts.transcriptEnd, 999)
    }

    func testSpeakerLabelWritesRecompute() {
        let service = MeetingService(appSupportDirectory: dir)
        let meeting = service.createMeeting(title: "Speakers", state: .completed)
        service.appendStableSegments([segment("a", 0), segment("b", 1)], to: meeting)
        let ids = meeting.segments.map(\.id)

        service.applySpeakerLabels(
            [MeetingSpeakerAssignment(segmentID: ids[0], label: "SPEAKER_00", confidence: 0.9),
             MeetingSpeakerAssignment(segmentID: ids[1], label: "SPEAKER_01", confidence: 0.9)],
            to: meeting
        )
        assertFactsMatch(meeting)
        XCTAssertEqual(meeting.transcriptFacts.speakerCount, 2)

        service.clearSpeakerLabels(for: meeting)
        assertFactsMatch(meeting)
        XCTAssertEqual(meeting.transcriptFacts.speakerCount, 0)
    }

    func testMeetingMergeRecomputesTheSurvivor() throws {
        let service = MeetingService(appSupportDirectory: dir)
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let primary = service.createMeeting(title: "Sync", state: .completed, startDate: start)
        let duplicate = service.createMeeting(title: "Sync", state: .completed, startDate: start.addingTimeInterval(60))
        service.appendStableSegments([segment("p", 0)], to: primary)
        service.appendStableSegments([segment("d1", 0), segment("d2", 1)], to: duplicate)
        service.addOutput(to: duplicate, kind: .extended, content: "x")

        let plan = try XCTUnwrap(MeetingMergePlanner.plan([primary, duplicate].map { MeetingMergeSnapshot(of: $0) }))
        let survivor = try XCTUnwrap(service.applyMerge(plan))
        assertFactsMatch(survivor)
        XCTAssertEqual(survivor.transcriptFacts.segmentCount, 3)
        XCTAssertTrue(survivor.outputKinds.contains(.extended))
    }

    func testBackupRestoreComputesFacts() throws {
        let service = MeetingService(appSupportDirectory: dir)
        let meeting = service.createMeeting(title: "Backed up", state: .completed, startDate: Date())
        service.appendStableSegments([segment("a", 0, end: 3), segment("b", 3, end: 6)], to: meeting)
        service.addOutput(to: meeting, kind: .summary, content: "s")
        let dto = SettingsBackupExporter.meetingDTOs(from: [meeting])[0]
        service.deleteMeeting(meeting)

        XCTAssertEqual(service.importMeetings([dto]), 1)
        let restored = try XCTUnwrap(service.meetings.first { $0.id == dto.id })
        assertFactsMatch(restored)
        XCTAssertEqual(restored.transcriptFacts.segmentCount, 2)
        XCTAssertEqual(restored.outputKinds, [.summary])
    }

    // MARK: - Fallback and self-heal (the relationship wins)

    func testUnsetColumnsFallBackToTheRelationships() {
        let service = MeetingService(appSupportDirectory: dir)
        let meeting = service.createMeeting(title: "Old row")
        service.appendStableSegments([segment("a", 0, end: 4)], to: meeting)
        service.addOutput(to: meeting, kind: .summary, content: "s")
        clearFacts(meeting)

        XCTAssertTrue(meeting.hasTranscript)
        XCTAssertEqual(meeting.transcriptFacts.transcriptDuration, 4)
        XCTAssertEqual(meeting.outputKinds, [.summary])

        // A live append on an unfilled row leaves it for the backfill; reads stay correct.
        service.appendStableSegments([segment("b", 4, end: 5)], to: meeting)
        XCTAssertNil(meeting.factSegmentCount)
        XCTAssertEqual(meeting.transcriptFacts.segmentCount, 2)
    }

    func testAColumnClaimingEmptyNeverHidesATranscriptAndHeals() async {
        let service = MeetingService(appSupportDirectory: dir)
        let meeting = service.createMeeting(title: "Drifted")
        service.appendStableSegments([segment("a", 0), segment("b", 1)], to: meeting)
        service.addOutput(to: meeting, kind: .summary, content: "s")
        meeting.factSegmentCount = 0
        meeting.factOutputKindsRaw = ""

        // Read: the relationship wins over a column claiming "nothing here".
        XCTAssertTrue(meeting.hasTranscript)
        XCTAssertEqual(meeting.transcriptFacts.segmentCount, 2)
        XCTAssertEqual(meeting.outputKinds, [.summary])

        // Heal: the reconcile pass rewrites the columns from the store.
        await service.reconcileFacts()
        XCTAssertEqual(meeting.factSegmentCount, 2)
        assertFactsMatch(meeting)
    }

    func testReconcileHealsAPositiveCountThatIsTooLow() async {
        let service = MeetingService(appSupportDirectory: dir)
        let meeting = service.createMeeting(title: "Under-counted")
        service.appendStableSegments((0..<5).map { segment("s\($0)", Double($0)) }, to: meeting)
        meeting.factSegmentCount = 2

        XCTAssertTrue(service.reconcileFacts(for: meeting))
        XCTAssertEqual(meeting.factSegmentCount, 5)
        XCTAssertFalse(service.reconcileFacts(for: meeting), "a reconciled row is left alone")
    }

    func testReconcileBackfillsAV1StoreAndIsIdempotent() async throws {
        let meetingID = UUID()
        try autoreleasepool {
            let config = ModelConfiguration(url: dir.appendingPathComponent("meetings.store"))
            let container = try ModelContainer(for: Schema(MeetingsSchemaV1.models), configurations: [config])
            let context = ModelContext(container)
            let meeting = MeetingsSchemaV1.Meeting(id: meetingID, title: "Pre-facts", startDate: Date())
            context.insert(meeting)
            for index in 0..<4 {
                context.insert(MeetingsSchemaV1.MeetingSegment(
                    order: index, start: Double(index), end: Double(index) + 2, text: "l\(index)",
                    speakerLabel: "SPEAKER_0\(index % 2)", meeting: meeting
                ))
            }
            context.insert(MeetingsSchemaV1.MeetingOutput(kindRaw: "summary", content: "s", meeting: meeting))
            try context.save()
        }

        let service = MeetingService(appSupportDirectory: dir)
        let meeting = try XCTUnwrap(service.meetings.first { $0.id == meetingID })
        XCTAssertFalse(meeting.hasStoredFacts, "rows from before the columns start unset")
        XCTAssertEqual(meeting.transcriptFacts.segmentCount, 4, "and read through the relationship")

        await service.reconcileFacts(chunkSize: 1)
        assertFactsMatch(meeting)
        XCTAssertEqual(meeting.transcriptFacts.transcriptDuration, 5)
        XCTAssertEqual(meeting.transcriptFacts.speakerCount, 2)

        let updatedAt = meeting.updatedAt
        await service.reconcileFacts()
        XCTAssertEqual(meeting.updatedAt, updatedAt, "fact writes are not edits")

        // Durable: a fresh service sees the backfilled columns.
        let reopened = MeetingService(appSupportDirectory: dir)
        let again = try XCTUnwrap(reopened.meetings.first { $0.id == meetingID })
        XCTAssertEqual(again.factSegmentCount, 4)
        XCTAssertEqual(again.storedOutputKinds, [.summary])
    }
}
