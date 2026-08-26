import XCTest
import TypeWhisperPluginSDK
@testable import TypeWhisper

/// M2 — per-meeting language detection (plan D5). Covers `MeetingLanguageCatalog.normalize`
/// (codes/names accepted, garbage rejected), the `.detected` setter race guard, fail-closed detection
/// (unrecognized reply ⇒ job `.failed`, nothing persisted), per-call provider fallback, the
/// `.languageDetection` job's llm-lane placement + `(kind, meetingID)` dedupe + priority ordering, the
/// chip Detect/Re-detect flow, and the M1-review rule-seed normalization. All hermetic: the LLM call
/// is stubbed.
@MainActor
final class MeetingLanguageDetectionTests: XCTestCase {
    // MARK: - Fixtures

    private func makeStore() throws -> MeetingService {
        let dir = try TestSupport.makeTemporaryDirectory(prefix: "MeetingLangDetect")
        addTeardownBlock { TestSupport.remove(dir) }
        return MeetingService(appSupportDirectory: dir)
    }

    private func makeDefaults() -> UserDefaults {
        let suite = "MeetingLangDetect-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        return defaults
    }

    /// A resumable barrier so a stubbed detection can "hold" mid-call for the race test.
    @MainActor
    private final class Gate {
        private var waiters: [CheckedContinuation<Void, Never>] = []
        private var opened = false
        func wait() async { if opened { return }; await withCheckedContinuation { waiters.append($0) } }
        func open() {
            guard !opened else { return }
            opened = true
            let current = waiters; waiters = []
            current.forEach { $0.resume() }
        }
    }

    @MainActor
    private final class StubProcessor: PromptProcessing {
        var selectedProviderId = "prompt-provider"
        var selectedCloudModel = "prompt-model"
        private(set) var callCount = 0
        private(set) var lastProviderOverride: String?
        private(set) var lastModelOverride: String?
        private(set) var lastSkipMemory: Bool?
        var reply = "de"
        var gate: Gate?

        func process(
            prompt: String,
            text: String,
            providerOverride: String?,
            cloudModelOverride: String?,
            temperatureDirective: PluginLLMTemperatureDirective,
            skipMemoryInjection: Bool
        ) async throws -> String {
            callCount += 1
            lastProviderOverride = providerOverride
            lastModelOverride = cloudModelOverride
            lastSkipMemory = skipMemoryInjection
            if let gate { await gate.wait() }
            return reply
        }
    }

    private func makeService(
        store: MeetingService,
        processor: StubProcessor,
        jobQueue: JobQueueService,
        defaults: UserDefaults
    ) -> MeetingLanguageService {
        MeetingLanguageService(meetingService: store, processor: processor, jobQueue: jobQueue, defaults: defaults)
    }

    private func makeMeeting(on service: MeetingService, texts: [String] = ["Guten Morgen, wie geht es dir heute?"]) -> Meeting {
        let meeting = service.createMeeting(title: "M", source: .adHoc, state: .completed)
        var start = 0.0
        service.appendStableSegments(texts.map { t in
            defer { start += 2 }
            return TranscriptionSegment(text: t, start: start, end: start + 2)
        }, to: meeting)
        return meeting
    }

    // MARK: - Catalog normalize

    func testNormalizeAcceptsCodes() {
        XCTAssertEqual(MeetingLanguageCatalog.normalize("de"), "de")
        XCTAssertEqual(MeetingLanguageCatalog.normalize("EN"), "en")
        XCTAssertEqual(MeetingLanguageCatalog.normalize(" es "), "es")
        XCTAssertEqual(MeetingLanguageCatalog.normalize("de."), "de")     // trailing punctuation
        XCTAssertEqual(MeetingLanguageCatalog.normalize("\"fr\""), "fr")  // quoted
    }

