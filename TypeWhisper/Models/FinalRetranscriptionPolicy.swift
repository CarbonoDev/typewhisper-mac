import Foundation

/// How a meeting's *final* (post-stop) transcript is produced from the recorded audio buffer
/// (addendum AD8). During capture the live-stabilized segments already exist as the failure
/// fallback (v1 D3); this policy controls the single re-transcription point in
/// `MeetingCaptureService.finalizeSegments`.
///
/// - `.off`: skip re-transcription entirely and keep the live-stabilized `.liveCapture` segments.
/// - `.sameEngine`: today's behavior — re-transcribe the full buffer with the Recorder's engine
///   defaults.
/// - `.engine(id, model)`: re-transcribe on a specific override engine (canonical: a fast local
///   engine live + a higher-quality cloud engine such as AssemblyAI for the final pass).
///
/// `Codable`/`Sendable` so it round-trips through the per-meeting `Meeting.finalRetranscriptionRaw`
/// JSON column, a rule's `MeetingRuleActions`, and the global UserDefaults default.
enum FinalRetranscriptionPolicy: Equatable, Sendable, Codable {
    case off
    case sameEngine
    case engine(id: String, model: String?)

    // MARK: - Codable (explicit, tolerant of missing optionals — mirrors AD3 discipline)

    private enum CodingKeys: String, CodingKey {
        case mode
        case engineId
        case model
    }

    private enum Mode: String, Codable {
        case off
        case sameEngine
        case engine
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let mode = try container.decode(Mode.self, forKey: .mode)
        switch mode {
        case .off:
            self = .off
        case .sameEngine:
            self = .sameEngine
        case .engine:
            let id = try container.decode(String.self, forKey: .engineId)
            let model = try container.decodeIfPresent(String.self, forKey: .model)
            self = .engine(id: id, model: model)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .off:
            try container.encode(Mode.off, forKey: .mode)
        case .sameEngine:
            try container.encode(Mode.sameEngine, forKey: .mode)
        case .engine(let id, let model):
            try container.encode(Mode.engine, forKey: .mode)
            try container.encode(id, forKey: .engineId)
            try container.encodeIfPresent(model, forKey: .model)
        }
    }

    // MARK: - JSON round-trip helpers (per-meeting column + global default storage)

    /// Encode to a compact JSON string for `Meeting.finalRetranscriptionRaw` / UserDefaults.
    var jsonString: String? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Decode from a JSON string; `nil`/empty/garbage yields `nil` (meaning "inherit").
    init?(jsonString: String?) {
        guard let jsonString,
              !jsonString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let data = jsonString.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(FinalRetranscriptionPolicy.self, from: data) else {
            return nil
        }
        self = decoded
    }

    /// Build from the discrete global-default UserDefaults keys (`meetings.finalPass.defaultMode`
    /// + engine/model). Returns `nil` when unset/invalid (meaning "no global default configured").
    init?(mode: String?, engineId: String?, model: String?) {
        guard let mode = mode?.trimmingCharacters(in: .whitespacesAndNewlines), !mode.isEmpty else {
            return nil
        }
        switch mode {
        case "off":
            self = .off
        case "sameEngine":
            self = .sameEngine
        case "engine":
            guard let engineId = engineId?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !engineId.isEmpty else {
                return nil
            }
            let trimmedModel = model?.trimmingCharacters(in: .whitespacesAndNewlines)
            self = .engine(id: engineId, model: (trimmedModel?.isEmpty == false) ? trimmedModel : nil)
        default:
            return nil
        }
    }

    /// The discrete-key `mode` string for `meetings.finalPass.defaultMode`.
    var modeRawValue: String {
        switch self {
        case .off: return "off"
        case .sameEngine: return "sameEngine"
        case .engine: return "engine"
        }
    }

    // MARK: - Precedence resolution (per-meeting → rule → global → default)

    /// Resolve the effective policy from the layered sources (addendum AD8). The first non-nil
    /// layer wins; `.sameEngine` is the ultimate default so a v1 meeting with no configuration
    /// behaves exactly as before.
    static func resolve(
        perMeeting: FinalRetranscriptionPolicy?,
        rule: FinalRetranscriptionPolicy?,
        global: FinalRetranscriptionPolicy?
    ) -> FinalRetranscriptionPolicy {
        perMeeting ?? rule ?? global ?? .sameEngine
    }

    // MARK: - Execution planning with availability + cloud-ceiling guards

    /// What `finalizeSegments` should actually do after applying the AD8 safety guards.
    enum Execution: Equatable, Sendable {
        /// Skip re-transcription; keep the persisted live-stabilized segments.
        case keepLiveSegments
        /// Re-transcribe the full buffer with the Recorder's engine defaults.
        case sameEngine
        /// Re-transcribe the full buffer on a specific override engine/model.
        case engine(id: String, model: String?)
    }

    struct Plan: Equatable, Sendable {
        var execution: Execution
        /// True when a requested override engine could not be honored and the plan degraded to a
        /// safer path (surfaced via the capture status/degraded indicator, never an error dialog).
        var degraded: Bool
    }

    /// Conservative default cloud audio ceiling: ~2 h of 16 kHz mono audio (2 * 3600 * 16000
    /// samples). Beyond this a cloud override degrades to `.sameEngine` to avoid pushing a
    /// 200 MB+ payload at a metered endpoint (addendum AD8).
    static let defaultCloudCeilingSeconds: Double = 2 * 3600

    /// Turn a resolved policy into an executable plan, degrading unavailable/oversized cloud
    /// overrides. Pure and fully injectable so it is unit-testable without a live `ModelManager`.
    ///
    /// - Parameters:
    ///   - durationSeconds: duration of the captured buffer being finalized.
    ///   - cloudCeilingSeconds: max cloud audio duration before degrading (see `defaultCloudCeilingSeconds`).
    ///   - isEngineAvailable: whether the override engine id is currently selectable/loadable.
    ///   - isCloudEngine: whether the override engine id is a metered/cloud engine.
    static func plan(
        for policy: FinalRetranscriptionPolicy,
        durationSeconds: Double,
        cloudCeilingSeconds: Double = defaultCloudCeilingSeconds,
        isEngineAvailable: (String) -> Bool,
        isCloudEngine: (String) -> Bool
    ) -> Plan {
        switch policy {
        case .off:
            return Plan(execution: .keepLiveSegments, degraded: false)
        case .sameEngine:
            return Plan(execution: .sameEngine, degraded: false)
        case .engine(let id, let model):
            guard isEngineAvailable(id) else {
                return Plan(execution: .sameEngine, degraded: true)
            }
            if isCloudEngine(id), durationSeconds > cloudCeilingSeconds {
                return Plan(execution: .sameEngine, degraded: true)
            }
            return Plan(execution: .engine(id: id, model: model), degraded: false)
        }
    }
}
