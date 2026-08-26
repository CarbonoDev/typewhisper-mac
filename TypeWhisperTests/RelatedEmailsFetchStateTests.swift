import XCTest
@testable import TypeWhisper

/// `RelatedEmailsModel` — the VM-owned related-emails fetch state ([Google Phase 3 · M5], D-M6)
/// over a stub `RelatedEmailsProviding`: fetch populates rows, errors are captured and cleared,
/// refresh bypasses the cache path, per-meeting isolation, not-connected no-op, and the
/// partial-error fallback.
@MainActor
final class RelatedEmailsFetchStateTests: XCTestCase {
    @MainActor
    private final class StubProvider: RelatedEmailsProviding {
        var connected = true
        var result: Result<[EmailCandidate], Error> = .success([])
        var partialErrors: [UUID: String] = [:]
        private(set) var candidatesCalls = 0
        private(set) var refreshCalls = 0

        func isConnected(for meeting: Meeting) -> Bool { connected }
        func candidates(for meeting: Meeting) async throws -> [EmailCandidate] {
            candidatesCalls += 1
            return try result.get()
        }
        func refresh(for meeting: Meeting) async throws -> [EmailCandidate] {
            refreshCalls += 1
            return try result.get()
        }
        func lastPartialError(for meeting: Meeting) -> String? { partialErrors[meeting.id] }
    }

    private let fixedNow = Date(timeIntervalSince1970: 1_786_399_200)

    private func candidate(id: String = "google:subA:m1", sub: String = "subA") -> EmailCandidate {
        EmailCandidate(
            id: id, messageID: String(id.split(separator: ":").last ?? "m"), accountSub: sub,
            accountEmail: "\(sub)@example.com", threadID: "t-\(id)", subject: "S", from: "A <a@x.com>",
            date: fixedNow, snippet: "s"
        )
    }

    private func makeModel(provider: StubProvider) -> RelatedEmailsModel {
        RelatedEmailsModel(provider: provider, now: { self.fixedNow })
    }

    func testFetchPopulatesRowsAndUpdatedAtAndClearsSpinner() async {
        let provider = StubProvider()
        provider.result = .success([candidate()])
        let model = makeModel(provider: provider)
        let meeting = Meeting(title: "M")

        await model.fetch(for: meeting)

        XCTAssertEqual(model.rows(for: meeting).map(\.id), ["google:subA:m1"])
        XCTAssertEqual(model.updatedAt(for: meeting), fixedNow)
        XCTAssertFalse(model.isFetching(for: meeting))
        XCTAssertNil(model.lastFetchError(for: meeting))
        XCTAssertEqual(provider.candidatesCalls, 1)
        XCTAssertEqual(provider.refreshCalls, 0)
    }

    func testRefreshUsesTheCacheBypassingPath() async {
        let provider = StubProvider()
        provider.result = .success([candidate()])
        let model = makeModel(provider: provider)
        let meeting = Meeting(title: "M")

        await model.refresh(for: meeting)

        XCTAssertEqual(provider.refreshCalls, 1, "refresh routes to the service's cache-bypassing variant")
        XCTAssertEqual(provider.candidatesCalls, 0)
        XCTAssertEqual(model.rows(for: meeting).count, 1)
    }

    func testThrownFetchIsCapturedAndClearedByTheNextSuccess() async {
        let provider = StubProvider()
        provider.result = .failure(URLError(.notConnectedToInternet))
        let model = makeModel(provider: provider)
        let meeting = Meeting(title: "M")

        await model.fetch(for: meeting)
        XCTAssertNotNil(model.lastFetchError(for: meeting))
        XCTAssertTrue(model.rows(for: meeting).isEmpty)

        provider.result = .success([candidate()])
        await model.refresh(for: meeting)
        XCTAssertNil(model.lastFetchError(for: meeting), "a clean fetch clears the captured error")
        XCTAssertEqual(model.rows(for: meeting).count, 1)
    }

    func testPerMeetingIsolation() async {
        let provider = StubProvider()
        provider.result = .success([candidate()])
        let model = makeModel(provider: provider)
        let meetingA = Meeting(title: "A")
        let meetingB = Meeting(title: "B")

        await model.fetch(for: meetingA)
        provider.result = .failure(URLError(.timedOut))
        await model.fetch(for: meetingB)

        XCTAssertEqual(model.rows(for: meetingA).count, 1, "B's failure never touches A's rows")
        XCTAssertNil(model.lastFetchError(for: meetingA))
        XCTAssertTrue(model.rows(for: meetingB).isEmpty)
        XCTAssertNotNil(model.lastFetchError(for: meetingB))
    }

