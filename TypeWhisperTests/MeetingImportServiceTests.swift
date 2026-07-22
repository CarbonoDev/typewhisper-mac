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

    func testImportTranscriptTextCreatesNewMeetingWithSegments() throws {
        let dir = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(dir) }

        let meetingService = MeetingService(appSupportDirectory: dir)
        let service = makeService(
            meetingService: meetingService,
            transcriber: StubTranscriber(result: makeResult(segments: []))
        )

        let meeting = try service.importTranscriptText(
            "Alice: Welcome everyone.\nBob: Thanks, glad to be here.",
            title: "Text Import"
        )

        XCTAssertEqual(meeting.source, .importedTranscript)
        XCTAssertEqual(meeting.title, "Text Import")
        let sorted = meeting.segments.sorted { $0.order < $1.order }
        XCTAssertEqual(sorted.map(\.text), ["Welcome everyone.", "Thanks, glad to be here."])
        XCTAssertEqual(sorted.map(\.speakerLabel), ["Alice", "Bob"])
    }

    func testImportTranscriptTextEmptyThrows() throws {
        let dir = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(dir) }
        let meetingService = MeetingService(appSupportDirectory: dir)
        let service = makeService(
            meetingService: meetingService,
            transcriber: StubTranscriber(result: makeResult(segments: []))
        )

        XCTAssertThrowsError(try service.importTranscriptText("   \n\n  ")) { error in
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
        // One coherent chronological transcript: no text duplicated across the sources.
        XCTAssertEqual(sorted.map(\.text), [
            "Opening remarks about scope.",
            "Early discussion of budget planning.",
            "Second half point one.",
            "Second half point two."
        ])
        // Overlap policy (`ImportOverlapPlan`): the timed import covers [5, 330], so the live row
        // whose midpoint sits inside it (300–330) yields to the imported version; the live row past
        // the covered span (330–360, midpoint 345) survives as captured.
        XCTAssertEqual(sorted.filter { $0.source == .liveCapture }.count, 1)
        XCTAssertEqual(sorted.filter { $0.source == .importedTranscript }.count, 3)
        XCTAssertEqual(sorted.last?.source, .liveCapture)
        // Orders remain contiguous and monotonic across the merged transcript.
        XCTAssertEqual(sorted.map(\.order), Array(0..<sorted.count))
    }

    // MARK: - Overlap policy (`ImportOverlapPlan`): timed import is authoritative for its span

    /// A timed import covering the middle of the meeting drops only the live-caption rows whose
    /// midpoint falls inside its covered span; live rows before and after survive, and the
    /// imported rows carry their own (Gemini) speaker names.
    func testMergeTimedImportDropsOnlyLiveCaptionRowsInsideCoveredSpan() throws {
        let dir = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(dir) }

        let meetingService = MeetingService(appSupportDirectory: dir)
        let service = makeService(
            meetingService: meetingService,
            transcriber: StubTranscriber(result: makeResult(segments: []))
        )

        // Live captions across the whole meeting (meeting-relative clock, per the API contract).
        let meeting = meetingService.createMeeting(title: "Con captions", source: .adHoc, state: .completed)
        meetingService.appendStableSegments(
            [
                TranscriptionSegment(text: "Caption antes del rango importado.", start: 0, end: 30),
                TranscriptionSegment(text: "Caption dentro del rango uno.", start: 300, end: 330),
                TranscriptionSegment(text: "Caption dentro del rango dos.", start: 340, end: 370),
                TranscriptionSegment(text: "Caption después del rango importado.", start: 600, end: 630)
            ],
            source: .liveCaptions,
            to: meeting
        )

        // A synthetic Gemini export covering 00:04:00–00:08:00 — a *different* transcription of the
        // same audio (no shared text with the captions), which text dedupe alone cannot catch.
        let fileURL = dir.appendingPathComponent("notas.md")
        try """
        ## **Llamada de Prueba \\- Transcripción**

        ### **00:04:00**

        **Nora Ibáñez:** Frase importada uno sobre el avance.

        **Teo Salas:** Frase importada dos con otra redacción.

        ### **La transcripción finalizó después de 00:08:00**

        *Esta transcripción editable se generó por computadora y puede contener errores.*
        """.write(to: fileURL, atomically: true, encoding: .utf8)

        let dropped = try service.mergeTranscriptFile(at: fileURL, into: meeting)

        XCTAssertEqual(dropped, 2, "exactly the two in-span caption rows are dropped")
        let sorted = meeting.segments.sorted { $0.order < $1.order }
        let texts = sorted.map(\.text)
        // Out-of-span captions survive; in-span captions are replaced by the import.
        XCTAssertTrue(texts.contains("Caption antes del rango importado."))
        XCTAssertTrue(texts.contains("Caption después del rango importado."))
        XCTAssertFalse(texts.contains("Caption dentro del rango uno."))
        XCTAssertFalse(texts.contains("Caption dentro del rango dos."))
        XCTAssertTrue(texts.contains("Frase importada uno sobre el avance."))
        XCTAssertTrue(texts.contains("Frase importada dos con otra redacción."))
        // The imported rows carry the export's own speaker names.
        XCTAssertEqual(
            sorted.first { $0.text.hasPrefix("Frase importada uno") }?.speakerLabel,
            "Nora Ibáñez"
        )
        XCTAssertEqual(sorted.filter { $0.source == .liveCaptions }.count, 2)
        XCTAssertEqual(sorted.filter { $0.source == .importedTranscript }.count, 2)
    }

    /// An import with no recoverable timing (plain `Speaker:` lines, all-zero timestamps) must fall
    /// back to the append + text-dedupe behavior: no live row is ever dropped on a guess.
    func testMergeUntimedImportNeverDropsLiveRows() throws {
        let dir = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(dir) }

        let meetingService = MeetingService(appSupportDirectory: dir)
        let service = makeService(
            meetingService: meetingService,
            transcriber: StubTranscriber(result: makeResult(segments: []))
        )

        let meeting = meetingService.createMeeting(title: "Con captions", source: .adHoc, state: .completed)
        meetingService.appendStableSegments(
            [
                TranscriptionSegment(text: "Caption uno con su propio texto.", start: 10, end: 20),
                TranscriptionSegment(text: "Caption dos con más contenido.", start: 20, end: 30)
            ],
            source: .liveCaptions,
            to: meeting
        )

        let fileURL = dir.appendingPathComponent("sin-tiempos.txt")
        try """
        Nora: Comentario sin marca de tiempo alguna.
        Teo: Otra línea sin tiempos en el archivo.
        """.write(to: fileURL, atomically: true, encoding: .utf8)

        let dropped = try service.mergeTranscriptFile(at: fileURL, into: meeting)

        XCTAssertEqual(dropped, 0, "an untimed import must never drop live rows")
        let sorted = meeting.segments.sorted { $0.order < $1.order }
        XCTAssertEqual(sorted.filter { $0.source == .liveCaptions }.count, 2)
        XCTAssertEqual(sorted.filter { $0.source == .importedTranscript }.count, 2)
    }

    /// Merging a timed import into a meeting with no segments is a plain add — every parsed
    /// segment lands, nothing to drop.
    func testMergeTimedImportIntoEmptyMeetingIsPlainAdd() throws {
        let dir = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(dir) }

        let meetingService = MeetingService(appSupportDirectory: dir)
        let service = makeService(
            meetingService: meetingService,
            transcriber: StubTranscriber(result: makeResult(segments: []))
        )
        let meeting = meetingService.createMeeting(title: "Vacío", source: .adHoc, state: .completed)

        let fileURL = dir.appendingPathComponent("notas.md")
        try """
        ## **Llamada Corta \\- Transcripción**

        ### **00:00:05**

        **Nora Ibáñez:** Único punto tratado en la llamada.

        **Teo Salas:** De acuerdo con el punto.

        ### **La transcripción finalizó después de 00:01:05**
        """.write(to: fileURL, atomically: true, encoding: .utf8)

        let dropped = try service.mergeTranscriptFile(at: fileURL, into: meeting)

        XCTAssertEqual(dropped, 0)
        let sorted = meeting.segments.sorted { $0.order < $1.order }
        XCTAssertEqual(sorted.count, 2)
        XCTAssertTrue(sorted.allSatisfy { $0.source == .importedTranscript })
        XCTAssertEqual(sorted.map(\.speakerLabel), ["Nora Ibáñez", "Teo Salas"])
        XCTAssertEqual(sorted.first?.start, 5)
    }

    // MARK: - `ImportOverlapPlan` pure-logic checks

    /// Only *live* sources are candidates for the overlap drop; previously-imported rows in the
    /// span are untouched, and out-of-span live rows always survive.
    func testImportOverlapPlanDropsOnlyLiveMidpointsInsideSpan() {
        let existing: [TranscriptMerger.Segment] = [
            .init(text: "caption dentro", start: 100, end: 120, source: .liveCaptions),
            .init(text: "captura dentro", start: 150, end: 170, source: .liveCapture),
            .init(text: "importado previo dentro", start: 160, end: 180, source: .importedAudio),
            .init(text: "caption fuera", start: 400, end: 420, source: .liveCaptions)
        ]
        let imported: [TranscriptMerger.Segment] = [
            .init(text: "nueva uno", start: 90, end: 200, source: .importedTranscript)
        ]

        let resolution = ImportOverlapPlan.resolve(existing: existing, imported: imported)

        XCTAssertEqual(resolution.droppedOverlappedCount, 2)
        XCTAssertEqual(
            resolution.survivingExisting.map(\.text),
            ["importado previo dentro", "caption fuera"]
        )
    }

    /// An all-zero-timing import has no recoverable span → the plan is a no-op (fallback path).
    func testImportOverlapPlanIsNoOpWithoutRecoverableTiming() {
        let existing: [TranscriptMerger.Segment] = [
            .init(text: "caption", start: 0, end: 30, source: .liveCaptions)
        ]
        let imported: [TranscriptMerger.Segment] = [
            .init(text: "sin tiempos uno", start: 0, end: 0, source: .importedTranscript),
            .init(text: "sin tiempos dos", start: 0, end: 0, source: .importedTranscript)
        ]

        let resolution = ImportOverlapPlan.resolve(existing: existing, imported: imported)

        XCTAssertEqual(resolution.droppedOverlappedCount, 0)
        XCTAssertEqual(resolution.survivingExisting, existing)
        XCTAssertNil(ImportOverlapPlan.coveredSpan(of: imported))
    }
}
