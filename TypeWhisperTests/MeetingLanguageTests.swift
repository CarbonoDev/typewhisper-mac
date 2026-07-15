import XCTest
import TypeWhisperPluginSDK
@testable import TypeWhisper

/// M1 — per-meeting language: schema + manual set + full threading (no detection). Covers the
/// provenance ladder (manual > rule > detected), the `transcriptionLanguageSelection` query, rule
/// seeding at capture start (only for `.exact`, never over `.manual`), both final-pass paths, audio
/// import persistence, the LLM output-language directive on the direct/reduce/brief/Q&A prompts (and
/// its deliberate absence from the map prompt), and the export frontmatter `language:` line.
@MainActor
final class MeetingLanguageTests: XCTestCase {
    // MARK: - Fixtures

    private func makeStore() throws -> MeetingService {
        let dir = try TestSupport.makeTemporaryDirectory(prefix: "MeetingLanguage")
        addTeardownBlock { TestSupport.remove(dir) }
        return MeetingService(appSupportDirectory: dir)
    }

    /// Force a meeting into a `.detected` provenance state (M2 owns the setter; here we set the model
    /// columns directly so the ladder can be exercised in M1).
    private func forceDetected(_ code: String, on meeting: Meeting, in service: MeetingService) {
        meeting.languageCode = code
        meeting.languageProvenance = .detected
        service.update(meeting)
    }

    // MARK: - Provenance ladder (MeetingService setters)

    func testSetLanguageRecordsManualAndLowercases() throws {
        let service = try makeStore()
        let meeting = service.createMeeting(title: "M", source: .adHoc, state: .completed)

        service.setLanguage("DE", for: meeting)

        XCTAssertEqual(meeting.languageCode, "de")
        XCTAssertEqual(meeting.languageProvenance, .manual)
    }

    func testSetLanguageManualOverridesRuleAndDetected() throws {
        let service = try makeStore()
        let meeting = service.createMeeting(title: "M", source: .adHoc, state: .completed)

        forceDetected("fr", on: meeting, in: service)
        service.setLanguage("en", for: meeting)
        XCTAssertEqual(meeting.languageCode, "en")
        XCTAssertEqual(meeting.languageProvenance, .manual)

        // A rule seed after a manual pick must not clobber it.
        service.seedRuleLanguage("de", for: meeting)
        XCTAssertEqual(meeting.languageCode, "en")
        XCTAssertEqual(meeting.languageProvenance, .manual)
    }

    func testClearLanguageResetsBothColumns() throws {
        let service = try makeStore()
        let meeting = service.createMeeting(title: "M", source: .adHoc, state: .completed)
        service.setLanguage("de", for: meeting)

        service.clearLanguage(for: meeting)

        XCTAssertNil(meeting.languageCode)
        XCTAssertNil(meeting.languageProvenanceRaw)
        XCTAssertNil(meeting.languageProvenance)
    }

    func testSetLanguageBlankClears() throws {
        let service = try makeStore()
        let meeting = service.createMeeting(title: "M", source: .adHoc, state: .completed)
        service.setLanguage("de", for: meeting)

        service.setLanguage("   ", for: meeting)

        XCTAssertNil(meeting.languageCode)
        XCTAssertNil(meeting.languageProvenance)
    }

    func testSeedRuleLanguageSeedsOverNil() throws {
        let service = try makeStore()
        let meeting = service.createMeeting(title: "M", source: .adHoc, state: .completed)

        service.seedRuleLanguage("de", for: meeting)

        XCTAssertEqual(meeting.languageCode, "de")
        XCTAssertEqual(meeting.languageProvenance, .rule)
    }

    func testSeedRuleLanguageOverwritesDetected() throws {
        let service = try makeStore()
        let meeting = service.createMeeting(title: "M", source: .adHoc, state: .completed)
        forceDetected("fr", on: meeting, in: service)

        service.seedRuleLanguage("de", for: meeting)

        XCTAssertEqual(meeting.languageCode, "de")
        XCTAssertEqual(meeting.languageProvenance, .rule)
    }

