import XCTest
@testable import TypeWhisper

/// [Track C] Final re-transcription policy precedence, guards, and Codable (addendum AD8).
final class FinalRetranscriptionResolutionTests: XCTestCase {
    // MARK: - Precedence: per-meeting → rule → global → default

    func testPerMeetingWins() {
        let resolved = FinalRetranscriptionPolicy.resolve(
            perMeeting: .off,
            rule: .engine(id: "a", model: nil),
            global: .sameEngine
        )
        XCTAssertEqual(resolved, .off)
    }

    func testRuleWinsWhenNoPerMeeting() {
        let resolved = FinalRetranscriptionPolicy.resolve(
            perMeeting: nil,
            rule: .engine(id: "assemblyai", model: "best"),
            global: .sameEngine
        )
        XCTAssertEqual(resolved, .engine(id: "assemblyai", model: "best"))
    }

    func testGlobalWinsWhenNoPerMeetingOrRule() {
        let resolved = FinalRetranscriptionPolicy.resolve(perMeeting: nil, rule: nil, global: .off)
        XCTAssertEqual(resolved, .off)
    }

    func testDefaultsToSameEngine() {
        let resolved = FinalRetranscriptionPolicy.resolve(perMeeting: nil, rule: nil, global: nil)
        XCTAssertEqual(resolved, .sameEngine)
    }

    // MARK: - Execution guards

    func testOffKeepsLiveSegments() {
        let plan = FinalRetranscriptionPolicy.plan(
            for: .off,
            durationSeconds: 60,
            isEngineAvailable: { _ in true },
            isCloudEngine: { _ in false }
        )
        XCTAssertEqual(plan, .init(execution: .keepLiveSegments, degraded: false))
    }

    func testSameEnginePlan() {
        let plan = FinalRetranscriptionPolicy.plan(
            for: .sameEngine,
            durationSeconds: 60,
            isEngineAvailable: { _ in false },
            isCloudEngine: { _ in true }
        )
        XCTAssertEqual(plan, .init(execution: .sameEngine, degraded: false))
    }

    func testEngineAvailablePassesThrough() {
        let plan = FinalRetranscriptionPolicy.plan(
            for: .engine(id: "assemblyai", model: "best"),
            durationSeconds: 60,
            isEngineAvailable: { $0 == "assemblyai" },
            isCloudEngine: { _ in true }
        )
        XCTAssertEqual(plan, .init(execution: .engine(id: "assemblyai", model: "best"), degraded: false))
    }

    func testUnavailableEngineDegradesToSameEngine() {
        let plan = FinalRetranscriptionPolicy.plan(
            for: .engine(id: "assemblyai", model: nil),
            durationSeconds: 60,
            isEngineAvailable: { _ in false },
            isCloudEngine: { _ in true }
        )
        XCTAssertEqual(plan, .init(execution: .sameEngine, degraded: true))
    }

    func testOversizedCloudAudioDegrades() {
        let plan = FinalRetranscriptionPolicy.plan(
            for: .engine(id: "assemblyai", model: nil),
            durationSeconds: 3 * 3600, // 3 h > 2 h ceiling
            cloudCeilingSeconds: FinalRetranscriptionPolicy.defaultCloudCeilingSeconds,
            isEngineAvailable: { _ in true },
            isCloudEngine: { _ in true }
        )
        XCTAssertEqual(plan, .init(execution: .sameEngine, degraded: true))
    }

    func testOversizedLocalEngineDoesNotDegrade() {
        // A *local* engine has no cloud ceiling.
        let plan = FinalRetranscriptionPolicy.plan(
            for: .engine(id: "parakeet", model: nil),
            durationSeconds: 5 * 3600,
            isEngineAvailable: { _ in true },
            isCloudEngine: { _ in false }
        )
        XCTAssertEqual(plan, .init(execution: .engine(id: "parakeet", model: nil), degraded: false))
    }

    // MARK: - Codable round-trips

    func testJSONRoundTripAllCases() {
        for policy in [FinalRetranscriptionPolicy.off, .sameEngine,
                       .engine(id: "assemblyai", model: "best"), .engine(id: "x", model: nil)] {
            let json = policy.jsonString
            XCTAssertNotNil(json)
            XCTAssertEqual(FinalRetranscriptionPolicy(jsonString: json), policy)
        }
    }

    func testJSONNilAndGarbage() {
        XCTAssertNil(FinalRetranscriptionPolicy(jsonString: nil))
        XCTAssertNil(FinalRetranscriptionPolicy(jsonString: ""))
        XCTAssertNil(FinalRetranscriptionPolicy(jsonString: "not json"))
    }

    // MARK: - Discrete-key init (global default storage)

    func testDiscreteKeyInit() {
        XCTAssertEqual(FinalRetranscriptionPolicy(mode: "off", engineId: nil, model: nil), .off)
        XCTAssertEqual(FinalRetranscriptionPolicy(mode: "sameEngine", engineId: nil, model: nil), .sameEngine)
        XCTAssertEqual(
            FinalRetranscriptionPolicy(mode: "engine", engineId: "assemblyai", model: "best"),
            .engine(id: "assemblyai", model: "best")
        )
        // engine mode with a blank model → nil model.
        XCTAssertEqual(
            FinalRetranscriptionPolicy(mode: "engine", engineId: "x", model: "  "),
            .engine(id: "x", model: nil)
        )
        // engine mode without an id → invalid.
        XCTAssertNil(FinalRetranscriptionPolicy(mode: "engine", engineId: nil, model: nil))
        XCTAssertNil(FinalRetranscriptionPolicy(mode: nil, engineId: nil, model: nil))
    }
}
