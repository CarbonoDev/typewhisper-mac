import XCTest
import AVFoundation
@testable import TypeWhisper

/// [M1/D3] Per-session track mode. Meeting capture must be able to record separate mic (L) / system
/// (R) tracks for one session without leaking `.separate` into the shared recorder instance (the
/// standalone Recorder's preference), and the both-sources mix must honor the session's layout.
@MainActor
final class AudioRecorderTrackModeTests: XCTestCase {

    // MARK: - Helpers

    /// A recorder wired through the injectable start/stop overrides so no real audio engine or
    /// permissions are touched (mirrors `MeetingCaptureServiceTests.makeRecorder`).
    private func makeOverriddenRecorder(recordingsDirectory: URL) -> AudioRecorderService {
        let recorder = AudioRecorderService()
        recorder.recordingsDirectoryOverride = recordingsDirectory
        recorder.startRecordingOverride = { _, _, _, outputURL, _ in
            try FileManager.default.createDirectory(
                at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try Data("placeholder".utf8).write(to: outputURL)
            return outputURL
        }
        recorder.stopRecordingOverride = { outputURL in
            try Data("recorded".utf8).write(to: outputURL)
            return outputURL
        }
        return recorder
    }

    /// Write a constant-valued mono float WAV file, so the mix's per-channel content is deterministic.
    private func writeMonoWAV(value: Float, seconds: Double, sampleRate: Double, to url: URL) throws {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
        let frames = AVAudioFrameCount(seconds * sampleRate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        let data = buffer.floatChannelData![0]
        for i in 0..<Int(frames) { data[i] = value }
        let file = try AVAudioFile(
            forWriting: url,
            settings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
            ]
        )
        try file.write(from: buffer)
    }

    /// Read a 2-channel float file back into per-channel sample arrays (mid-file, past any codec ramp).
    private func readStereo(_ url: URL) throws -> (left: [Float], right: [Float]) {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        XCTAssertGreaterThanOrEqual(format.channelCount, 2)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        let frames = Int(buffer.frameLength)
        let left = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: frames))
        let right = Array(UnsafeBufferPointer(start: buffer.floatChannelData![1], count: frames))
        return (left, right)
    }

    // MARK: - Session capture + no leak

    func testSessionTrackModeIsCapturedPerSessionAndDoesNotLeak() async throws {
        let dir = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(dir) }
        let recorder = makeOverriddenRecorder(recordingsDirectory: dir.appendingPathComponent("rec"))
        recorder.trackMode = .mixed // the user's standalone Recorder preference

        // A meeting-style session explicitly requests separate tracks.
        _ = try await recorder.startRecording(micEnabled: true, systemAudioEnabled: true, format: .wav, trackMode: .separate)
        XCTAssertEqual(recorder.sessionTrackMode, .separate)
        XCTAssertEqual(recorder.trackMode, .mixed, "explicit session mode must not mutate the instance preference")
        _ = await recorder.stopRecording()

        // The next standalone recording (no explicit mode) falls back to the untouched instance value.
        _ = try await recorder.startRecording(micEnabled: true, systemAudioEnabled: true, format: .wav)
        XCTAssertEqual(recorder.sessionTrackMode, .mixed, "a default session inherits the instance preference — no leak from the meeting")
        _ = await recorder.stopRecording()
    }

    func testDefaultSessionTrackModeFollowsInstancePreference() async throws {
        let dir = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(dir) }
        let recorder = makeOverriddenRecorder(recordingsDirectory: dir.appendingPathComponent("rec"))
        // User picked `.separate` in the Recorder UI (instance property).
        recorder.trackMode = .separate

        _ = try await recorder.startRecording(micEnabled: true, systemAudioEnabled: true, format: .wav)
        XCTAssertEqual(recorder.sessionTrackMode, .separate, "nil trackMode captures the instance value")
        _ = await recorder.stopRecording()
    }

    // MARK: - Both-source mix honors the session layout

    /// Separate mode writes L = mic / R = system: the sole consumer of the track mode. This is what
    /// makes the two-person channel path (mic = Me / system = Others) real for new captures.
    func testSeparateModeMixWritesMicLeftSystemRight() throws {
        let dir = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(dir) }
        let recorder = makeOverriddenRecorder(recordingsDirectory: dir.appendingPathComponent("rec"))

        let sr = 16_000.0
        let micURL = dir.appendingPathComponent("mic.wav")
        let sysURL = dir.appendingPathComponent("sys.wav")
        let outURL = dir.appendingPathComponent("out.wav")
        try writeMonoWAV(value: 0.4, seconds: 1, sampleRate: sr, to: micURL)   // mic distinct level
        try writeMonoWAV(value: 0.2, seconds: 1, sampleRate: sr, to: sysURL)   // system distinct level

        try recorder.mixAudioFiles(micURL: micURL, systemURL: sysURL, outputURL: outURL, trackMode: .separate, micDuckingMode: .aggressive, outputFormat: .wav)

        let (left, right) = try readStereo(outURL)
        let mid = left.count / 2
        XCTAssertEqual(Double(left[mid]), 0.4, accuracy: 0.02, "L carries the mic track")
        XCTAssertEqual(Double(right[mid]), 0.2, accuracy: 0.02, "R carries the system track")
        // The two channels are genuinely distinct — this is what the decorrelation gate detects.
        XCTAssertNotEqual(left[mid], right[mid])
    }

    /// [M1/D3 carried minor] A single-source session (mic-only or system-only) is unaffected by
    /// `.separate`: `stopRecording` routes a lone source through `copyOrConvert` (never the both-sources
    /// mix), so the stored file stays exactly what was captured — a mono track, not a phantom-channel
    /// stereo file. `copyOrConvert` takes no track mode, so setting the instance preference to `.separate`
    /// changes nothing. Proves no phantom empty channel is ever written for one source (adjudication A#2).
    func testSingleSourceSessionUnaffectedBySeparateTrackMode() throws {
        let dir = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(dir) }
        let recorder = makeOverriddenRecorder(recordingsDirectory: dir.appendingPathComponent("rec"))
        recorder.trackMode = .separate // even with the separate preference set…

        let sr = 16_000.0
        let micURL = dir.appendingPathComponent("mic.wav")
        let outURL = dir.appendingPathComponent("out.wav")
        try writeMonoWAV(value: 0.4, seconds: 1, sampleRate: sr, to: micURL)

        // …the single-source finalizer copies the one mono track verbatim.
        try recorder.copyOrConvert(from: micURL, to: outURL, outputFormat: .wav)

        let outFile = try AVAudioFile(forReading: outURL)
        XCTAssertEqual(outFile.processingFormat.channelCount, 1, "a single-source recording stays mono — no phantom second channel")
        let buffer = AVAudioPCMBuffer(pcmFormat: outFile.processingFormat, frameCapacity: AVAudioFrameCount(outFile.length))!
        try outFile.read(into: buffer)
        let mid = Int(buffer.frameLength) / 2
        XCTAssertEqual(Double(buffer.floatChannelData![0][mid]), 0.4, accuracy: 0.02, "the captured mic content is preserved unchanged")
    }

    /// Mixed mode duplicates the same mic+system mix into both channels — the pre-fix behavior that
    /// the meeting path must NOT use. Proves the track mode parameter is actually honored (the two
    /// layouts diverge for identical inputs).
    func testMixedModeMixDuplicatesSameMixIntoBothChannels() throws {
        let dir = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(dir) }
        let recorder = makeOverriddenRecorder(recordingsDirectory: dir.appendingPathComponent("rec"))

        let sr = 16_000.0
        let micURL = dir.appendingPathComponent("mic.wav")
        let sysURL = dir.appendingPathComponent("sys.wav")
        let outURL = dir.appendingPathComponent("out.wav")
        try writeMonoWAV(value: 0.4, seconds: 1, sampleRate: sr, to: micURL)
        try writeMonoWAV(value: 0.2, seconds: 1, sampleRate: sr, to: sysURL)

        try recorder.mixAudioFiles(micURL: micURL, systemURL: sysURL, outputURL: outURL, trackMode: .mixed, micDuckingMode: .aggressive, outputFormat: .wav)

        let (left, right) = try readStereo(outURL)
        let mid = left.count / 2
        // Both channels carry the identical mix — not separable into mic vs system.
        XCTAssertEqual(left[mid], right[mid], accuracy: 0.0001, "mixed mode writes the same mix into L and R")
    }
}
