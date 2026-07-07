import Foundation
import AVFoundation
import TypeWhisperPluginSDK
import os.log

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "TypeWhisper", category: "MeetingDiarizationEnricher")

/// A single segment→speaker assignment produced by enrichment, applied by `MeetingService`.
struct MeetingSpeakerAssignment: Sendable, Equatable {
    let segmentID: UUID
    let label: String
    let confidence: Double?
}

/// Raw audio a meeting's stored recording decodes to, for diarization. `channels` holds one Float
/// array per channel. A channel count of two does **not** imply separate mic/system tracks: the
/// recorder writes 2-channel files for its *mixed* mode too (both channels carry the same mic+system
/// mix). Whether the two tracks are genuinely distinct is decided by an inter-channel decorrelation
/// probe (`channelsAreDecorrelated`), not by the channel count.
struct MeetingAudioData: Sendable {
    let channels: [[Float]]
    let sampleRate: Double
}

/// A value-typed transcript segment time range, so the off-main enrichment path takes no SwiftData
/// models (`MeetingSegment` is `@MainActor`-bound) across actor boundaries.
struct MeetingSegmentTimeRange: Sendable {
    let id: UUID
    let start: Double
    let end: Double
}

/// Opens a meeting's stored audio for diarization. Injected so tests can supply synthetic channels
/// without a real audio file or AVFoundation.
protocol MeetingAudioInspecting: Sendable {
    /// Cheap channel-count probe (reads the file header only) used for availability gating.
    func channelCount(at url: URL) throws -> Int
    /// Full decode into per-channel Float samples.
    func load(at url: URL) throws -> MeetingAudioData
    /// Decode only the recording's first `maxFrames` frames, for the cheap correlation probe that
    /// lets `enrich` reject a mixed-mode live capture without a sidecar *before* the whole-file
    /// decode. Reads the head only, never the entire (possibly multi-GB) recording.
    func loadPrefix(at url: URL, maxFrames: Int) throws -> MeetingAudioData
}

extension MeetingAudioInspecting {
    /// Default: decode the whole file and truncate. Correct but not cheap — conformers backed by a
    /// real audio file (`AVAudioFileInspector`) override this with a genuinely bounded read; the
    /// fallback exists so in-memory test inspectors need not reimplement it.
    func loadPrefix(at url: URL, maxFrames: Int) throws -> MeetingAudioData {
        let full = try load(at: url)
        return MeetingAudioData(channels: full.channels.map { Array($0.prefix(maxFrames)) },
                                sampleRate: full.sampleRate)
    }
}

/// Default `MeetingAudioInspecting` backed by `AVAudioFile` (deinterleaved Float channel data).
struct AVAudioFileInspector: MeetingAudioInspecting {
    func channelCount(at url: URL) throws -> Int {
        let file = try AVAudioFile(forReading: url)
        return Int(file.processingFormat.channelCount)
    }

    func load(at url: URL) throws -> MeetingAudioData {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let frameCount = AVAudioFrameCount(file.length)
        guard frameCount > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            return MeetingAudioData(channels: [], sampleRate: format.sampleRate)
        }
        try file.read(into: buffer)
        guard let floatData = buffer.floatChannelData else {
            return MeetingAudioData(channels: [], sampleRate: format.sampleRate)
        }
        let frames = Int(buffer.frameLength)
        let channelCount = Int(format.channelCount)
        var channels: [[Float]] = []
        channels.reserveCapacity(channelCount)
        for channel in 0..<channelCount {
            channels.append(Array(UnsafeBufferPointer(start: floatData[channel], count: frames)))
        }
        return MeetingAudioData(channels: channels, sampleRate: format.sampleRate)
    }

    func loadPrefix(at url: URL, maxFrames: Int) throws -> MeetingAudioData {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let available = AVAudioFrameCount(max(0, file.length))
        let wanted = AVAudioFrameCount(max(0, maxFrames))
        let frameCount = min(available, wanted)
        guard frameCount > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            return MeetingAudioData(channels: [], sampleRate: format.sampleRate)
        }
        try file.read(into: buffer, frameCount: frameCount)
        guard let floatData = buffer.floatChannelData else {
            return MeetingAudioData(channels: [], sampleRate: format.sampleRate)
        }
        let frames = Int(buffer.frameLength)
        let channelCount = Int(format.channelCount)
        var channels: [[Float]] = []
        channels.reserveCapacity(channelCount)
        for channel in 0..<channelCount {
            channels.append(Array(UnsafeBufferPointer(start: floatData[channel], count: frames)))
        }
        return MeetingAudioData(channels: channels, sampleRate: format.sampleRate)
    }
}