    func testNotConnectedIsANoOp() async {
        let provider = StubProvider()
        provider.connected = false
        provider.result = .success([candidate()])
        let model = makeModel(provider: provider)
        let meeting = Meeting(title: "M")

        await model.fetch(for: meeting)

        XCTAssertEqual(provider.candidatesCalls, 0, "no fetch while Gmail is not connected for the meeting")
        XCTAssertTrue(model.rows(for: meeting).isEmpty)
    }

    func testNilProviderIsInert() async {
        let model = RelatedEmailsModel(provider: nil, now: { self.fixedNow })
        let meeting = Meeting(title: "M")
        await model.fetch(for: meeting)
        XCTAssertTrue(model.rows(for: meeting).isEmpty)
        XCTAssertNil(model.lastFetchError(for: meeting))
    }

    // MARK: - Connectivity flips (review findings: no refetch on enable, stale rows on disable)

    func testConnectFlipRefetchesAMeetingWhoseLoadEarlyReturned() async {
        // The section's `.task(id: meeting.id)` ran while Gmail was off and early-returned; the task
        // id never changes for an already-open document, so the flip is the only chance to fetch.
        let provider = StubProvider()
        provider.connected = false
        provider.result = .success([candidate()])
        let model = makeModel(provider: provider)
        let meeting = Meeting(title: "M")

        await model.fetch(for: meeting)
        XCTAssertEqual(provider.candidatesCalls, 0)

        provider.connected = true
        await model.connectionDidChange(isConnected: true)

        XCTAssertEqual(provider.candidatesCalls, 1, "the enable flip re-triggers the load")
        XCTAssertEqual(model.rows(for: meeting).map(\.id), ["google:subA:m1"])
        XCTAssertEqual(model.updatedAt(for: meeting), fixedNow)
    }

    func testDisconnectClearsCachedRowsSoTheAppendixGateAgreesWithTheSection() async {
        // The appendix gate is `isGmailConnected || !rows.isEmpty`: rows that outlive the toggle
        // keep a count badge over a section that renders only the "enable Gmail" hint.
        let provider = StubProvider()
        provider.result = .success([candidate(), candidate(id: "google:subA:m2")])
        let model = makeModel(provider: provider)
        let meeting = Meeting(title: "M")
        provider.partialErrors[meeting.id] = nil

        await model.fetch(for: meeting)
        XCTAssertEqual(model.rows(for: meeting).count, 2)

        provider.connected = false
        await model.connectionDidChange(isConnected: false)

        XCTAssertTrue(model.rows(for: meeting).isEmpty, "rows dropped on disable/disconnect")
        XCTAssertNil(model.updatedAt(for: meeting))
        XCTAssertNil(model.lastFetchError(for: meeting))
    }

    func testReconnectAfterDisconnectRefillsTheClearedRows() async {
        let provider = StubProvider()
        provider.result = .success([candidate()])
        let model = makeModel(provider: provider)
        let meeting = Meeting(title: "M")

        await model.fetch(for: meeting)
        provider.connected = false
        await model.connectionDidChange(isConnected: false)
        XCTAssertTrue(model.rows(for: meeting).isEmpty)

        provider.connected = true
        await model.connectionDidChange(isConnected: true)

        XCTAssertEqual(model.rows(for: meeting).count, 1, "the meeting stays tracked across the off/on cycle")
    }

    func testPartialErrorSurfacesThroughLastFetchError() async {
        // D-M6: a partially failed multi-account fetch succeeds (merged remainder cached) but
        // must still surface — the model falls back to the service's per-meeting lastPartialError.
        let provider = StubProvider()
        provider.result = .success([candidate()])
        let model = makeModel(provider: provider)
        let meeting = Meeting(title: "M")
        provider.partialErrors[meeting.id] = "subB@example.com: HTTP 500"

        await model.fetch(for: meeting)

        XCTAssertEqual(model.rows(for: meeting).count, 1)
        XCTAssertEqual(model.lastFetchError(for: meeting), "subB@example.com: HTTP 500")
    }
}
