import XCTest
import Combine
import Observation
import SwiftData
@testable import TypeWhisper

/// Perf 1C: in-place writes save without refetching/republishing the meetings list; list-shaped
/// writes (insert, delete, sort-key change, folders/tags) still do; `performBatch` coalesces the
/// republish. Views see in-place writes through SwiftData Observation, which these tests lock.
@MainActor
final class MeetingServicePublishingTests: XCTestCase {
    private var dir: URL!
    private var cancellables = Set<AnyCancellable>()

    override func setUpWithError() throws {
        dir = try TestSupport.makeTemporaryDirectory()
    }

    override func tearDown() {
        cancellables.removeAll()
        TestSupport.remove(dir)
        super.tearDown()
    }

    private final class Counter { var value = 0 }

    /// Counts `meetingsListPublisher` emissions after subscription (the initial replay is dropped).
    private func listEmissions(of service: MeetingService) -> Counter {
        let counter = Counter()
        service.meetingsListPublisher.dropFirst().sink { _ in counter.value += 1 }.store(in: &cancellables)
        return counter
    }

    private func observationFires(_ read: @escaping () -> Void, after mutate: () -> Void) -> Bool {
        final class Flag: @unchecked Sendable { var value = false }
        let fired = Flag()
        withObservationTracking { read() } onChange: { fired.value = true }
        mutate()
        return fired.value
    }

    private func segment(_ text: String, _ start: Double) -> TranscriptionSegment {
        TranscriptionSegment(text: text, start: start, end: start + 1)
    }

    // MARK: - Live append

    func testLiveAppendDoesNotRepublishTheList() {
        let service = MeetingService(appSupportDirectory: dir)
        let meeting = service.createMeeting(title: "Live", state: .live, startDate: Date())
        let emissions = listEmissions(of: service)

        for index in 0..<5 {
            service.appendStableSegments([segment("s\(index)", Double(index))], source: .liveCaptions, to: meeting)
        }

        XCTAssertEqual(emissions.value, 0)
        XCTAssertEqual(service.meetings.first?.segments.count, 5)
    }

    func testLiveAppendIsDurableAndKeepsOrderSequence() {
        let meetingID: UUID
        do {
            let service = MeetingService(appSupportDirectory: dir)
            let meeting = service.createMeeting(title: "Live", state: .live, startDate: Date())
            meetingID = meeting.id
            service.appendStableSegments([segment("a", 0), segment("b", 1)], source: .liveCaptions, to: meeting)
            service.appendStableSegments([segment("c", 2)], source: .liveCaptions, to: meeting)
            service.appendStableSegments([segment("d", 3)], source: .liveCaptions, to: meeting)
        }

        // A fresh service on the same store sees every appended segment, in order.
        let reopened = MeetingService(appSupportDirectory: dir)
        let meeting = reopened.meetings.first { $0.id == meetingID }
        let ordered = meeting?.segments.sorted { $0.order < $1.order }
        XCTAssertEqual(ordered?.map(\.order), [0, 1, 2, 3])
        XCTAssertEqual(ordered?.map(\.text), ["a", "b", "c", "d"])

        // …and appending after reopening continues the sequence from the store.
        reopened.appendStableSegments([segment("e", 4)], source: .liveCaptions, to: meeting!)
        XCTAssertEqual(meeting?.segments.map(\.order).max(), 4)
    }

    /// The live-append order cache must never hand out an order that collides with, or sorts
    /// before, segments another path wrote. Each case: append (populates the cache) → rewrite →
    /// append, then the orders are unique and the last append sorts after everything else.
    private func assertAppendSortsLast(
        on meeting: Meeting,
        service: MeetingService,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        service.appendStableSegments([segment("after", 500)], to: meeting)
        let orders = meeting.segments.map(\.order)
        XCTAssertEqual(Set(orders).count, orders.count, "orders must be unique: \(orders.sorted())", file: file, line: line)
        let last = meeting.segments.first { $0.text == "after" }
        XCTAssertEqual(last?.order, orders.max(), "the appended segment must sort last", file: file, line: line)
        XCTAssertEqual(orders.max(), orders.count - 1, "orders stay dense: \(orders.sorted())", file: file, line: line)
    }

