import Foundation
import TypeWhisperPluginSDK
import os.log

private let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "TypeWhisper",
    category: "LocalDiarization"
)

/// Adds speaker labels to a transcription result using a local diarization
/// provider, when the transcription engine did not already produce them.
@MainActor
final class LocalDiarizationService {
    static let shared = LocalDiarizationService()

    private let enabledKey = "diarization.enabled"
    private let numSpeakersKey = "diarization.numSpeakers"

    nonisolated let provider: DiarizationProvider

    var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    /// Desired speaker count, or `nil` for automatic detection (stored as 0).
    var numSpeakers: Int? {
        get {
            let value = UserDefaults.standard.integer(forKey: numSpeakersKey)
            return value > 0 ? value : nil
        }
        set { UserDefaults.standard.set(newValue ?? 0, forKey: numSpeakersKey) }
    }

    init(provider: DiarizationProvider = PyannoteDiarizationProvider()) {
        self.provider = provider
    }

    /// Enriches `result` with speaker labels. Safe to call from any actor.
    ///
    /// Returns the input unchanged when diarization is disabled, when the
    /// transcription already carries speaker labels, or when the provider fails
    /// (diarization is best-effort and must never drop a transcription).
    nonisolated func enrich(
        result: PluginStructuredTranscriptionResult,
        audio: AudioData
    ) async -> PluginStructuredTranscriptionResult {
        guard !result.segments.isEmpty else { return result }

        let alreadyLabeled = result.segments.allSatisfy { $0.speakerLabel != nil }
        if alreadyLabeled { return result }

        let config = await MainActor.run { (isEnabled: isEnabled, numSpeakers: numSpeakers) }
        guard config.isEnabled else { return result }

        do {
            let diarSegments = try await provider.diarize(
                wavData: audio.wavData,
                numSpeakers: config.numSpeakers
            )
            guard !diarSegments.isEmpty else { return result }

            let enrichedSegments = Self.assignSpeakers(to: result.segments, from: diarSegments)
            return PluginStructuredTranscriptionResult(
                text: result.text,
                detectedLanguage: result.detectedLanguage,
                segments: enrichedSegments
            )
        } catch {
            logger.error("Diarization failed, returning unlabeled result: \(error.localizedDescription, privacy: .public)")
            return result
        }
    }

    /// Assigns each transcription segment the speaker of the diarization
    /// segment it overlaps with most in time.
    nonisolated static func assignSpeakers(
        to segments: [PluginStructuredTranscriptionSegment],
        from diarSegments: [SpeakerSegment]
    ) -> [PluginStructuredTranscriptionSegment] {
        segments.map { segment in
            guard let best = bestOverlap(for: segment, in: diarSegments) else {
                return segment
            }
            return PluginStructuredTranscriptionSegment(
                text: segment.text,
                start: segment.start,
                end: segment.end,
                speakerLabel: best.speaker,
                speakerConfidence: best.confidence
            )
        }
    }

    private nonisolated static func bestOverlap(
        for segment: PluginStructuredTranscriptionSegment,
        in diarSegments: [SpeakerSegment]
    ) -> (speaker: String, confidence: Double)? {
        let segmentDuration = max(segment.end - segment.start, 0)

        var bestSpeaker: String?
        var bestOverlap: TimeInterval = 0
        for diar in diarSegments {
            let overlap = min(segment.end, diar.end) - max(segment.start, diar.start)
            if overlap > bestOverlap {
                bestOverlap = overlap
                bestSpeaker = diar.speaker
            }
        }

        guard let bestSpeaker, bestOverlap > 0 else { return nil }
        let confidence = segmentDuration > 0 ? min(bestOverlap / segmentDuration, 1) : 1
        return (bestSpeaker, confidence)
    }
}
