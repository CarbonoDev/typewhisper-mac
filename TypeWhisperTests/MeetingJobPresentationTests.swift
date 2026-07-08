import XCTest
@testable import TypeWhisper

/// Pure presentation tests for the meeting activity popover and Home "working" badge (job-queue plan
/// J3). No SwiftUI, no queue, no timing — every function under test is a pure map over value types, so
/// the popover sectioning/order, the localized kind labels, the cancellability rules (including the
/// finding-1 queued-`finalTranscription` guard), and the working-badge derivation are all
/// deterministic.
@MainActor
final class MeetingJobPresentationTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_700_000_000)

    private func job(
        kind: MeetingJobKind,
        state: MeetingJobState,
        priority: MeetingJobPriority = .userInitiated,
        created: TimeInterval = 0,
        started: TimeInterval? = nil,
        finished: TimeInterval? = nil,
        meetingID: UUID? = UUID()
    ) -> MeetingJob {
        MeetingJob(
            id: UUID(),
            kind: kind,
            meetingID: meetingID,
            state: state,
            priority: priority,
            createdAt: base.addingTimeInterval(created),
            startedAt: started.map { base.addingTimeInterval($0) },
            finishedAt: finished.map { base.addingTimeInterval($0) },
            progressLabel: nil,
            dedupeKey: nil
        )
    }

    // MARK: - Sectioning

    func testSectionsGroupByStateAndOrderWithinEachGroup() {
        let runningLate = job(kind: .summary, state: .running, started: 10)
        let runningEarly = job(kind: .brief, state: .running, started: 5)
        let queuedBackground = job(kind: .brief, state: .queued, priority: .background, created: 1)
        let queuedUser = job(kind: .summary, state: .queued, priority: .userInitiated, created: 2)
        let failedOld = job(kind: .audioImport, state: .failed(message: "a"), finished: 3)
        let failedNew = job(kind: .diarization, state: .failed(message: "b"), finished: 8)
        // Interleave input order to prove the sectioning does the ordering, not the caller.
        let sections = MeetingJobPresentation.sections(from: [
            failedOld, runningLate, queuedBackground, failedNew, queuedUser, runningEarly,
        ])

        // Running: oldest start first.
        XCTAssertEqual(sections.running.map(\.id), [runningEarly.id, runningLate.id])
        // Queued: userInitiated before background (driver order).
        XCTAssertEqual(sections.queued.map(\.id), [queuedUser.id, queuedBackground.id])
        // Failed: newest failure first.
        XCTAssertEqual(sections.failed.map(\.id), [failedNew.id, failedOld.id])
        XCTAssertFalse(sections.isEmpty)
    }

    func testSectionsIgnoreSucceededAndCancelledAndIsEmptyWhenNothingToShow() {
        let sections = MeetingJobPresentation.sections(from: [
            job(kind: .summary, state: .succeeded, finished: 1),
            job(kind: .brief, state: .cancelled, finished: 2),
        ])
        XCTAssertTrue(sections.running.isEmpty)
        XCTAssertTrue(sections.queued.isEmpty)
        XCTAssertTrue(sections.failed.isEmpty)
        XCTAssertTrue(sections.isEmpty)
    }

    // MARK: - Kind labels

    func testEveryKindHasANonEmptyDistinctLabel() {
        let labels = MeetingJobKind.allCases.map(\.displayName)
        XCTAssertTrue(labels.allSatisfy { !$0.isEmpty }, "every kind must have a localized label")
        XCTAssertEqual(Set(labels).count, MeetingJobKind.allCases.count, "labels must be distinct")
    }

    // MARK: - Cancellability (finding 1)

    func testCanCancelForbidsQueuedFinalTranscriptionButAllowsRunning() {
        // Finding 1: a queued final pass must NOT be cancellable (cancelling it would mark the job
        // `.cancelled` without running `runFinalization`, stranding the meeting in `.processing`). Once
        // running, it is cancellable (its keep-live path still completes the meeting).
        XCTAssertFalse(MeetingJobPresentation.canCancel(job(kind: .finalTranscription, state: .queued)))
        XCTAssertTrue(MeetingJobPresentation.canCancel(job(kind: .finalTranscription, state: .running, started: 1)))
    }

    func testCanCancelForbidsExportAndSettledJobs() {
        XCTAssertFalse(MeetingJobPresentation.canCancel(job(kind: .export, state: .queued)))
        XCTAssertFalse(MeetingJobPresentation.canCancel(job(kind: .export, state: .running, started: 1)))
        XCTAssertFalse(MeetingJobPresentation.canCancel(job(kind: .summary, state: .succeeded, finished: 1)))
        XCTAssertFalse(MeetingJobPresentation.canCancel(job(kind: .summary, state: .failed(message: "x"), finished: 1)))
    }

    func testCanCancelAllowsOrdinaryActiveJobs() {
        XCTAssertTrue(MeetingJobPresentation.canCancel(job(kind: .summary, state: .queued)))
        XCTAssertTrue(MeetingJobPresentation.canCancel(job(kind: .brief, state: .running, started: 1)))
        XCTAssertTrue(MeetingJobPresentation.canCancel(job(kind: .audioImport, state: .queued)))
        XCTAssertTrue(MeetingJobPresentation.canCancel(job(kind: .diarization, state: .running, started: 1)))
    }

    // MARK: - Home working badge

    func testHomeActivityBadgeIsNilWhenNothingRunning() {
        XCTAssertNil(MeetingsViewModel.homeActivityBadge(runningKinds: []))
    }

    func testHomeActivityBadgeUsesTheRunningKindLabel() {
        let badge = MeetingsViewModel.homeActivityBadge(runningKinds: [.summary])
        XCTAssertEqual(badge, MeetingActivityBadge(text: MeetingJobKind.summary.displayName))
    }

    func testHomeActivityBadgePrefersTheMostBlockingKind() {
        // With both a final transcription and a summary running, the transcription (more blocking)
        // wins the label, deterministically regardless of input order.
        let badge = MeetingsViewModel.homeActivityBadge(runningKinds: [.summary, .finalTranscription])
        XCTAssertEqual(badge?.text, MeetingJobKind.finalTranscription.displayName)
    }
}
