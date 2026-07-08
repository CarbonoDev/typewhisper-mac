import XCTest
@testable import TypeWhisper

@MainActor
final class MeetingImportServiceTests: XCTestCase {

    // MARK: - Stub transcriber (the `MeetingAudioTranscribing` seam)

    private final class StubTranscriber: MeetingAudioTranscribing {
        var result: TranscriptionResult
        var errorToThrow: Error?
        private(set) var receivedSampleCount = 0
        private(set) var receivedLanguageSelection: LanguageSelection?

        init(result: TranscriptionResult) { self.result = result }

        func transcribeImportedAudio(
            samples: [Float],
            languageSelection: LanguageSelection
        ) async throws -> TranscriptionResult {
            receivedSampleCount = samples.count
            receivedLanguageSelection = languageSelection
            if let errorToThrow { throw errorToThrow }
            return result
        }
    }

    /// A transcriber that blocks long enough for the test to cancel the import job first; the
    /// cancelled sleep throws, so `createFromImport` never runs.
    @MainActor
    private final class BlockingTranscriber: MeetingAudioTranscribing {
        private(set) var started = false
        func transcribeImportedAudio(
            samples: [Float],
            languageSelection: LanguageSelection
        ) async throws -> TranscriptionResult {
            started = true
            try await Task.sleep(nanoseconds: 5_000_000_000)
            return TranscriptionResult(
                text: "unused", detectedLanguage: "en", duration: 1, processingTime: 0,
                engineUsed: "stub", segments: [TranscriptionSegment(text: "unused", start: 0, end: 1)]
            )
        }
    }

    private func waitUntil(_ condition: @escaping () -> Bool) async {
        var iterations = 0
        while !condition() {
            if iterations > 100_000 { XCTFail("condition never met"); return }
            await Task.yield()
            iterations += 1
        }
    }

    private func makeResult(segments: [TranscriptionSegment]) -> TranscriptionResult {
        TranscriptionResult(
            text: segments.map(\.text).joined(separator: " "),
            detectedLanguage: "en",
            duration: 1,
            processingTime: 0.1,
            engineUsed: "stub",
            segments: segments
        )
    }

    private func makeService(
        meetingService: MeetingService,
        transcriber: MeetingAudioTranscribing
    ) -> MeetingImportService {
        MeetingImportService(
            meetingService: meetingService,
            audioFileService: AudioFileService(),
            transcriber: transcriber
        )
    }

    // MARK: - Transcript file → new meeting

    func testImportTranscriptFileCreatesNewMeetingWithSegments() throws {
        let dir = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(dir) }

        let meetingService = MeetingService(appSupportDirectory: dir)
        let transcriber = StubTranscriber(result: makeResult(segments: []))
        let service = makeService(meetingService: meetingService, transcriber: transcriber)

        let fileURL = dir.appendingPathComponent("google-meet.txt")
        try """
        Alice  00:00:05
        Welcome everyone to the sync.

        Bob  00:00:20
        Thanks, glad to be here.
        """.write(to: fileURL, atomically: true, encoding: .utf8)

        let meeting = try service.importTranscriptFile(at: fileURL)