    func testAppendAfterReplaceSegmentsSortsLast() {
        let service = MeetingService(appSupportDirectory: dir)
        let meeting = service.createMeeting(title: "Live", state: .live, startDate: Date())
        service.appendStableSegments([segment("a", 0), segment("b", 1), segment("c", 2)], to: meeting)

        // The final pass replaces the three live rows with one.
        service.replaceSegments(of: meeting, source: .liveCapture, with: [segment("final", 0)])

        assertAppendSortsLast(on: meeting, service: service)
    }

    func testAppendAfterMergeImportSortsLast() {
        let service = MeetingService(appSupportDirectory: dir)
        let meeting = service.createMeeting(title: "Live", state: .completed, startDate: Date())
        service.appendStableSegments([segment("a", 0), segment("b", 1)], to: meeting)

        // A Drive/file transcript merged in: more rows than the cache knows about, renumbered.
        _ = service.mergeImport(
            into: meeting,
            segments: (0..<6).map { segment("imported \($0)", Double(100 + $0 * 10)) },
            source: .importedTranscript
        )
        XCTAssertGreaterThan(meeting.segments.count, 2, "precondition: the merge grew the transcript")

        assertAppendSortsLast(on: meeting, service: service)
    }

    func testAppendAfterApplyMergeSortsLast() throws {
        let service = MeetingService(appSupportDirectory: dir)
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let primary = service.createMeeting(title: "Sync", state: .completed, startDate: start)
        let duplicate = service.createMeeting(title: "Sync", state: .completed, startDate: start.addingTimeInterval(60))
        service.appendStableSegments([segment("p1", 0), segment("p2", 1)], to: primary)
        service.appendStableSegments([segment("d1", 0), segment("d2", 1), segment("d3", 2)], to: duplicate)

        let plan = try XCTUnwrap(MeetingMergePlanner.plan([primary, duplicate].map { MeetingMergeSnapshot(of: $0) }))
        let survivor = try XCTUnwrap(service.applyMerge(plan))
        XCTAssertEqual(survivor.segments.count, 5, "precondition: the survivor absorbed the duplicate's rows")

        assertAppendSortsLast(on: survivor, service: service)
    }

    func testAppendAfterBackupRestoreOfADeletedMeetingSortsLast() {
        let service = MeetingService(appSupportDirectory: dir)
        let meeting = service.createMeeting(title: "Restored", state: .completed, startDate: Date())
        service.appendStableSegments([segment("a", 0)], to: meeting)
        let dto = SettingsBackupExporter.meetingDTOs(from: [meeting])[0]
        service.deleteMeeting(meeting)

        // Restoring the backup re-inserts the same id with its own segment orders.
        var restoredDTO = dto
        restoredDTO.segments += (1..<4).map { index in
            var extra = dto.segments[0]
            extra.id = UUID()
            extra.order = index
            extra.text = "restored \(index)"
            return extra
        }
        XCTAssertEqual(service.importMeetings([restoredDTO]), 1)
        let restored = service.meetings.first { $0.id == dto.id }!

        assertAppendSortsLast(on: restored, service: service)
    }

    // MARK: - Observation (the signal views rely on instead of the republish)

    func testInPlaceWritesFireSwiftDataObservationOnTheMeeting() {
        let service = MeetingService(appSupportDirectory: dir)
        let meeting = service.createMeeting(title: "Observed", startDate: Date())
        service.appendStableSegments([segment("a", 0)], to: meeting)
        service.addOutput(to: meeting, kind: .summary, content: "first")

        XCTAssertTrue(observationFires({ _ = meeting.segments }) {
            service.appendStableSegments([segment("b", 1)], to: meeting)
        }, "segment append")
        XCTAssertTrue(observationFires({ _ = meeting.updatedAt }) {
            service.appendStableSegments([segment("c", 2)], to: meeting)
        }, "updatedAt on append")
        XCTAssertTrue(observationFires({ _ = meeting.outputs }) {
            service.addOutput(to: meeting, kind: .summary, content: "second")
        }, "output insert")
        XCTAssertTrue(observationFires({ _ = meeting.outputs }) {
            service.deleteOutput(meeting.outputs[0])
        }, "output delete")
        XCTAssertTrue(observationFires({ _ = meeting.notes }) {
            service.addNote(to: meeting, text: "note")
        }, "note insert")
        XCTAssertTrue(observationFires({ _ = meeting.title }) {
            service.setTitle("Renamed", for: meeting)
        }, "title")
    }

    // MARK: - List-shaped writes still republish

