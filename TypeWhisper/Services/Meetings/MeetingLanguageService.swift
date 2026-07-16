import Foundation
import Combine
import TypeWhisperPluginSDK
import os.log

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "TypeWhisper", category: "MeetingLanguageService")

/// Validates and normalizes a language token (a detection reply, or a free-text capture-rule value)
/// against the app's spoken-language catalog (plan D5). Accepts an ISO code (`de`, `en-US`) **or** a
/// language name in English, German, or the language's own endonym (`German`, `Deutsch`), and returns
/// a canonical lowercased code drawn from `defaultSpokenLanguageCodes`, or `nil` for anything it does
/// not recognize.
///
/// This is the single choke point that makes detection **fail-closed**: a garbage/uncertain reply
/// normalizes to `nil`, so `MeetingLanguageService.detectLanguage` throws and the job fails visibly
/// instead of persisting nonsense. It is also reused at rule-seed time (`MeetingService.seedRuleLanguage`)
/// so a rule's free-text language field can never write a bogus code onto a meeting.
enum MeetingLanguageCatalog {
    /// The recognized spoken-language codes (the app's spoken-language set, lowercased).
    static let knownCodes: Set<String> = Set(defaultSpokenLanguageCodes.map { $0.lowercased() })

    /// Lowercased language-name → code, built from English, German, and endonym display names of every
    /// known code. Names that collide across codes keep the first (catalog-ordered) code — collisions
    /// among the spoken-language set are between near-synonyms and are not user-observable here.
    private static let nameToCode: [String: String] = {
        var map: [String: String] = [:]
        let nameLocales = [Locale(identifier: "en"), Locale(identifier: "de")]
        for code in defaultSpokenLanguageCodes {
            let lower = code.lowercased()
            var names: [String] = []
            for locale in nameLocales {
                if let name = locale.localizedString(forIdentifier: code) { names.append(name) }
            }
            // The language's own endonym (e.g. "Deutsch", "日本語").
            if let endonym = Locale(identifier: code).localizedString(forIdentifier: code) {
                names.append(endonym)
            }
            for name in names {
                let key = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                guard !key.isEmpty else { continue }
                if map[key] == nil { map[key] = lower }
            }
        }
        return map
    }()

    /// Normalize `raw` to a known lowercased code, or `nil` when unrecognized.
    ///
    /// Strategy (fail-closed, tolerant of the common model phrasings "de", "de.", "German", "en-US"):
    /// 1. Clean to a single lowercased token (strip surrounding quotes/punctuation).
    /// 2. Whole-token match against the code set, then the base of a region-tagged code (`en-us` → `en`),
    ///    then the name map.
    /// 3. If — and only if — the reply is a multi-word phrase ("The language is German."), scan its
    ///    word tokens against the **name map only**, never bare codes: many English function words
    ///    ("is" = Icelandic, "no" = Norwegian, "it" = Italian) collide with 2-letter ISO codes, so
    ///    matching stray codes inside a sentence would false-positive.
    static func normalize(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let cleaned = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'`.,:;!?()[]{}“”‘’"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !cleaned.isEmpty else { return nil }

        if let code = matchSingleToken(cleaned) { return code }

        // Multi-word phrase: match language names only (never bare codes).
        if cleaned.contains(where: { $0 == " " || $0 == "\n" || $0 == "\t" }) {
            if let code = nameToCode[cleaned] { return code }
            let words = cleaned.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" })
            for word in words {
                let key = String(word).trimmingCharacters(in: CharacterSet(charactersIn: "\"'`.,:;!?()[]{}“”‘’"))
                if !key.isEmpty, let code = nameToCode[key] { return code }
            }
        }
        return nil
    }

    /// Match a single cleaned token against the code set (exact, then region-base), then the name map.
    private static func matchSingleToken(_ token: String) -> String? {
        if knownCodes.contains(token) { return token }
        if let separatorIndex = token.firstIndex(where: { $0 == "-" || $0 == "_" }) {
            let base = String(token[token.startIndex..<separatorIndex])
            if knownCodes.contains(base) { return base }
        }
        if let code = nameToCode[token] { return code }
        return nil
    }
}

/// Per-meeting spoken-language **detection** (plan D5, M2). Runs a single cheap LLM call over a
/// transcript sample to infer the language of an as-yet-unset meeting, then persists it as
/// `.detected` through `MeetingService.setDetectedLanguage` (which never overwrites a manual or rule
/// value). Detection is **fail-closed**: an unrecognized reply throws, so the wrapping job fails
/// visibly and nothing is written.
///
/// Enqueue happens through the shared `JobQueueService` on the cap-1 `llm` lane so a detection is
/// never concurrent with a user generation: `.background` when auto-triggered at a transcript-ready
/// choke point, `.userInitiated` from the Language chip's Detect / Re-detect action. Dedupe is the
/// default `(languageDetection, meetingID)`.
@MainActor
final class MeetingLanguageService: ObservableObject {
    /// A detection reply the catalog could not resolve — surfaced as a visible, retryable job failure
    /// (plan D5 / owner-veto 6: fail closed, not a silent no-op).
    enum DetectionError: LocalizedError {
        case unrecognizedReply(String)

        var errorDescription: String? {
            switch self {
            case .unrecognizedReply:
                return String(localized: "meetings.language.detect.error.unrecognized")
            }
        }
    }

    /// Characters of transcript sampled for the detection call — enough to disambiguate a language,
    /// far below any provider context window (a language is obvious within a few sentences).
    static let defaultSampleCharBudget = 2_000