        XCTAssertEqual(meeting.source, .importedTranscript)
        XCTAssertEqual(meeting.title, "google-meet")
        let sorted = meeting.segments.sorted { $0.order < $1.order }
        XCTAssertEqual(sorted.map(\.text), ["Welcome everyone to the sync.", "Thanks, glad to be here."])
        XCTAssertEqual(sorted.map(\.speakerLabel), ["Alice", "Bob"])
        XCTAssertTrue(sorted.allSatisfy { $0.source == .importedTranscript })
        // Orders are contiguous and monotonic.
        XCTAssertEqual(sorted.map(\.order), Array(0..<sorted.count))
    }

    func testImportUnsupportedTranscriptFileThrows() throws {
        let dir = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(dir) }
        let meetingService = MeetingService(appSupportDirectory: dir)
        let service = makeService(
            meetingService: meetingService,
            transcriber: StubTranscriber(result: makeResult(segments: []))
        )

        let fileURL = dir.appendingPathComponent("audio.wav")
        try Data("not really audio".utf8).write(to: fileURL)

        XCTAssertThrowsError(try service.importTranscriptFile(at: fileURL)) { error in
            XCTAssertEqual(error as? MeetingImportService.ImportError, .unsupportedTranscriptFile)
        }
    }

    func testImportEmptyTranscriptFileThrows() throws {
        let dir = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(dir) }
        let meetingService = MeetingService(appSupportDirectory: dir)
        let service = makeService(
            meetingService: meetingService,
            transcriber: StubTranscriber(result: makeResult(segments: []))
        )

        let fileURL = dir.appendingPathComponent("empty.txt")
        try "   \n\n  ".write(to: fileURL, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try service.importTranscriptFile(at: fileURL)) { error in
            XCTAssertEqual(error as? MeetingImportService.ImportError, .emptyTranscript)
        }
    }

    // MARK: - Audio file → new meeting (stubbed transcription)

    func testImportAudioFileCreatesNewMeetingWithSegmentsAndAdoptsAudio() async throws {
        let dir = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(dir) }

        let meetingService = MeetingService(appSupportDirectory: dir)
        let transcriber = StubTranscriber(
            result: makeResult(segments: [
                TranscriptionSegment(text: "First transcribed segment.", start: 0, end: 2),
                TranscriptionSegment(text: "Second transcribed segment.", start: 2, end: 4)
            ])
        )
        let service = makeService(meetingService: meetingService, transcriber: transcriber)

        // A real, decodable WAV so `AudioFileService.loadAudioSamples` produces samples.
        let audioURL = dir.appendingPathComponent("recording.wav")
        let wav = WavEncoder.encode(Array(repeating: Float(0.1), count: 16_000), sampleRate: 16_000)
        try wav.write(to: audioURL)

        let meeting = try await service.importAudioFile(at: audioURL)

        XCTAssertEqual(meeting.source, .importedAudio)
        XCTAssertGreaterThan(transcriber.receivedSampleCount, 0)
        let sorted = meeting.segments.sorted { $0.order < $1.order }
        XCTAssertEqual(sorted.map(\.text), ["First transcribed segment.", "Second transcribed segment."])
        XCTAssertTrue(sorted.allSatisfy { $0.source == .importedAudio })

        // Audio adopted into meetings-audio/, and the user's original file is left in place.
        XCTAssertNotNil(meeting.audioFileName)
        XCTAssertNotNil(meetingService.audioFileURL(for: meeting))
        XCTAssertTrue(FileManager.default.fileExists(atPath: audioURL.path), "original must not be moved")
    }

    func testImportAudioFileWithNoTranscriptThrows() async throws {
        let dir = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(dir) }

        let meetingService = MeetingService(appSupportDirectory: dir)
        let service = makeService(
            meetingService: meetingService,
            transcriber: StubTranscriber(result: makeResult(segments: []))
        )

        let audioURL = dir.appendingPathComponent("silent.wav")
        try WavEncoder.encode(Array(repeating: Float(0), count: 16_000), sampleRate: 16_000).write(to: audioURL)

        do {
            _ = try await service.importAudioFile(at: audioURL)
            XCTFail("Expected emptyAudioTranscription")
        } catch {
            XCTAssertEqual(error as? MeetingImportService.ImportError, .emptyAudioTranscription)
        }
        // No meeting was created for the failed import.
        XCTAssertTrue(meetingService.meetings.isEmpty)
    }

    // MARK: - [Track J] Audio import routed through the job queue

    /// Routed as an `.audioImport` job (the shape `MeetingsViewModel.importAudioFile` uses): while the
    /// transcription is in flight an import job is active (what `isImporting()` reads), and cancelling
    /// it creates no meeting — `createFromImport` runs only after transcription returns.
    func testCancelledAudioImportJobCreatesNoMeeting() async throws {
        let dir = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(dir) }

        let meetingService = MeetingService(appSupportDirectory: dir)
        let transcriber = BlockingTranscriber()
        let service = makeService(meetingService: meetingService, transcriber: transcriber)
        let queue = JobQueueService()

        let audioURL = dir.appendingPathComponent("recording.wav")
        try WavEncoder.encode(Array(repeating: Float(0.1), count: 16_000), sampleRate: 16_000).write(to: audioURL)

        let id = queue.enqueue(kind: .audioImport, meetingID: nil) { [weak service] in
            _ = try await service?.importAudioFile(at: audioURL)
        }
        // `isImporting()` equivalent: an audio-import job is active while the transcription runs.
        XCTAssertTrue(queue.jobs.contains { $0.kind == .audioImport && $0.state.isActive })

        await waitUntil { transcriber.started }
        queue.cancel(id)
        await queue.drain()

        XCTAssertTrue(meetingService.meetings.isEmpty, "a cancelled import must create no meeting")
        XCTAssertEqual(queue.jobs.first { $0.id == id }?.state, .cancelled)
    }

    // MARK: - Merge transcript into an existing captured meeting

    func testMergeTranscriptFileIntoCapturedMeetingProducesOneOrderedDedupedTranscript() throws {
        let dir = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(dir) }

        let meetingService = MeetingService(appSupportDirectory: dir)
        let service = makeService(
            meetingService: meetingService,
            transcriber: StubTranscriber(result: makeResult(segments: []))
        )

        // A captured meeting covering only the later part of the call (shared clock at t=300+).
        let meeting = meetingService.createMeeting(title: "Captured", source: .adHoc, state: .completed)
        meetingService.appendStableSegments(
            [
                TranscriptionSegment(text: "Second half point one.", start: 300, end: 330),
                TranscriptionSegment(text: "Second half point two.", start: 330, end: 360)
            ],
            to: meeting
        )

        // The full Google Meet transcript, including the overlap the user already captured.
        let fileURL = dir.appendingPathComponent("full.txt")
        try """
        Alice  00:00:05
        Opening remarks about scope.

        Bob  00:01:00
        Early discussion of budget planning.

        Alice  00:05:00
        Second half point one.

        Bob  00:05:30
        Second half point two.
        """.write(to: fileURL, atomically: true, encoding: .utf8)

        try service.mergeTranscriptFile(at: fileURL, into: meeting)

        let sorted = meeting.segments.sorted { $0.order < $1.order }
        // One coherent chronological transcript: two imported gap-fillers + two captured segments,
        // overlap not duplicated.
        XCTAssertEqual(sorted.map(\.text), [
            "Opening remarks about scope.",
            "Early discussion of budget planning.",
            "Second half point one.",
            "Second half point two."
        ])
        // The overlap resolves to the captured source; the gap-fillers stay imported-tagged.
        XCTAssertEqual(sorted.filter { $0.source == .liveCapture }.count, 2)
        XCTAssertEqual(sorted.filter { $0.source == .importedTranscript }.count, 2)
        XCTAssertTrue(sorted.suffix(2).allSatisfy { $0.source == .liveCapture })
        // Orders remain contiguous and monotonic across the merged transcript.
        XCTAssertEqual(sorted.map(\.order), Array(0..<sorted.count))
    }
}