    func testNormalizeAcceptsRegionTaggedCode() {
        XCTAssertEqual(MeetingLanguageCatalog.normalize("en-US"), "en")
        XCTAssertEqual(MeetingLanguageCatalog.normalize("pt_BR"), "pt")
    }

    func testNormalizeAcceptsLanguageNames() {
        XCTAssertEqual(MeetingLanguageCatalog.normalize("German"), "de")
        XCTAssertEqual(MeetingLanguageCatalog.normalize("Deutsch"), "de") // endonym / German-locale name
        XCTAssertEqual(MeetingLanguageCatalog.normalize("spanish"), "es")
    }

    func testNormalizeAcceptsMultiWordPhraseByName() {
        // A sentence resolves via the embedded language *name*, not stray 2-letter tokens.
        XCTAssertEqual(MeetingLanguageCatalog.normalize("The language is German."), "de")
    }

    func testNormalizeRejectsGarbage() {
        XCTAssertNil(MeetingLanguageCatalog.normalize("xyzzy"))
        XCTAssertNil(MeetingLanguageCatalog.normalize(""))
        XCTAssertNil(MeetingLanguageCatalog.normalize("   "))
        XCTAssertNil(MeetingLanguageCatalog.normalize(nil))
        XCTAssertNil(MeetingLanguageCatalog.normalize("I'm not sure which language this is"))
    }

    // MARK: - Lane placement

    func testLanguageDetectionRunsOnLLMLane() {
        XCTAssertEqual(MeetingJobKind.languageDetection.lane, .llm)
    }

    // MARK: - setDetectedLanguage ladder

    func testSetDetectedWritesOnlyWhenUnset() throws {
        let service = try makeStore()
        let meeting = service.createMeeting(title: "M", source: .adHoc, state: .completed)

        service.setDetectedLanguage("DE", for: meeting)
        XCTAssertEqual(meeting.languageCode, "de")
        XCTAssertEqual(meeting.languageProvenance, .detected)
    }

    func testSetDetectedNeverOverwritesManualOrRule() throws {
        let service = try makeStore()
        let manual = service.createMeeting(title: "Manual", source: .adHoc, state: .completed)
        service.setLanguage("en", for: manual)
        service.setDetectedLanguage("de", for: manual)
        XCTAssertEqual(manual.languageCode, "en")
        XCTAssertEqual(manual.languageProvenance, .manual)

        let ruled = service.createMeeting(title: "Ruled", source: .adHoc, state: .completed)
        service.seedRuleLanguage("fr", for: ruled)
        service.setDetectedLanguage("de", for: ruled)
        XCTAssertEqual(ruled.languageCode, "fr")
        XCTAssertEqual(ruled.languageProvenance, .rule)
    }

    // MARK: - Detection success / fail-closed

    func testDetectionPersistsDetectedLanguage() async throws {
        let store = try makeStore()
        let processor = StubProcessor(); processor.reply = "de"
        let service = makeService(store: store, processor: processor, jobQueue: JobQueueService(), defaults: makeDefaults())
        let meeting = makeMeeting(on: store)

        try await service.detectLanguage(for: meeting)

        XCTAssertEqual(meeting.languageCode, "de")
        XCTAssertEqual(meeting.languageProvenance, .detected)
        XCTAssertEqual(processor.callCount, 1)
        XCTAssertEqual(processor.lastSkipMemory, true, "detection must skip memory injection")
    }

    func testDetectionSkipsWhenAlreadySet() async throws {
        let store = try makeStore()
        let processor = StubProcessor()
        let service = makeService(store: store, processor: processor, jobQueue: JobQueueService(), defaults: makeDefaults())
        let meeting = makeMeeting(on: store)
        store.setLanguage("en", for: meeting)

        try await service.detectLanguage(for: meeting) // force == false

        XCTAssertEqual(processor.callCount, 0, "no LLM call when the language is already set")
        XCTAssertEqual(meeting.languageCode, "en")
    }