/// Post-finalize, opt-in speaker diarization for a completed meeting (plan M9 / D8).
///
/// Runs the local pyannote diarization provider over the meeting's stored audio and assigns
/// `SPEAKER_xx` labels to the transcript segments by time overlap — reusing
/// `LocalDiarizationService.assignSpeakers`, the same engine-agnostic overlap matcher the recorder
/// path uses. Unlike `LocalDiarizationService.enrich`, which swallows every failure and returns the
/// unlabeled result, this surfaces outcomes **explicitly** (plan D8): a provider that ran but found
/// nothing yields `.noSpeakersDetected` (distinct from a provider error, which throws), so the UI
/// can show an honest "no speakers detected" state.
///
/// **Separate-track heuristic (offline, no sidecar).** The recorder can write a two-channel file in
/// two very different layouts: *separate* mode (L = mic, R = system — the two tracks are genuinely
/// distinct) and *mixed* mode (both channels carry the same mic+system mix). Channel count alone
/// therefore cannot tell them apart, so this class runs the cheap Me/Others RMS heuristic **only**
/// when (a) the meeting is a live capture (`.adHoc`/`.calendar` — imported audio is never
/// separate-track) and (b) the two channels are measurably decorrelated. Otherwise the audio is
/// downmixed to mono and the pyannote path is used (and the feature is hidden when the sidecar is
/// unavailable).
///
/// **Off-main decode.** The whole-file decode, per-segment RMS, and WAV encoding run on a
/// nonisolated helper (`prepare`) so the feature's primary action never blocks the main actor with a
/// multi-GB decode of a long meeting; only the SwiftData writes happen back on the main actor.
@MainActor
final class MeetingDiarizationEnricher: ObservableObject {
    /// Separate-track heuristic labels; both seeded into `speakerMap` with localized default names.
    /// `nonisolated` so the off-main assignment helper can reference them.
    nonisolated static let micSpeakerLabel = "SPEAKER_ME"
    nonisolated static let systemSpeakerLabel = "SPEAKER_OTHERS"

    /// Segment/audio timelines that diverge by more than this many seconds are treated as a
    /// mismatch (restarted-session or merged-meeting flows point `audioFileName` at audio whose
    /// 0-based timeline does not match the stored segment times — labeling would be wrong).
    private static let timelineToleranceSeconds = 2.0

    /// Minimum normalized inter-channel difference energy `Σ(L−R)² / Σ(L²+R²)` for two channels to
    /// count as separate tracks. Genuine separate-mode files (L = mic only, R = system only — disjoint
    /// signals) score ~1.0 even with speaker bleed; identical mixed-mode channels score ~0. The
    /// discriminating middle is the mixed-mode file with *stereo* system content: the recorder writes
    /// L = mic + sysL, R = mic + sysR, whose normalized difference energy is `2S²/(M²+S²)` — already
    /// ~0.08 at just 20% side amplitude, and higher for wider stereo. A threshold near 0.01 misclassifies
    /// those live mixed-mode captures (shared video/music, stereo conferencing output) as separate-track
    /// and pins near-arbitrary Me/Others labels; a robust midpoint keeps them on the mono/provider path
    /// while still admitting genuinely disjoint tracks.
    private static let decorrelationThreshold = 0.35

