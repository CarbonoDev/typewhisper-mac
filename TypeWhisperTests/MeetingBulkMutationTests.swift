import XCTest
import Combine
import TypeWhisperPluginSDK
@testable import TypeWhisper

/// LX-2 — bulk mutators + rename + job fan-out (plan LX-2, D5/D6). The service-level mutators follow
/// the `renameTag` single-save pattern: a loop-then-one-`save()`/`fetchMeetings()` guarded by a
/// `didChange` flag. "Single save" is asserted via a single `$meetings` emission (one `fetchMeetings`
/// republish) using the same `MeetingService(appSupportDirectory:)` + reopen discipline as
/// `MeetingServiceTests`/`MeetingOrganizationTests`. The long-running fan-out (generate / export)
/// enqueues one job per meeting; those are validated against a real `JobQueueService` — the exact
/// primitive the VM's thin `generateBriefs`/`exportToVault` loops call.
@MainActor
final class MeetingBulkMutationTests: XCTestCase {
    // MARK: - Emission counter (single-save seam)

    /// Count `$meetings` republishes after subscription (drops the initial replay). A single-save bulk
    /// mutator republishes exactly once; a no-op republishes zero times.
    private func countingEmissions(
        of service: MeetingService,
        during body: () -> Void
    ) -> Int {
        var count = 0
        let cancellable = service.$meetings.dropFirst().sink { _ in count += 1 }
        body()
        cancellable.cancel()
        return count
    }

    // MARK: - Bulk setFolder

    func testSetFolderBulkMovesEveryMeetingInOneSaveAndPersists() throws {
        let dir = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(dir) }

        let ids: [UUID]
        do {
            let service = MeetingService(appSupportDirectory: dir)
            let a = service.createMeeting(title: "A")
            let b = service.createMeeting(title: "B")
            let c = service.createMeeting(title: "C")
            service.setFolder("Existing", for: c) // already filed; a/b unfiled
            ids = [a.id, b.id]

            let emissions = countingEmissions(of: service) {
                service.setFolder("Acme/Q3", for: [a, b, c])
            }
            XCTAssertEqual(emissions, 1, "one fetchMeetings republish for the whole bulk move")
            XCTAssertEqual(a.folderPath, "Acme/Q3")
            XCTAssertEqual(b.folderPath, "Acme/Q3")
            XCTAssertEqual(c.folderPath, "Acme/Q3")
        }