    func testSeedRuleLanguageNeverOverwritesManual_manualThenRule() throws {
        let service = try makeStore()
        let meeting = service.createMeeting(title: "M", source: .adHoc, state: .completed)

        service.setLanguage("en", for: meeting)      // manual first
        service.seedRuleLanguage("de", for: meeting) // rule after

        XCTAssertEqual(meeting.languageCode, "en")
        XCTAssertEqual(meeting.languageProvenance, .manual)
    }

    func testSeedRuleLanguageNeverOverwritesManual_ruleThenManual() throws {
        let service = try makeStore()
        let meeting = service.createMeeting(title: "M", source: .adHoc, state: .completed)

        service.seedRuleLanguage("de", for: meeting) // rule first
        service.setLanguage("en", for: meeting)      // manual after wins

        XCTAssertEqual(meeting.languageCode, "en")
        XCTAssertEqual(meeting.languageProvenance, .manual)
    }

    func testTranscriptionLanguageSelectionDerivesFromColumn() throws {
        let service = try makeStore()
        let meeting = service.createMeeting(title: "M", source: .adHoc, state: .completed)

        XCTAssertEqual(service.transcriptionLanguageSelection(for: meeting), .auto)

        service.setLanguage("de", for: meeting)
        XCTAssertEqual(service.transcriptionLanguageSelection(for: meeting), .exact("de"))
    }

    // MARK: - LLM output-language directive (plan D4)

    @MainActor
    private final class StubProcessor: PromptProcessing {
        struct Call {
            let prompt: String
            let text: String
        }
        var selectedProviderId = "p"
        var selectedCloudModel = "m"
        private(set) var calls: [Call] = []
        var responder: (Int) -> String = { "resp-\($0)" }

        func process(
            prompt: String,
            text: String,
            providerOverride: String?,
            cloudModelOverride: String?,
            temperatureDirective: PluginLLMTemperatureDirective,
            skipMemoryInjection: Bool
        ) async throws -> String {
            calls.append(Call(prompt: prompt, text: text))
            return responder(calls.count)
        }
    }

    private func makeVault() -> ObsidianVaultService {
        let suite = "MeetingLanguageTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        return ObsidianVaultService(defaults: defaults)
    }

    private func makeMeeting(on service: MeetingService, segmentTexts: [String]) -> Meeting {
        let meeting = service.createMeeting(title: "Analysis", source: .adHoc, state: .completed)
        var start = 0.0
        service.appendStableSegments(
            segmentTexts.map { text in
                defer { start += 2 }
                return TranscriptionSegment(text: text, start: start, end: start + 2)
            },
            to: meeting
        )
        return meeting
    }

    private func makeTemplate(prompt: String = "Summarize this.") -> PromptAction {
        PromptAction(
            name: "T",
            prompt: prompt,
            surfaceRaw: PromptSurface.meeting.rawValue,
            meetingKindRaw: MeetingOutputKind.summary.rawValue
        )
    }

    /// The English target-language name is what the directive embeds.
    private func directiveMarker(_ code: String) -> String {
        Locale(identifier: "en").localizedString(forIdentifier: code) ?? code
    }

    func testDirectPathCarriesLanguageDirective() async throws {
        let service = try makeStore()
        let processor = StubProcessor()
        let llm = MeetingLLMService(meetingService: service, vaultService: makeVault(), processor: processor)
        let meeting = makeMeeting(on: service, segmentTexts: ["Short transcript."])
        service.setLanguage("de", for: meeting)

        _ = try await llm.generateOutput(for: meeting, using: makeTemplate())

        XCTAssertEqual(processor.calls.count, 1)
        let prompt = try XCTUnwrap(processor.calls.first?.prompt)
        XCTAssertTrue(prompt.contains(directiveMarker("de")), "direct prompt must carry the language directive")
        XCTAssertTrue(prompt.contains("Summarize this."), "template prompt must be preserved")
    }