    /// Frames of the recording's head decoded for the cheap availability/short-circuit correlation
    /// probe (~10 s at 48 kHz), so a mixed-mode live capture without a sidecar can be rejected before
    /// the whole-file decode instead of after it. Bounded so it never reads a multi-hour recording.
    private static let probeFrameCount = 480_000

    /// Mean per-sample inter-channel energy `(L²+R²)` below which a prefix is treated as effectively
    /// silent — a silent head is inconclusive (a separate-track recording may simply open with
    /// silence), so the short-circuit defers to the authoritative whole-file check rather than
    /// misclassifying it. `nonisolated` so the off-main correlation helpers can reference it.
    private nonisolated static let silenceEnergyFloor = 1e-6

    /// Whether — and how — speaker identification can run for a given meeting.
    enum Availability: Equatable {
        /// No stored audio, or a mono recording with no diarization sidecar available.
        case unavailable
        /// A live-captured stereo recording: the offline heuristic may run without a sidecar (the
        /// authoritative separate-vs-mixed decision is deferred to `enrich`).
        case separateTrack
        /// A mono recording with the pyannote sidecar available.
        case provider
    }

    /// The result of an enrichment pass.
    enum Outcome: Equatable {
        /// Segments were labeled; `speakerCount` distinct speakers were assigned.
        case labeled(speakerCount: Int)
        /// The provider ran (or the heuristic found only silence) but produced zero labels (plan D8).
        case noSpeakersDetected
        /// The provider is unavailable and the recording is not separate-track.
        case unavailable
        /// The meeting has no stored audio to diarize.
        case noAudio
        /// The meeting has no transcript segments to label.
        case noTranscript
        /// The transcript timeline does not line up with the stored audio (restarted/merged flows),
        /// so labeling would attach wrong speakers — surfaced as a status, nothing is written.
        case timelineMismatch
    }

    enum EnrichError: LocalizedError, Equatable {
        /// An enrichment pass is already running on this service (re-entrancy guard).
        case alreadyEnriching
        /// Decoding the stored audio failed.
        case audioLoadFailed(String)
        /// The diarization provider failed (surfaced explicitly, not swallowed — plan D8).
        case providerFailed(String)

        var errorDescription: String? {
            switch self {
            case .alreadyEnriching:
                return String(localized: "meetings.diarization.error.alreadyEnriching")
            case .audioLoadFailed(let message):
                return String(format: String(localized: "meetings.diarization.error.audioLoad"), message)
            case .providerFailed(let message):
                return String(format: String(localized: "meetings.diarization.error.provider"), message)
            }
        }
    }

    /// Outcome of the off-main preparation pass: either the audio yielded separate-track assignments,
    /// or it was reduced to mono WAV data for the sidecar, or a pre-labeling guard fired.
    private enum Preparation: Sendable {
        case separateTrack([MeetingSpeakerAssignment])
        case mono(Data)
        case noAudio
        case timelineMismatch
    }

    @Published private(set) var isEnriching = false

    private let meetingService: MeetingService
    private let provider: DiarizationProvider
    private let audioInspector: MeetingAudioInspecting
    private let numSpeakersProvider: @MainActor () -> Int?

    init(
        meetingService: MeetingService,
        provider: DiarizationProvider = LocalDiarizationService.shared.provider,
        audioInspector: MeetingAudioInspecting = AVAudioFileInspector(),
        numSpeakersProvider: @escaping @MainActor () -> Int? = { LocalDiarizationService.shared.numSpeakers }
    ) {
        self.meetingService = meetingService
        self.provider = provider
        self.audioInspector = audioInspector
        self.numSpeakersProvider = numSpeakersProvider
    }

    // MARK: - Availability

