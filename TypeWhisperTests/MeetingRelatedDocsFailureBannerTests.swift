import XCTest
@testable import TypeWhisper

/// M8 carried minor: the "last related-docs search failed" banner must reflect only the *most
/// recently settled* discovery job, so a failure followed by a successful re-run clears the banner
/// (failed rows are retained until dismissed, so a naive "any failed row" check would keep showing it).
/// The ordering logic is a pure static over `[MeetingJob]`, unit-testable without the view model.
@MainActor
final class MeetingRelatedDocsFailureBannerTests: XCTestCase {

    private func job(
        _ kind: MeetingJobKind,
        _ state: MeetingJobState,
        finishedAt: Date?
    ) -> MeetingJob {
        MeetingJob(
            id: UUID(),
            kind: kind,
            meetingID: UUID(),
            state: state,
            priority: .userInitiated,
            createdAt: Date(timeIntervalSince1970: 0),
            startedAt: nil,
            finishedAt: finishedAt,
            progressLabel: nil,
            dedupeKey: nil
        )
    }

    private let t1 = Date(timeIntervalSince1970: 100)
    private let t2 = Date(timeIntervalSince1970: 200)

    func testFailureThenSuccessClearsBanner() {
        let jobs = [
            job(.relatedDiscovery, .failed(message: "judge failed"), finishedAt: t1),
            job(.relatedDiscovery, .succeeded, finishedAt: t2) // later → supersedes
        ]
        XCTAssertFalse(MeetingsViewModel.lastSettledJobFailed(jobs, kind: .relatedDiscovery))
    }

    func testSuccessThenFailureShowsBanner() {
        let jobs = [
            job(.relatedDiscovery, .succeeded, finishedAt: t1),
            job(.relatedDiscovery, .failed(message: "judge failed"), finishedAt: t2)
        ]
        XCTAssertTrue(MeetingsViewModel.lastSettledJobFailed(jobs, kind: .relatedDiscovery))
    }

    func testFailureOnlyShowsBanner() {
        let jobs = [job(.relatedDiscovery, .failed(message: "boom"), finishedAt: t1)]
        XCTAssertTrue(MeetingsViewModel.lastSettledJobFailed(jobs, kind: .relatedDiscovery))
    }

    func testFailureThenFailureShowsBanner() {
        let jobs = [
            job(.relatedDiscovery, .failed(message: "boom1"), finishedAt: t1),
            job(.relatedDiscovery, .failed(message: "boom2"), finishedAt: t2)
        ]
        XCTAssertTrue(MeetingsViewModel.lastSettledJobFailed(jobs, kind: .relatedDiscovery))
    }

    func testNoSettledJobsNoBanner() {
        let jobs = [job(.relatedDiscovery, .queued, finishedAt: nil),
                    job(.relatedDiscovery, .running, finishedAt: nil)]
        XCTAssertFalse(MeetingsViewModel.lastSettledJobFailed(jobs, kind: .relatedDiscovery))
    }

    func testOtherKindFailuresIgnored() {
        // A failed summary/brief must not trip the related-docs banner.
        let jobs = [
            job(.summary, .failed(message: "unrelated"), finishedAt: t2),
            job(.relatedDiscovery, .succeeded, finishedAt: t1)
        ]
        XCTAssertFalse(MeetingsViewModel.lastSettledJobFailed(jobs, kind: .relatedDiscovery))
    }

    // MARK: - Specific failure reason surfaced inline (banner diagnosis)

    func testFailureMessageSurfacesLatestReason() {
        let jobs = [
            job(.relatedDiscovery, .failed(message: "old reason"), finishedAt: t1),
            job(.relatedDiscovery, .failed(message: "newest reason"), finishedAt: t2)
        ]
        XCTAssertEqual(MeetingsViewModel.lastSettledFailureMessage(jobs, kind: .relatedDiscovery),
                       "newest reason", "the most recently settled failure's message wins")
    }

    func testFailureMessageNilWhenLatestSucceeded() {
        let jobs = [
            job(.relatedDiscovery, .failed(message: "boom"), finishedAt: t1),
            job(.relatedDiscovery, .succeeded, finishedAt: t2) // later → supersedes
        ]
        XCTAssertNil(MeetingsViewModel.lastSettledFailureMessage(jobs, kind: .relatedDiscovery))
    }

    func testFailureMessageNilWhenNoSettledJobs() {
        let jobs = [job(.relatedDiscovery, .queued, finishedAt: nil)]
        XCTAssertNil(MeetingsViewModel.lastSettledFailureMessage(jobs, kind: .relatedDiscovery))
    }
}