    func testNoDirectiveWhenLanguageUnset() async throws {
        let service = try makeStore()
        let processor = StubProcessor()
        let llm = MeetingLLMService(meetingService: service, vaultService: makeVault(), processor: processor)
        let meeting = makeMeeting(on: service, segmentTexts: ["Short transcript."])

        _ = try await llm.generateOutput(for: meeting, using: makeTemplate())

        let prompt = try XCTUnwrap(processor.calls.first?.prompt)
        XCTAssertFalse(prompt.contains("Write your entire response in"))
        XCTAssertEqual(prompt, "Summarize this.")
    }

    func testMapPromptIsDirectiveFreeButReduceCarriesIt() async throws {
        let service = try makeStore()
        let processor = StubProcessor()
        // Tiny budget forces map/reduce (multiple chunks).
        let llm = MeetingLLMService(
            meetingService: service, vaultService: makeVault(), processor: processor, charBudget: 40
        )
        let meeting = makeMeeting(on: service, segmentTexts: [
            "The first portion of the meeting discusses the roadmap in detail.",
            "The second portion of the meeting covers hiring and budget concerns."
        ])
        service.setLanguage("de", for: meeting)

        _ = try await llm.generateOutput(for: meeting, using: makeTemplate())

        XCTAssertGreaterThan(processor.calls.count, 1, "expected a map/reduce run")
        // The final (reduce) call carries the directive.
        let reducePrompt = try XCTUnwrap(processor.calls.last?.prompt)
        XCTAssertTrue(reducePrompt.contains(directiveMarker("de")), "reduce prompt must carry the directive")
        // Every earlier (map) call must NOT carry the directive (owner-veto 4).
        for mapCall in processor.calls.dropLast() {
            XCTAssertFalse(
                mapCall.prompt.contains("Write your entire response in"),
                "map prompt must be directive-free"
            )
        }
    }

    func testQAAnswerCarriesLanguageDirective() async throws {
        let service = try makeStore()
        let processor = StubProcessor()
        let llm = MeetingLLMService(meetingService: service, vaultService: makeVault(), processor: processor)
        let meeting = makeMeeting(on: service, segmentTexts: ["We shipped the release."])
        service.setLanguage("de", for: meeting)

        _ = try await llm.answerQuestion(for: meeting, question: "What happened?")

        let prompt = try XCTUnwrap(processor.calls.first?.prompt)
        XCTAssertTrue(prompt.contains(directiveMarker("de")), "Q&A system prompt must carry the directive")
    }

    func testBriefCarriesLanguageDirective() async throws {
        let service = try makeStore()
        let processor = StubProcessor()
        let brief = MeetingBriefService(meetingService: service, vaultService: makeVault(), processor: processor)

        // A prior related meeting (shared attendee + a summary) gives the brief context so it doesn't
        // throw `insufficientContext`.
        let attendee = Attendee(name: "Marco", email: "marco@acme.com")
        let prior = service.createMeeting(
            title: "Prior", source: .calendar, state: .completed, attendees: [attendee]
        )
        service.addOutput(to: prior, kind: .summary, content: "Prior summary body.")

        let meeting = service.createMeeting(
            title: "Upcoming", source: .calendar, state: .scheduled, attendees: [attendee]
        )
        service.setLanguage("de", for: meeting)

        _ = try await brief.generateBrief(for: meeting)

        let prompt = try XCTUnwrap(processor.calls.first?.prompt)
        XCTAssertTrue(prompt.contains(directiveMarker("de")), "brief system prompt must carry the directive")
    }

    // MARK: - Audio import (persist chosen language + pass to transcription)