    /// Whether speaker identification should be offered for `meeting`. Live-captured stereo
    /// recordings *may* carry separate mic/system tracks the offline heuristic can label without a
    /// sidecar (the genuine separate-vs-mixed check is deferred to `enrich`); everything else needs
    /// the pyannote sidecar; no audio means no action.
    func availability(for meeting: Meeting) async -> Availability {
        guard let url = meetingService.audioFileURL(for: meeting) else { return .unavailable }
        if Self.isLiveCaptured(meeting),
           let channels = try? audioInspector.channelCount(at: url), channels >= 2 {
            return .separateTrack
        }
        return await provider.isAvailable ? .provider : .unavailable
    }

    // MARK: - Enrichment

    /// Diarize `meeting`'s stored audio and persist speaker labels onto its segments. Returns an
    /// explicit `Outcome`; throws only on a hard error (audio decode / provider failure).
    @discardableResult
    func enrich(_ meeting: Meeting) async throws -> Outcome {
        guard !isEnriching else { throw EnrichError.alreadyEnriching }
        // Claim the flag *synchronously*, before any `await`, so two user-triggered passes can't both
        // slip past the guard (the availability/prefix probes below suspend) and run concurrent
        // whole-file decodes + `applySpeakerLabels` (finding 3). The synchronous early returns below
        // (.noTranscript/.noAudio) and the async .unavailable returns are all covered by the defer.
        isEnriching = true
        defer { isEnriching = false }

        let segments = meeting.segments.sorted { $0.order < $1.order }
        guard !segments.isEmpty else { return .noTranscript }
        guard let url = meetingService.audioFileURL(for: meeting) else { return .noAudio }

        let ranges = segments.map { MeetingSegmentTimeRange(id: $0.id, start: $0.start, end: $0.end) }
        let allowSeparateTrack = Self.isLiveCaptured(meeting)

        // Gate on provider availability *before* decoding, so an unavailable sidecar never triggers a
        // whole-file decode that can only end in `.unavailable`.
        if await provider.isAvailable == false {
            // Imported recordings are never separate-track → straight to the unavailable state.
            if !allowSeparateTrack { return .unavailable }
            // A live capture *might* carry separate mic/system tracks the offline heuristic can label
            // without a sidecar — but only if the channels are genuinely decorrelated. Probe a bounded
            // prefix: a mono file, or a mixed-mode capture whose head is confidently correlated (real,
            // non-silent audio mixed into both channels), has nowhere to go without a sidecar, so bail
            // before the multi-GB decode. A silent/inconclusive or decorrelated head falls through to
            // the authoritative whole-file check below (which may still find genuine separate tracks).
            if await Self.prefixIsDefinitelyNotSeparateTrack(
                inspector: audioInspector,
                url: url,
                maxFrames: Self.probeFrameCount,
                threshold: Self.decorrelationThreshold
            ) {
                return .unavailable
            }
        }

        // Off-main: decode, timeline-check, decide track mode, and either compute separate-track
        // assignments or produce mono WAV data — none of this touches the main actor.
        let preparation: Preparation
        do {
            preparation = try await Self.prepare(
                inspector: audioInspector,
                url: url,
                ranges: ranges,
                allowSeparateTrack: allowSeparateTrack,
                timelineTolerance: Self.timelineToleranceSeconds,
                decorrelationThreshold: Self.decorrelationThreshold
            )
        } catch {
            throw EnrichError.audioLoadFailed(error.localizedDescription)
        }

        switch preparation {
        case .noAudio:
            return .noAudio

        case .timelineMismatch:
            logger.warning("Meeting diarization skipped: transcript timeline does not match stored audio.")
            return .timelineMismatch

        case .separateTrack(let assignments):
            return applySeparateTrackAssignments(assignments, to: meeting)

        case .mono(let wavData):
            // A live recording that turned out to be mixed (correlated channels) lands here too;
            // it needs the sidecar, so gate on availability now that we know the layout.
            guard await provider.isAvailable else { return .unavailable }

            let diarSegments: [SpeakerSegment]
            do {
                diarSegments = try await Self.runDiarization(
                    provider: provider,
                    wavData: wavData,
                    numSpeakers: numSpeakersProvider()
                )
            } catch {
                logger.error("Meeting diarization failed: \(error.localizedDescription, privacy: .public)")
                throw EnrichError.providerFailed(error.localizedDescription)
            }

            // Provider ran but found nothing → explicit unlabeled state (plan D8), not a silent no-op.
            guard !diarSegments.isEmpty else { return .noSpeakersDetected }

            let assignments = Self.assign(ranges: ranges, from: diarSegments)
            guard !assignments.isEmpty else { return .noSpeakersDetected }

            meetingService.applySpeakerLabels(assignments, to: meeting)
            let distinct = Set(assignments.map(\.label))
            return .labeled(speakerCount: distinct.count)
        }
    }

