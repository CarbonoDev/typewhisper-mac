import Foundation

struct SpeakerSegment {
    let start: TimeInterval
    let end: TimeInterval
    let speaker: String
}

protocol DiarizationProvider {
    var isAvailable: Bool { get async }
    func diarize(wavData: Data, numSpeakers: Int?) async throws -> [SpeakerSegment]
}

enum DiarizationError: Error, LocalizedError {
    case providerUnavailable
    case sidecarNotFound(path: String)
    case pythonError(String)
    case invalidOutput

    var errorDescription: String? {
        switch self {
        case .providerUnavailable: return "Diarization provider is not available"
        case .sidecarNotFound(let p): return "Diarization sidecar not found at: \(p)"
        case .pythonError(let msg): return "Python error: \(msg)"
        case .invalidOutput: return "Diarization returned invalid output"
        }
    }
}