    func testInsertAndDeleteRepublish() {
        let service = MeetingService(appSupportDirectory: dir)
        let emissions = listEmissions(of: service)

        let meeting = service.createMeeting(title: "A", startDate: Date())
        XCTAssertEqual(emissions.value, 1)
        XCTAssertEqual(service.meetings.map(\.id), [meeting.id])

        service.deleteMeeting(meeting)
        XCTAssertEqual(emissions.value, 2)
        XCTAssertTrue(service.meetings.isEmpty)
    }

    func testTitleEditDoesNotRepublishButSortKeyChangeReorders() {
        let service = MeetingService(appSupportDirectory: dir)
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let older = service.createMeeting(title: "Older", startDate: base)
        let newer = service.createMeeting(title: "Newer", startDate: base.addingTimeInterval(3600))
        XCTAssertEqual(service.meetings.map(\.id), [newer.id, older.id])
        let emissions = listEmissions(of: service)

        service.setTitle("Older, renamed", for: older)
        XCTAssertEqual(emissions.value, 0)

        // Moving `older` past `newer` breaks the fetch order → refetch + republish.
        service.setMeetingDate(base.addingTimeInterval(7200), for: older)
        XCTAssertEqual(emissions.value, 1)
        XCTAssertEqual(service.meetings.map(\.id), [older.id, newer.id])

        // A date change that keeps the order does not republish.
        service.setMeetingDate(base.addingTimeInterval(7100), for: older)
        XCTAssertEqual(emissions.value, 1)
    }

    func testFolderAndTagWritesRepublishForTheOrganizationIndex() {
        let service = MeetingService(appSupportDirectory: dir)
        let meeting = service.createMeeting(title: "A", startDate: Date())
        let index = MeetingOrganizationIndex(meetingService: service)

        service.setFolder("Clients/Acme", for: meeting)
        XCTAssertEqual(index.folderTree.map(\.path), ["Clients"])
        service.setObsidianTags(["hiring"], for: meeting)
        XCTAssertEqual(index.tagCounts.map(\.key), ["hiring"])
    }

    // MARK: - performBatch

    func testBatchRepublishesOnceAndKeepsMembershipExactInside() {
        let service = MeetingService(appSupportDirectory: dir)
        let emissions = listEmissions(of: service)

        service.performBatch {
            let first = service.createMeeting(title: "One", startDate: Date())
            // Bulk writers dedupe against `meetings` mid-batch: it must already include `first`.
            XCTAssertTrue(service.meetings.contains { $0.id == first.id })
            service.createMeeting(title: "Two", startDate: Date())
            service.performBatch { service.createMeeting(title: "Three", startDate: Date()) }
            XCTAssertEqual(emissions.value, 0)
        }

        XCTAssertEqual(emissions.value, 1)
        XCTAssertEqual(service.meetings.count, 3)
    }

    func testBatchWithOnlyInPlaceWritesDoesNotRepublish() {
        let service = MeetingService(appSupportDirectory: dir)
        let meeting = service.createMeeting(title: "A", startDate: Date())
        let emissions = listEmissions(of: service)

        service.performBatch {
            service.appendStableSegments([segment("a", 0)], to: meeting)
            service.addNote(to: meeting, text: "n")
        }
        XCTAssertEqual(emissions.value, 0)
    }

    func testCreateFromImportRepublishesOnce() {
        let service = MeetingService(appSupportDirectory: dir)
        let emissions = listEmissions(of: service)

        service.createFromImport(
            title: "Imported",
            source: .importedTranscript,
            segments: [segment("a", 0), segment("b", 1)],
            segmentSource: .importedTranscript,
            startDate: Date()
        )
        XCTAssertEqual(emissions.value, 1)
        XCTAssertEqual(service.meetings.first?.segments.count, 2)
    }

    // MARK: - Fetch-order check

    func testFetchOrderPutsUndatedMeetingsLastAndBreaksTiesOnCreation() {
        let service = MeetingService(appSupportDirectory: dir)
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        service.createMeeting(title: "Undated")
        service.createMeeting(title: "Dated", startDate: date)
        service.createMeeting(title: "Dated twin", startDate: date)
        // Whatever the store returned is, by definition, in fetch order.
        XCTAssertTrue(MeetingService.isInFetchOrder(service.meetings))
        XCTAssertEqual(service.meetings.last?.title, "Undated")
        XCTAssertFalse(MeetingService.isInFetchOrder(service.meetings.reversed()))
    }
}