    // MARK: - Separate-track heuristic

    /// Persist the separate-track assignments and seed the speaker map with localized default names
    /// (unless the user already renamed them). Runs on the main actor — the RMS work that produced
    /// `assignments` already happened off-main in `prepare`.
    private func applySeparateTrackAssignments(
        _ assignments: [MeetingSpeakerAssignment],
        to meeting: Meeting
    ) -> Outcome {
        guard !assignments.isEmpty else { return .noSpeakersDetected }

        var map = meeting.speakerMap
        let used = Set(assignments.map(\.label))
        if used.contains(Self.micSpeakerLabel), (map[Self.micSpeakerLabel] ?? "").isEmpty {
            map[Self.micSpeakerLabel] = String(localized: "meetings.diarization.speaker.me")
        }
        if used.contains(Self.systemSpeakerLabel), (map[Self.systemSpeakerLabel] ?? "").isEmpty {
            map[Self.systemSpeakerLabel] = String(localized: "meetings.diarization.speaker.others")
        }

        meetingService.applySpeakerLabels(assignments, speakerMap: map, to: meeting)
        return .labeled(speakerCount: used.count)
    }

    // MARK: - Off-main preparation

    /// Off-main audio work: decode, verify the transcript timeline against the audio duration, decide
    /// whether the recording is genuinely separate-track, and return either the separate-track
    /// assignments or the mono WAV data for the sidecar. Value-typed I/O only (`Sendable`), so it can
    /// hop off the main actor like `runDiarization`.
    private nonisolated static func prepare(
        inspector: MeetingAudioInspecting,
        url: URL,
        ranges: [MeetingSegmentTimeRange],
        allowSeparateTrack: Bool,
        timelineTolerance: Double,
        decorrelationThreshold: Double
    ) async throws -> Preparation {
        let audio = try inspector.load(at: url)

        let frames = audio.channels.map(\.count).max() ?? 0
        guard frames > 0, audio.sampleRate > 0 else { return .noAudio }

        // Guard against restarted-session / merged-meeting flows where the segment timeline no
        // longer indexes this audio file (plan reminder: labeling the wrong span persists wrong
        // speakers). Compare the transcript's extent to the audio duration.
        let audioDuration = Double(frames) / audio.sampleRate
        let transcriptEnd = ranges.map(\.end).max() ?? 0
        if transcriptEnd > audioDuration + timelineTolerance {
            return .timelineMismatch
        }

        // Genuine separate tracks only when this is a live capture AND the two channels are
        // measurably decorrelated (mixed-mode 2-channel files are identical → not separate).
        if allowSeparateTrack, audio.channels.count >= 2,
           channelsAreDecorrelated(audio.channels[0], audio.channels[1], threshold: decorrelationThreshold) {
            let assignments = separateTrackAssignments(
                mic: audio.channels[0],
                system: audio.channels[1],
                sampleRate: audio.sampleRate,
                ranges: ranges
            )
            return .separateTrack(assignments)
        }

        // Mono / sidecar path: downmix every channel to mono (identical mixed channels average to
        // themselves) and encode WAV off-main.
        let mono = downmixToMono(audio.channels, frames: frames)
        guard !mono.isEmpty else { return .noAudio }
        let sampleRate = Int(audio.sampleRate.rounded())
        return .mono(WavEncoder.encode(mono, sampleRate: sampleRate))
    }