    func testGarbageReplyFailsClosedAndPersistsNothing() async throws {
        let store = try makeStore()
        let processor = StubProcessor(); processor.reply = "I have no idea"
        let service = makeService(store: store, processor: processor, jobQueue: JobQueueService(), defaults: makeDefaults())
        let meeting = makeMeeting(on: store)

        do {
            try await service.detectLanguage(for: meeting)
            XCTFail("expected an unrecognized-reply throw")
        } catch let error as MeetingLanguageService.DetectionError {
            guard case .unrecognizedReply = error else { return XCTFail("wrong error case") }
        }
        XCTAssertNil(meeting.languageCode, "a fail-closed detection writes nothing")
    }

    func testUnrecognizedReplyThroughJobMarksFailed() async throws {
        let store = try makeStore()
        let processor = StubProcessor(); processor.reply = "???"
        let jobQueue = JobQueueService()
        let service = makeService(store: store, processor: processor, jobQueue: jobQueue, defaults: makeDefaults())
        let meeting = makeMeeting(on: store)

        service.enqueueAutoDetection(for: meeting)
        await jobQueue.drain()

        let job = try XCTUnwrap(jobQueue.jobs(for: meeting.id).first { $0.kind == .languageDetection })
        guard case .failed = job.state else { return XCTFail("expected the job to be .failed, got \(job.state)") }
        XCTAssertNil(meeting.languageCode)
    }

    // MARK: - Provider resolution (per call)

    func testProviderFallsBackToPromptProviderWhenUnset() async throws {
        let store = try makeStore()
        let processor = StubProcessor(); processor.reply = "de"
        let service = makeService(store: store, processor: processor, jobQueue: JobQueueService(), defaults: makeDefaults())
        let meeting = makeMeeting(on: store)

        try await service.detectLanguage(for: meeting)

        XCTAssertNil(processor.lastProviderOverride, "empty setting ⇒ inherit prompt provider (nil override)")
        XCTAssertNil(processor.lastModelOverride)
    }

    func testConfiguredProviderIsPassedPerCall() async throws {
        let store = try makeStore()
        let processor = StubProcessor(); processor.reply = "de"
        let defaults = makeDefaults()
        defaults.set("groq", forKey: UserDefaultsKeys.meetingsLanguageDetectionProviderId)
        defaults.set("llama-3.1", forKey: UserDefaultsKeys.meetingsLanguageDetectionModel)
        let service = makeService(store: store, processor: processor, jobQueue: JobQueueService(), defaults: defaults)
        let meeting = makeMeeting(on: store)

        try await service.detectLanguage(for: meeting)

        XCTAssertEqual(processor.lastProviderOverride, "groq")
        XCTAssertEqual(processor.lastModelOverride, "llama-3.1")
    }

    // MARK: - Race: manual set during in-flight detection

    func testManualSetDuringInFlightDetectionIsNotClobbered() async throws {
        let store = try makeStore()
        let processor = StubProcessor(); processor.reply = "de"
        let gate = Gate(); processor.gate = gate
        let service = makeService(store: store, processor: processor, jobQueue: JobQueueService(), defaults: makeDefaults())
        let meeting = makeMeeting(on: store)

        // Start a detection that blocks inside `process`.
        let task = Task { try await service.detectLanguage(for: meeting) }
        // Let it reach the awaited gate.
        for _ in 0..<10 where processor.callCount == 0 { await Task.yield() }
        XCTAssertEqual(processor.callCount, 1)

        // User sets the language manually while detection is suspended.
        store.setLanguage("en", for: meeting)

        // Detection now completes and tries to persist "de" — the `setDetectedLanguage` nil-guard wins.
        gate.open()
        try await task.value

        XCTAssertEqual(meeting.languageCode, "en")
        XCTAssertEqual(meeting.languageProvenance, .manual)
    }

    // MARK: - Dedupe + priority