    @MainActor
    private final class RecordingTranscriber: MeetingAudioTranscribing {
        private(set) var receivedSelection: LanguageSelection?
        func transcribeImportedAudio(
            samples: [Float],
            languageSelection: LanguageSelection
        ) async throws -> TranscriptionResult {
            receivedSelection = languageSelection
            return TranscriptionResult(
                text: "Imported line.", detectedLanguage: "en", duration: 1, processingTime: 0.1,
                engineUsed: "stub", segments: [TranscriptionSegment(text: "Imported line.", start: 0, end: 1)]
            )
        }
    }

    func testImportPersistsChosenLanguageAndPassesItToTranscription() async throws {
        let dir = try TestSupport.makeTemporaryDirectory(prefix: "MeetingLanguageImport")
        defer { TestSupport.remove(dir) }
        let service = MeetingService(appSupportDirectory: dir)
        let transcriber = RecordingTranscriber()
        let importService = MeetingImportService(
            meetingService: service, audioFileService: AudioFileService(), transcriber: transcriber
        )

        // A real, decodable WAV so `AudioFileService.loadAudioSamples` produces samples.
        let audioURL = dir.appendingPathComponent("recording.wav")
        let wav = WavEncoder.encode(Array(repeating: Float(0.1), count: 16_000), sampleRate: 16_000)
        try wav.write(to: audioURL)

        let meeting = try await importService.importAudioFile(at: audioURL, languageCode: "de")

        XCTAssertEqual(transcriber.receivedSelection, .exact("de"), "chosen language must drive transcription")
        XCTAssertEqual(meeting.languageCode, "de")
        XCTAssertEqual(meeting.languageProvenance, .manual, "an import picker choice is an explicit manual pick")
    }

    func testImportLeftOnAutoPersistsNoLanguage() async throws {
        let dir = try TestSupport.makeTemporaryDirectory(prefix: "MeetingLanguageImport")
        defer { TestSupport.remove(dir) }
        let service = MeetingService(appSupportDirectory: dir)
        let transcriber = RecordingTranscriber()
        let importService = MeetingImportService(
            meetingService: service, audioFileService: AudioFileService(), transcriber: transcriber
        )

        let audioURL = dir.appendingPathComponent("recording.wav")
        try WavEncoder.encode(Array(repeating: Float(0.1), count: 16_000), sampleRate: 16_000).write(to: audioURL)

        let meeting = try await importService.importAudioFile(at: audioURL, languageCode: nil)

        XCTAssertEqual(transcriber.receivedSelection, .auto)
        XCTAssertNil(meeting.languageCode)
    }

    // MARK: - Export frontmatter

    func testFrontmatterEmitsLanguageWhenSet() throws {
        let vaultDir = try TestSupport.makeTemporaryDirectory(prefix: "MeetingLanguageVault")
        addTeardownBlock { TestSupport.remove(vaultDir) }
        let storeDir = try TestSupport.makeTemporaryDirectory(prefix: "MeetingLanguageExportStore")
        addTeardownBlock { TestSupport.remove(storeDir) }
        let service = MeetingService(appSupportDirectory: storeDir)

        let suite = "MeetingLanguageExport-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        let vault = ObsidianVaultService(defaults: defaults)
        vault.connect(to: vaultDir.path)
        let exporter = MeetingObsidianExporter(vaultService: vault)

        let meeting = service.createMeeting(title: "Sync", source: .adHoc, state: .completed)
        service.appendStableSegments([TranscriptionSegment(text: "Hi.", start: 0, end: 1)], to: meeting)
        service.setLanguage("de", for: meeting)

        let urls = try exporter.export(meeting, sections: [.transcript], combined: true)
        let body = try String(contentsOf: try XCTUnwrap(urls.first), encoding: .utf8)
        XCTAssertTrue(body.contains("language: de"), "frontmatter must include the language line")
    }