    // MARK: - Pure helpers

    private static func isLiveCaptured(_ meeting: Meeting) -> Bool {
        meeting.source == .adHoc || meeting.source == .calendar
    }

    /// Average all channels into a single mono track. A cheap, correct reduction for both a true
    /// mono file (one channel) and a mixed-mode stereo file (two identical channels).
    nonisolated static func downmixToMono(_ channels: [[Float]], frames: Int) -> [Float] {
        guard !channels.isEmpty, frames > 0 else { return [] }
        if channels.count == 1 { return channels[0] }
        var mono = [Float](repeating: 0, count: frames)
        let scale = Float(1) / Float(channels.count)
        for channel in channels {
            let n = min(frames, channel.count)
            for index in 0..<n {
                mono[index] += channel[index] * scale
            }
        }
        return mono
    }

    /// Inter-channel energies over a bounded, strided sample window (so it stays cheap on multi-hour
    /// recordings): the difference energy `Σ(L−R)²`, the total energy `Σ(L²+R²)`, and the number of
    /// samples visited. Shared by the decorrelation and confident-correlation discriminators.
    private nonisolated static func interChannelEnergies(_ a: [Float], _ b: [Float]) -> (diff: Double, total: Double, samples: Int) {
        let count = min(a.count, b.count)
        guard count > 0 else { return (0, 0, 0) }
        let maxSamples = 480_000 // ~10 s at 48 kHz
        let stride = max(1, count / maxSamples)
        var diffEnergy = 0.0
        var totalEnergy = 0.0
        var samples = 0
        var index = 0
        while index < count {
            let left = Double(a[index])
            let right = Double(b[index])
            let delta = left - right
            diffEnergy += delta * delta
            totalEnergy += left * left + right * right
            samples += 1
            index += stride
        }
        return (diffEnergy, totalEnergy, samples)
    }

    /// Whether two channels are measurably decorrelated — the separate-vs-mixed discriminator.
    /// Normalized inter-channel difference energy `Σ(L−R)² / Σ(L²+R²)`. Identical (mixed-mode)
    /// channels score ~0; independent (separate mic/system) channels score ~1.
    nonisolated static func channelsAreDecorrelated(_ a: [Float], _ b: [Float], threshold: Double) -> Bool {
        let e = interChannelEnergies(a, b)
        guard e.total > 0 else { return false } // both silent → treat as mixed (mono path)
        return (e.diff / e.total) > threshold
    }

    /// Whether a prefix shows the two channels are *confidently* correlated: it carries meaningful
    /// energy AND its normalized difference energy is at/below `threshold`. A silent (energy-less)
    /// prefix is deliberately NOT confident — it returns false so the caller defers to the
    /// authoritative whole-file check rather than misclassifying a separate-track recording that
    /// merely opens with silence.
    nonisolated static func channelsAreConfidentlyCorrelated(_ a: [Float], _ b: [Float], threshold: Double) -> Bool {
        let e = interChannelEnergies(a, b)
        guard e.samples > 0, e.total > 0 else { return false }
        guard e.total / Double(e.samples) > silenceEnergyFloor else { return false } // silent head → inconclusive
        return (e.diff / e.total) <= threshold
    }

    /// Cheap, bounded pre-decode check used only to short-circuit an unavailable-sidecar live capture:
    /// `true` when the recording's head proves it cannot be separate-track (mono, or stereo whose
    /// channels are confidently correlated). A silent/inconclusive or decorrelated head, or a read
    /// failure, returns `false` so the caller proceeds to the authoritative whole-file decision.
    private nonisolated static func prefixIsDefinitelyNotSeparateTrack(
        inspector: MeetingAudioInspecting,
        url: URL,
        maxFrames: Int,
        threshold: Double
    ) async -> Bool {
        guard let probe = try? inspector.loadPrefix(at: url, maxFrames: maxFrames) else { return false }
        guard probe.channels.count >= 2 else { return true } // mono/no channels can't be separate-track
        return channelsAreConfidentlyCorrelated(probe.channels[0], probe.channels[1], threshold: threshold)
    }