        let reopened = MeetingService(appSupportDirectory: dir)
        for id in ids {
            let m = try XCTUnwrap(reopened.meetings.first { $0.id == id })
            XCTAssertEqual(m.folderPath, "Acme/Q3")
        }
    }

    func testSetFolderBulkMatchesPerItemMutatorAndClearsToUnfiled() throws {
        let dir = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(dir) }
        let service = MeetingService(appSupportDirectory: dir)
        let a = service.createMeeting(title: "A")
        let b = service.createMeeting(title: "B")
        service.setFolder("Acme", for: [a, b])
        // Bulk clear (nil / blank ⇒ Unfiled), same normalization as the single mutator.
        service.setFolder("  ", for: [a, b])
        XCTAssertNil(a.folderPath)
        XCTAssertNil(b.folderPath)
    }

    func testSetFolderBulkNoOpWhenNothingChanges() throws {
        let dir = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(dir) }
        let service = MeetingService(appSupportDirectory: dir)
        let a = service.createMeeting(title: "A")
        let b = service.createMeeting(title: "B")
        service.setFolder("Acme", for: [a, b])

        let emissions = countingEmissions(of: service) {
            service.setFolder("Acme", for: [a, b]) // already there
        }
        XCTAssertEqual(emissions, 0, "an all-no-change bulk move does not save/republish")
    }

    // MARK: - Bulk add / remove tag

    func testAddTagBulkAddsEverywhereCaseFoldedInOneSave() throws {
        let dir = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(dir) }
        let service = MeetingService(appSupportDirectory: dir)
        let a = service.createMeeting(title: "A")
        let b = service.createMeeting(title: "B")
        service.setObsidianTags(["Hiring"], for: a) // already carries a case variant

        let emissions = countingEmissions(of: service) {
            service.addTag("hiring", to: [a, b])
        }
        XCTAssertEqual(emissions, 1, "only b changed, but still a single save for the batch")
        XCTAssertEqual(a.tags, ["Hiring"], "case-variant already present ⇒ not duplicated")
        XCTAssertEqual(b.tags, ["hiring"])
    }

    func testAddTagBulkNoOpWhenAllAlreadyCarryItOrBlank() throws {
        let dir = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(dir) }
        let service = MeetingService(appSupportDirectory: dir)
        let a = service.createMeeting(title: "A")
        let b = service.createMeeting(title: "B")
        service.setObsidianTags(["q3"], for: a)
        service.setObsidianTags(["Q3"], for: b)

        let emissions = countingEmissions(of: service) {
            service.addTag("q3", to: [a, b]) // both already carry (case-folded)
            service.addTag("   ", to: [a, b]) // blank
        }
        XCTAssertEqual(emissions, 0)
    }

    func testRemoveTagBulkRemovesEverywhereCaseFoldedInOneSave() throws {
        let dir = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(dir) }
        let service = MeetingService(appSupportDirectory: dir)
        let a = service.createMeeting(title: "A")
        let b = service.createMeeting(title: "B")
        let c = service.createMeeting(title: "C")
        service.setObsidianTags(["hiring", "q3"], for: a)
        service.setObsidianTags(["Hiring"], for: b)
        service.setObsidianTags(["roadmap"], for: c) // untouched

        let emissions = countingEmissions(of: service) {
            service.removeTag("hiring", from: [a, b, c])
        }
        XCTAssertEqual(emissions, 1)
        XCTAssertEqual(a.tags, ["q3"])
        XCTAssertTrue(b.tags.isEmpty, "case-variant removed too")
        XCTAssertEqual(c.tags, ["roadmap"], "meeting without the tag untouched")
    }

    // MARK: - Bulk delete

    func testDeleteMeetingsBulkRemovesAllInOneSaveAndDeletesAudio() throws {
        let dir = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(dir) }

        let survivorID: UUID
        do {
            let service = MeetingService(appSupportDirectory: dir)
            let a = service.createMeeting(title: "A")
            let b = service.createMeeting(title: "B")
            let survivor = service.createMeeting(title: "Keep")
            survivorID = survivor.id

            // Give `a` an audio blob so we can assert the bulk delete sweeps it.
            let audioSource = dir.appendingPathComponent("clip.wav")
            try Data([0x1, 0x2, 0x3]).write(to: audioSource)
            service.adoptAudioFile(audioSource, for: a)
            let audioURL = try XCTUnwrap(service.audioFileURL(for: a))
            XCTAssertTrue(FileManager.default.fileExists(atPath: audioURL.path))

            let emissions = countingEmissions(of: service) {
                service.deleteMeetings([a, b])
            }
            XCTAssertEqual(emissions, 1, "one republish for the whole batch delete")
            XCTAssertEqual(service.meetings.map(\.id), [survivorID])
            XCTAssertFalse(FileManager.default.fileExists(atPath: audioURL.path), "audio blob removed")
        }

        let reopened = MeetingService(appSupportDirectory: dir)
        XCTAssertEqual(reopened.meetings.map(\.id), [survivorID])
    }

    func testDeleteMeetingsBulkNoOpOnEmptyInput() throws {
        let dir = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(dir) }
        let service = MeetingService(appSupportDirectory: dir)
        _ = service.createMeeting(title: "A")

        let emissions = countingEmissions(of: service) {
            service.deleteMeetings([])
        }
        XCTAssertEqual(emissions, 0)
        XCTAssertEqual(service.meetings.count, 1)
    }

    // MARK: - Rename (reuses the identity milestone's title editing)

    func testRenameSetsTitleAndBumpsUpdatedAt() throws {
        let dir = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(dir) }
        let service = MeetingService(appSupportDirectory: dir)
        let a = service.createMeeting(title: "Old")
        let before = a.updatedAt

        service.setTitle("New Title", for: a)
        XCTAssertEqual(a.title, "New Title")
        XCTAssertGreaterThanOrEqual(a.updatedAt, before)

        // Blank title is ignored — a meeting always keeps a title.
        service.setTitle("   ", for: a)
        XCTAssertEqual(a.title, "New Title")
    }

    // MARK: - Long-running fan-out (one job per meeting; dedupe protects the provider)

    func testBulkGenerateFansOutOneLLMJobPerMeetingAndDedupesRefires() {
        let queue = JobQueueService()
        let m1 = UUID(), m2 = UUID(), m3 = UUID()
        // The VM's `generateBriefs` loop is one `enqueue(kind: .brief, meetingID:)` per meeting.
        for id in [m1, m2, m3] {
            queue.enqueue(kind: .brief, meetingID: id) {}
        }
        XCTAssertEqual(queue.jobs.filter { $0.kind == .brief && $0.state.isActive }.count, 3)

        // A re-fire over the same selection dedupes on (kind, meetingID): no new jobs.
        for id in [m1, m2, m3] {
            queue.enqueue(kind: .brief, meetingID: id) {}
        }
        XCTAssertEqual(queue.jobs.filter { $0.kind == .brief && $0.state.isActive }.count, 3,
                       "cap-1 llm lane + (kind, meetingID) dedupe collapse the re-fire")
        XCTAssertTrue(queue.jobs.allSatisfy { $0.lane == .llm })
    }

    func testBulkExportFansOutOneIOJobPerMeeting() {
        let queue = JobQueueService()
        let ids = (0..<4).map { _ in UUID() }
        for id in ids {
            queue.enqueue(kind: .export, meetingID: id) {}
        }
        let exportJobs = queue.jobs.filter { $0.kind == .export }
        XCTAssertEqual(exportJobs.count, 4)
        XCTAssertTrue(exportJobs.allSatisfy { $0.lane == .io }, "export runs on the unbounded io lane")
    }
}