    func testAutoDetectDedupesByMeeting() async throws {
        let store = try makeStore()
        let processor = StubProcessor(); processor.reply = "de"
        let jobQueue = JobQueueService()
        let service = makeService(store: store, processor: processor, jobQueue: jobQueue, defaults: makeDefaults())
        let meeting = makeMeeting(on: store)

        // Two synchronous enqueues before the lane worker runs ⇒ the second dedupes.
        service.enqueueAutoDetection(for: meeting)
        service.enqueueAutoDetection(for: meeting)
        await jobQueue.drain()

        XCTAssertEqual(processor.callCount, 1, "(languageDetection, meetingID) dedupe collapses the pair")
        XCTAssertEqual(meeting.languageCode, "de")
    }

    func testBackgroundDetectionYieldsToUserInitiatedSummary() async throws {
        // Both jobs share the cap-1 llm lane; a userInitiated summary must run before a background
        // languageDetection enqueued first.
        let jobQueue = JobQueueService()
        let order = OrderRecorder()
        let meetingID = UUID()

        jobQueue.enqueue(kind: .languageDetection, meetingID: meetingID, priority: .background) {
            order.append("detect")
        }
        jobQueue.enqueue(kind: .summary, meetingID: meetingID, priority: .userInitiated) {
            order.append("summary")
        }
        await jobQueue.drain()

        XCTAssertEqual(order.values, ["summary", "detect"])
    }

    @MainActor
    private final class OrderRecorder {
        private(set) var values: [String] = []
        func append(_ v: String) { values.append(v) }
    }

    // MARK: - Chip Detect / Re-detect

    func testRequestUserDetectionNoOpWhenManual() async throws {
        let store = try makeStore()
        let processor = StubProcessor()
        let jobQueue = JobQueueService()
        let service = makeService(store: store, processor: processor, jobQueue: jobQueue, defaults: makeDefaults())
        let meeting = makeMeeting(on: store)
        store.setLanguage("en", for: meeting)

        let jobID = service.requestUserDetection(for: meeting)
        await jobQueue.drain()

        XCTAssertNil(jobID, "Detect is disabled for a manual pick — clear first")
        XCTAssertEqual(processor.callCount, 0)
        XCTAssertEqual(meeting.languageCode, "en")
    }

    func testRequestUserDetectionClearsThenReDetects() async throws {
        let store = try makeStore()
        let processor = StubProcessor(); processor.reply = "es"
        let jobQueue = JobQueueService()
        let service = makeService(store: store, processor: processor, jobQueue: jobQueue, defaults: makeDefaults())
        let meeting = makeMeeting(on: store)
        store.setDetectedLanguage("de", for: meeting) // a prior detection

        _ = service.requestUserDetection(for: meeting)
        await jobQueue.drain()

        XCTAssertEqual(processor.callCount, 1)
        XCTAssertEqual(meeting.languageCode, "es", "re-detect cleared the old value and wrote the fresh one")
        XCTAssertEqual(meeting.languageProvenance, .detected)
    }

    // MARK: - Rule-seed normalization (M1-review fix)

    func testSeedRuleLanguageNormalizesFreeTextName() throws {
        let service = try makeStore()
        let meeting = service.createMeeting(title: "M", source: .adHoc, state: .completed)

        // The rule editor stores free text; "german" ⇒ LanguageSelection.exact("german"). The seed must
        // normalize it to the canonical code, not persist "german" verbatim.
        service.seedRuleLanguage("german", for: meeting)

        XCTAssertEqual(meeting.languageCode, "de")
        XCTAssertEqual(meeting.languageProvenance, .rule)
    }

    func testSeedRuleLanguageSilentlySkipsGarbage() throws {
        let service = try makeStore()
        let meeting = service.createMeeting(title: "M", source: .adHoc, state: .completed)

        service.seedRuleLanguage("not-a-language", for: meeting)

        XCTAssertNil(meeting.languageCode, "unrecognizable rule text must not become a meeting language")
        XCTAssertNil(meeting.languageProvenance)
    }
}