    /// Per-segment Me/Others assignment by which of the two tracks is louder over the segment's
    /// time span. Segments where both tracks are silent are left unlabeled.
    nonisolated static func separateTrackAssignments(
        mic: [Float],
        system: [Float],
        sampleRate: Double,
        ranges: [MeetingSegmentTimeRange]
    ) -> [MeetingSpeakerAssignment] {
        var assignments: [MeetingSpeakerAssignment] = []
        for range in ranges {
            let micEnergy = rms(mic, start: range.start, end: range.end, sampleRate: sampleRate)
            let systemEnergy = rms(system, start: range.start, end: range.end, sampleRate: sampleRate)
            let total = micEnergy + systemEnergy
            guard total > 0 else { continue } // both channels silent over this span → leave unlabeled
            if micEnergy >= systemEnergy {
                assignments.append(.init(segmentID: range.id, label: micSpeakerLabel, confidence: micEnergy / total))
            } else {
                assignments.append(.init(segmentID: range.id, label: systemSpeakerLabel, confidence: systemEnergy / total))
            }
        }
        return assignments
    }

    /// Value-typed overlap assignment (no SwiftData), so it is unit-testable in isolation. Reuses
    /// `LocalDiarizationService.assignSpeakers` — the same best-time-overlap logic used by the
    /// recorder's batch diarization — so meeting and recorder labeling stay consistent.
    nonisolated static func assign(
        ranges: [(id: UUID, start: Double, end: Double)],
        from diarSegments: [SpeakerSegment]
    ) -> [MeetingSpeakerAssignment] {
        let pluginSegments = ranges.map {
            PluginStructuredTranscriptionSegment(text: "", start: $0.start, end: $0.end, speakerLabel: nil, speakerConfidence: nil)
        }
        let labeled = LocalDiarizationService.assignSpeakers(to: pluginSegments, from: diarSegments)
        var assignments: [MeetingSpeakerAssignment] = []
        for (index, range) in ranges.enumerated() {
            guard let label = labeled[index].speakerLabel, !label.isEmpty else { continue }
            assignments.append(.init(segmentID: range.id, label: label, confidence: labeled[index].speakerConfidence))
        }
        return assignments
    }

    /// Value-typed overlap assignment over `MeetingSegmentTimeRange`s (used by the off-main path).
    nonisolated static func assign(
        ranges: [MeetingSegmentTimeRange],
        from diarSegments: [SpeakerSegment]
    ) -> [MeetingSpeakerAssignment] {
        assign(ranges: ranges.map { (id: $0.id, start: $0.start, end: $0.end) }, from: diarSegments)
    }

    /// Root-mean-square amplitude of `samples` over `[start, end)` seconds. 0 when the range is
    /// empty/out of bounds. Used only to compare the two tracks' relative loudness per segment.
    nonisolated static func rms(_ samples: [Float], start: Double, end: Double, sampleRate: Double) -> Double {
        guard sampleRate > 0, end > start, !samples.isEmpty else { return 0 }
        let from = max(0, Int(start * sampleRate))
        let to = min(samples.count, Int(end * sampleRate))
        guard to > from else { return 0 }
        var sum = 0.0
        for index in from..<to {
            let value = Double(samples[index])
            sum += value * value
        }
        return (sum / Double(to - from)).squareRoot()
    }

    /// Off-main-actor wrapper for the blocking sidecar call (nonisolated async runs on the generic
    /// executor, keeping the pyannote process off the main thread).
    private nonisolated static func runDiarization(
        provider: DiarizationProvider,
        wavData: Data,
        numSpeakers: Int?
    ) async throws -> [SpeakerSegment] {
        try await provider.diarize(wavData: wavData, numSpeakers: numSpeakers)
    }
}