    func testFrontmatterOmitsLanguageWhenUnset() throws {
        let vaultDir = try TestSupport.makeTemporaryDirectory(prefix: "MeetingLanguageVault")
        addTeardownBlock { TestSupport.remove(vaultDir) }
        let storeDir = try TestSupport.makeTemporaryDirectory(prefix: "MeetingLanguageExportStore")
        addTeardownBlock { TestSupport.remove(storeDir) }
        let service = MeetingService(appSupportDirectory: storeDir)

        let suite = "MeetingLanguageExport-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        let vault = ObsidianVaultService(defaults: defaults)
        vault.connect(to: vaultDir.path)
        let exporter = MeetingObsidianExporter(vaultService: vault)

        let meeting = service.createMeeting(title: "Sync", source: .adHoc, state: .completed)
        service.appendStableSegments([TranscriptionSegment(text: "Hi.", start: 0, end: 1)], to: meeting)

        let urls = try exporter.export(meeting, sections: [.transcript], combined: true)
        let body = try String(contentsOf: try XCTUnwrap(urls.first), encoding: .utf8)
        XCTAssertFalse(body.contains("language:"), "no language line when unset")
    }

    // MARK: - Capture: rule seeding + final-pass language threading

    private var previousPluginManager: PluginManager?

    private func withPluginManager(_ body: () async throws -> Void) async rethrows {
        previousPluginManager = PluginManager.shared
        PluginManager.shared = PluginManager()
        defer {
            PluginManager.shared = previousPluginManager
            previousPluginManager = nil
        }
        try await body()
    }

    private final class FakeMatcher: MeetingContextRuleMatching {
        let actions: MeetingRuleActions
        init(actions: MeetingRuleActions) { self.actions = actions }
        func match(_ context: MeetingContext) -> MeetingRuleMatchResult? {
            MeetingRuleMatchResult(ruleID: UUID(), ruleName: "R", specificity: 1, actions: actions)
        }
    }

    private func makeRecorder(recordingsDirectory: URL) -> AudioRecorderService {
        let recorder = AudioRecorderService()
        recorder.recordingsDirectoryOverride = recordingsDirectory
        recorder.startRecordingOverride = { _, _, _, outputURL in
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
        recorder.currentBufferOverride = { Array(repeating: Float(0.2), count: 16_000) }
        return recorder
    }

    private func makeCaptureService(
        meetingService: MeetingService,
        recorder: AudioRecorderService,
        jobQueue: JobQueueService,
        ruleMatcher: MeetingContextRuleMatching?
    ) -> MeetingCaptureService {
        let suite = "MeetingLanguageCapture-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        return MeetingCaptureService(
            meetingService: meetingService,
            audioRecorderService: recorder,
            modelManager: ModelManagerService(),
            jobQueue: jobQueue,
            defaults: defaults,
            flushIntervalSeconds: 0,
            ruleMatcher: ruleMatcher
        )
    }

    func testRuleExactLanguageSeedsMeeting() async throws {
        try await withPluginManager {
            let dir = try TestSupport.makeTemporaryDirectory(prefix: "MeetingLanguageCapture")
            defer { TestSupport.remove(dir) }
            let service = MeetingService(appSupportDirectory: dir)
            let recorder = makeRecorder(recordingsDirectory: dir.appendingPathComponent("rec"))
            let jobQueue = JobQueueService()
            let matcher = FakeMatcher(actions: MeetingRuleActions(languageSelection: "de"))
            let capture = makeCaptureService(
                meetingService: service, recorder: recorder, jobQueue: jobQueue, ruleMatcher: matcher
            )
            let meeting = service.createMeeting(title: "Ruled", source: .adHoc, state: .scheduled)

            try await capture.start(meeting: meeting)

            XCTAssertEqual(meeting.languageCode, "de")
            XCTAssertEqual(meeting.languageProvenance, .rule)

            await capture.stop()
            await capture.awaitFinalizeTeardownForTesting()
            await jobQueue.drain()
        }
    }

