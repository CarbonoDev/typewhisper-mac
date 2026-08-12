import XCTest
@testable import TypeWhisper

/// The D-D4 attach-to-meeting resolver ([Google Phase 2 · M1]), pure over candidate snapshots:
/// the 0.6 confidence threshold, the ±24 h window, the same-account → score → stable-id
/// tie-break among qualifying candidates, the near-miss create policy, and the
/// filename-date-else-createdTime fallback.
@MainActor
final class DriveTranscriptMatcherTests: XCTestCase {

    /// 2026-07-07 11:00:00 UTC — the date embedded in `datedFileName`.
    private let embeddedDate: Date = {
        var components = DateComponents()
        components.year = 2026; components.month = 7; components.day = 7
        components.hour = 11; components.minute = 0
        components.timeZone = TimeZone(identifier: "UTC")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: components)!
    }()

    private let datedFileName = "Weekly sync - 2026_07_07 11_00 UTC - Notes by Gemini"

    // MARK: - Threshold (merge vs near-miss)

    func testConfidentMatchMerges() {
        let target = DriveTranscriptMatcher.Candidate(
            title: "Weekly sync",
            startDate: embeddedDate
        )
        let unrelated = DriveTranscriptMatcher.Candidate(
            title: "Quarterly planning offsite",
            startDate: embeddedDate
        )

        let disposition = DriveTranscriptMatcher.disposition(
            fileName: datedFileName,
            createdTime: nil,
            sub: "sub-1",
            candidates: [unrelated, target]
        )

        guard case .merge(let meetingID, let score) = disposition else {
            return XCTFail("expected merge, got \(disposition)")
        }
        XCTAssertEqual(meetingID, target.id)
        XCTAssertEqual(score, 1.0, accuracy: 0.0001, "identical title + exact date scores ~1")
    }

    func testNearMissCreatesWithCleanTitleAndFilenameDate() {
        // Same slot, disjoint title: score = 0.35 × proximity < 0.6 → near-miss, never merged.
        let nearMiss = DriveTranscriptMatcher.Candidate(
            title: "Quarterly planning offsite",
            startDate: embeddedDate
        )

        let disposition = DriveTranscriptMatcher.disposition(
            fileName: datedFileName,
            createdTime: nil,
            sub: "sub-1",
            candidates: [nearMiss]
        )

        XCTAssertEqual(disposition, .create(title: "Weekly sync", startDate: embeddedDate))
    }

    func testNoCandidatesCreates() {
        let disposition = DriveTranscriptMatcher.disposition(
            fileName: datedFileName, createdTime: nil, sub: "sub-1", candidates: []
        )
        XCTAssertEqual(disposition, .create(title: "Weekly sync", startDate: embeddedDate))
    }

    // MARK: - ±24 h window (D-D4: a weekly recurring title can never hit the wrong occurrence)

    func testIdenticalTitleOutsideWindowCreates() {
        let lastWeeksOccurrence = DriveTranscriptMatcher.Candidate(
            title: "Weekly sync",
            startDate: embeddedDate.addingTimeInterval(-25 * 60 * 60)
        )
        let undated = DriveTranscriptMatcher.Candidate(title: "Weekly sync", startDate: nil)

        let disposition = DriveTranscriptMatcher.disposition(
            fileName: datedFileName,
            createdTime: nil,
            sub: "sub-1",
            candidates: [lastWeeksOccurrence, undated]
        )

        XCTAssertEqual(
            disposition,
            .create(title: "Weekly sync", startDate: embeddedDate),
            "out-of-window and undated meetings are never candidates"
        )
    }

    func testIdenticalTitleInsideWindowStillMerges() {
        let sameDayShift = DriveTranscriptMatcher.Candidate(
            title: "Weekly sync",
            startDate: embeddedDate.addingTimeInterval(3 * 60 * 60)
        )

        let disposition = DriveTranscriptMatcher.disposition(
            fileName: datedFileName, createdTime: nil, sub: "sub-1", candidates: [sameDayShift]
        )

        guard case .merge(let meetingID, _) = disposition else {
            return XCTFail("expected merge, got \(disposition)")
        }
        XCTAssertEqual(meetingID, sameDayShift.id)
    }

    // MARK: - Tie-breaks among qualifying candidates (D-D4)

    func testSameAccountWinsOnEqualScores() {
        // Two equally perfect candidates; only the second is linked to a calendar event from the
        // same Google account the transcript arrived through.
        let otherAccount = DriveTranscriptMatcher.Candidate(
            title: "Weekly sync",
            startDate: embeddedDate,
            calendarEventID: "google:sub-other:evt1"
        )
        let sameAccount = DriveTranscriptMatcher.Candidate(
            title: "Weekly sync",
            startDate: embeddedDate,
            calendarEventID: "google:sub-1:evt2"
        )

        let disposition = DriveTranscriptMatcher.disposition(
            fileName: datedFileName,
            createdTime: nil,
            sub: "sub-1",
            candidates: [otherAccount, sameAccount]
        )

        guard case .merge(let meetingID, _) = disposition else {
            return XCTFail("expected merge, got \(disposition)")
        }
        XCTAssertEqual(meetingID, sameAccount.id, "same-account affinity breaks the tie")
    }

    func testSameAccountAffinityNeverSuppressesAStrongerQualifierElsewhere() {
        // A weak same-account candidate below the threshold must not shadow a confident match
        // from another account — the threshold decides merge-vs-create, affinity only picks
        // among qualifiers.
        let weakSameAccount = DriveTranscriptMatcher.Candidate(
            title: "Totally different agenda",
            startDate: embeddedDate,
            calendarEventID: "google:sub-1:evt-weak"
        )
        let strongOtherAccount = DriveTranscriptMatcher.Candidate(
            title: "Weekly sync",
            startDate: embeddedDate,
            calendarEventID: "google:sub-other:evt-strong"
        )

        let disposition = DriveTranscriptMatcher.disposition(
            fileName: datedFileName,
            createdTime: nil,
            sub: "sub-1",
            candidates: [weakSameAccount, strongOtherAccount]
        )

        guard case .merge(let meetingID, _) = disposition else {
            return XCTFail("expected merge, got \(disposition)")
        }
        XCTAssertEqual(meetingID, strongOtherAccount.id)
    }

    /// Back-to-back recurring occurrences (the review's D-D4 ordering ruling): yesterday's
    /// same-account "Weekly sync" still qualifies at 23 h distance (~0.66), but today's unlinked
    /// occurrence scores ~1.0 — a gap far beyond the near-tie band, so score dominates and
    /// affinity must NOT redirect the transcript into the wrong occurrence.
    func testScoreDominatesAffinityBeyondTheNearTieBand() {
        let yesterdaySameAccount = DriveTranscriptMatcher.Candidate(
            title: "Weekly sync",
            startDate: embeddedDate.addingTimeInterval(-23 * 60 * 60),
            calendarEventID: "google:sub-1:evt-yesterday"
        )
        let todayUnlinked = DriveTranscriptMatcher.Candidate(
            title: "Weekly sync",
            startDate: embeddedDate
        )

        let disposition = DriveTranscriptMatcher.disposition(
            fileName: datedFileName,
            createdTime: nil,
            sub: "sub-1",
            candidates: [yesterdaySameAccount, todayUnlinked]
        )

        guard case .merge(let meetingID, let score) = disposition else {
            return XCTFail("expected merge, got \(disposition)")
        }
        XCTAssertEqual(meetingID, todayUnlinked.id, "score gap > 0.05 must be decided by score alone")
        XCTAssertEqual(score, 1.0, accuracy: 0.0001)
    }

    /// The segment-count rung is gone (review fix — reading `Meeting.segments.count` faulted every
    /// segment of every meeting per imported file). What is left must still be *stable*: a fully
    /// tied pair resolves to the same meeting regardless of the input order.
    func testRemainingTiesResolveDeterministically() {
        let first = DriveTranscriptMatcher.Candidate(title: "Weekly sync", startDate: embeddedDate)
        let second = DriveTranscriptMatcher.Candidate(title: "Weekly sync", startDate: embeddedDate)

        func winner(_ candidates: [DriveTranscriptMatcher.Candidate]) -> UUID? {
            guard case .merge(let meetingID, _) = DriveTranscriptMatcher.disposition(
                fileName: datedFileName, createdTime: nil, sub: "sub-1", candidates: candidates
            ) else { return nil }
            return meetingID
        }

        let forward = winner([first, second])
        XCTAssertNotNil(forward)
        XCTAssertEqual(forward, winner([second, first]), "the tie-break must not depend on order")
    }

    // MARK: - Date fallback (filename date, else Drive createdTime)

    func testNoDateFilenameFallsBackToCreatedTimeForMatching() {
        let createdTime = embeddedDate
        let candidate = DriveTranscriptMatcher.Candidate(title: "Weekly sync", startDate: createdTime)

        let disposition = DriveTranscriptMatcher.disposition(
            fileName: "Weekly sync",
            createdTime: createdTime,
            sub: "sub-1",
            candidates: [candidate]
        )

        guard case .merge(let meetingID, _) = disposition else {
            return XCTFail("expected merge, got \(disposition)")
        }
        XCTAssertEqual(meetingID, candidate.id)
    }

    func testNoDateFilenameCreatesDatedFromCreatedTime() {
        let createdTime = embeddedDate
        let disposition = DriveTranscriptMatcher.disposition(
            fileName: "Weekly sync", createdTime: createdTime, sub: "sub-1", candidates: []
        )
        XCTAssertEqual(disposition, .create(title: "Weekly sync", startDate: createdTime))
    }

    func testNoDateAnywhereCreatesUndated() {
        let inWindowNever = DriveTranscriptMatcher.Candidate(title: "Weekly sync", startDate: embeddedDate)
        let disposition = DriveTranscriptMatcher.disposition(
            fileName: "Weekly sync", createdTime: nil, sub: "sub-1", candidates: [inWindowNever]
        )
        XCTAssertEqual(disposition, .create(title: "Weekly sync", startDate: nil))
    }
}