    private let meetingService: MeetingService
    private let processor: any PromptProcessing
    private let jobQueue: JobQueueService
    private let defaults: UserDefaults
    /// Per-purpose model router (plan D9/M4): the `languageDetection` purpose reuses the existing
    /// `meetings.language.detection*` keys, so routing through it preserves the exact prior behavior
    /// while unifying resolution under one ladder. Defaulted so predating tests construct without it —
    /// a nil router is built over this service's processor + the same `defaults`.
    private let modelRouter: MeetingModelRouter
    private let sampleCharBudget: Int

    init(
        meetingService: MeetingService,
        processor: any PromptProcessing,
        jobQueue: JobQueueService,
        defaults: UserDefaults = .standard,
        modelRouter: MeetingModelRouter? = nil,
        sampleCharBudget: Int = MeetingLanguageService.defaultSampleCharBudget
    ) {
        self.meetingService = meetingService
        self.processor = processor
        self.jobQueue = jobQueue
        self.defaults = defaults
        self.modelRouter = modelRouter ?? MeetingModelRouter(processor: processor, defaults: defaults)
        self.sampleCharBudget = sampleCharBudget
    }

    // MARK: - Enqueue

    /// Auto-enqueue a `.background` detection at a transcript-ready choke point, **only** when the
    /// meeting has no language yet (plan D5). Idempotent by the queue's `(languageDetection, meetingID)`
    /// dedupe; a no-op when the language is already set.
    func enqueueAutoDetection(for meeting: Meeting) {
        guard meeting.languageCode == nil else { return }
        enqueueDetection(for: meeting, force: false, priority: .background)
    }

    /// User-initiated Detect / Re-detect from the Language chip (plan D1/D9). Enabled only when the
    /// provenance is not `.manual` (the UI disables it with a "clear first" hint; this guard is the
    /// programmatic backstop). It **clears** any standing `.rule`/`.detected` value first so the
    /// re-detect re-runs, then enqueues a `.userInitiated` job. Returns the job id, or `nil` when the
    /// language is a manual pick (no-op).
    @discardableResult
    func requestUserDetection(for meeting: Meeting) -> UUID? {
        guard meeting.languageProvenance != .manual else { return nil }
        meetingService.clearLanguage(for: meeting)
        return enqueueDetection(for: meeting, force: false, priority: .userInitiated)
    }

    @discardableResult
    private func enqueueDetection(
        for meeting: Meeting,
        force: Bool,
        priority: MeetingJobPriority
    ) -> UUID {
        jobQueue.enqueue(
            kind: .languageDetection,
            meetingID: meeting.id,
            priority: priority,
            progressLabel: String(localized: "meetings.jobs.progress.detectingLanguage")
        ) { [weak self] in
            try await self?.detectLanguage(for: meeting, force: force)
        }
    }

    // MARK: - Detection

    /// Detect and persist a meeting's language (the `.languageDetection` job body; also directly
    /// unit-tested with a stubbed `processor`).
    ///
    /// 1. Guard: run only when `force` or the meeting is unset (re-checked here so a `.background` job
    ///    that was queued before a manual pick no-ops).
    /// 2. Sample a truncated transcript rendering (one cheap call — no map/reduce).
    /// 3. Ask the resolved detection provider for the language code.
    /// 4. Normalize via `MeetingLanguageCatalog` — an unrecognized reply throws (fail-closed).
    /// 5. Persist via `setDetectedLanguage` (ladder-checked: never over manual/rule).
    func detectLanguage(for meeting: Meeting, force: Bool = false) async throws {
        guard force || meeting.languageCode == nil else { return }
        let sample = detectionSample(for: meeting)
        // Nothing to detect (no transcript yet) — quietly succeed rather than fail; the transcript-ready
        // choke points only enqueue once a transcript exists, so this is a defensive guard.
        guard !sample.isEmpty else { return }

        let reply = try await processor.process(
            prompt: Self.detectionPrompt,
            text: sample,
            providerOverride: resolvedProviderOverride,
            cloudModelOverride: resolvedModelOverride,
            temperatureDirective: .inheritProviderSetting,
            skipMemoryInjection: true
        )

        guard let code = MeetingLanguageCatalog.normalize(reply) else {
            logger.debug("Language detection reply not recognized; failing the job")
            throw DetectionError.unrecognizedReply(reply)
        }
        meetingService.setDetectedLanguage(code, for: meeting)
    }

    /// Render a truncated transcript sample for the detection call. Speaker names are intentionally
    /// omitted — the raw spoken text is what identifies the language.
    private func detectionSample(for meeting: Meeting) -> String {
        let segments = meeting.segments
            .sorted { $0.order < $1.order }
            .map { TranscriptContextBuilder.Segment(start: $0.start, text: $0.text) }
        let full = TranscriptContextBuilder.renderTranscript(segments)
        return TranscriptContextBuilder.truncateWords(full, to: sampleCharBudget)
    }

    // MARK: - Provider resolution (per call, never snapshotted — plan D5 / D9 / UX risk 8)

    /// The configured detection provider id, or `nil` to inherit the current prompt-provider selection
    /// (empty/unset default). Resolved inside the detector, per call, via the shared router's
    /// `languageDetection` purpose (which reads the same `meetings.language.detection*` keys).
    private var resolvedProviderOverride: String? {
        modelRouter.overrideProvider(for: .languageDetection)
    }

    /// The configured detection model id, or `nil` for the provider default.
    private var resolvedModelOverride: String? {
        modelRouter.overrideModel(for: .languageDetection)
    }

    /// The terse detection instruction. Kept as a stable English scaffold (models follow English
    /// instructions most reliably) and never shown to the user, so it is not localized.
    static let detectionPrompt = """
    Identify the primary spoken language of the transcript below. \
    Reply with ONLY the ISO 639-1 language code (for example: en, de, es, fr, pt, zh). \
    Do not add any explanation, punctuation, quotation marks, or extra words.
    """
}