    func testRuleNonExactLanguageSeedsNothing() async throws {
        try await withPluginManager {
            let dir = try TestSupport.makeTemporaryDirectory(prefix: "MeetingLanguageCapture")
            defer { TestSupport.remove(dir) }
            let service = MeetingService(appSupportDirectory: dir)
            let recorder = makeRecorder(recordingsDirectory: dir.appendingPathComponent("rec"))
            let jobQueue = JobQueueService()
            // "auto" resolves to `.auto`, not `.exact` → seeds nothing (plan D2, risk 8).
            let matcher = FakeMatcher(actions: MeetingRuleActions(languageSelection: "auto"))
            let capture = makeCaptureService(
                meetingService: service, recorder: recorder, jobQueue: jobQueue, ruleMatcher: matcher
            )
            let meeting = service.createMeeting(title: "AutoRule", source: .adHoc, state: .scheduled)

            try await capture.start(meeting: meeting)

            XCTAssertNil(meeting.languageCode)
            XCTAssertNil(meeting.languageProvenance)

            await capture.stop()
            await capture.awaitFinalizeTeardownForTesting()
            await jobQueue.drain()
        }
    }

    func testRuleDoesNotClobberManualPick() async throws {
        try await withPluginManager {
            let dir = try TestSupport.makeTemporaryDirectory(prefix: "MeetingLanguageCapture")
            defer { TestSupport.remove(dir) }
            let service = MeetingService(appSupportDirectory: dir)
            let recorder = makeRecorder(recordingsDirectory: dir.appendingPathComponent("rec"))
            let jobQueue = JobQueueService()
            let matcher = FakeMatcher(actions: MeetingRuleActions(languageSelection: "de"))
            let capture = makeCaptureService(
                meetingService: service, recorder: recorder, jobQueue: jobQueue, ruleMatcher: matcher
            )
            let meeting = service.createMeeting(title: "Manual", source: .adHoc, state: .scheduled)
            service.setLanguage("en", for: meeting) // explicit manual pick before capture

            try await capture.start(meeting: meeting)

            XCTAssertEqual(meeting.languageCode, "en")
            XCTAssertEqual(meeting.languageProvenance, .manual)

            await capture.stop()
            await capture.awaitFinalizeTeardownForTesting()
            await jobQueue.drain()
        }
    }

    func testSameEngineFinalizeReceivesExactLanguage() async throws {
        try await withPluginManager {
            let dir = try TestSupport.makeTemporaryDirectory(prefix: "MeetingLanguageFinalize")
            defer { TestSupport.remove(dir) }
            let service = MeetingService(appSupportDirectory: dir)
            let recorder = makeRecorder(recordingsDirectory: dir.appendingPathComponent("rec"))
            let jobQueue = JobQueueService()
            let capture = makeCaptureService(
                meetingService: service, recorder: recorder, jobQueue: jobQueue, ruleMatcher: nil
            )

            let captured = LanguageBox()
            capture.finalizeTranscribeOverrideForTesting = { _, selection in
                captured.value = selection
                return TranscriptionResult(
                    text: "Final.", detectedLanguage: "de", duration: 1, processingTime: 0.1,
                    engineUsed: "stub", segments: [TranscriptionSegment(text: "Final.", start: 0, end: 1)]
                )
            }

            let meeting = service.createMeeting(title: "Finalize", source: .adHoc, state: .scheduled)
            service.setLanguage("de", for: meeting)

            try await capture.start(meeting: meeting)
            capture.ingestLiveTranscript("Live rough.", elapsed: 1)
            await capture.stop()
            await capture.awaitFinalizeTeardownForTesting()
            await jobQueue.drain()

            XCTAssertEqual(captured.value, .exact("de"), "final same-engine pass must honor the meeting language")
        }
    }

    /// Reference box so the `@Sendable` finalize override can record the selection it received.
    @MainActor
    private final class LanguageBox { var value: LanguageSelection? }
}
