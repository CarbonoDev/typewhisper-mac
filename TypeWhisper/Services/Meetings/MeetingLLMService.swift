import Foundation
import Combine
import TypeWhisperPluginSDK
import os.log

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "TypeWhisper", category: "MeetingLLMService")

/// The single-turn LLM call seam used by the Meetings feature (plan M4 reuse note). Narrowed to
/// the one `process` method plus the current provider/model selection so unit tests can stub it
/// without constructing the whole `PromptProcessingService` / plugin graph. `PromptProcessingService`
/// conforms as-is.
@MainActor
protocol PromptProcessing: AnyObject {
    var selectedProviderId: String { get }
    var selectedCloudModel: String { get }

    func process(
        prompt: String,
        text: String,
        providerOverride: String?,
        cloudModelOverride: String?,
        temperatureDirective: PluginLLMTemperatureDirective,
        skipMemoryInjection: Bool
    ) async throws -> String
}

extension PromptProcessingService: PromptProcessing {}

/// Runs a `.meeting`-surface `PromptAction` (the unified meeting template, plan AD6) over a
/// meeting's transcript to produce a persisted `MeetingOutput`
/// (plan M4). Long transcripts are handled with a char-budget map/reduce (plan D7): each chunk is
/// summarized (map), then the partial summaries are reduced through the template's own prompt.
/// Transcripts that fit one chunk take the direct single-call path. In-meeting notes are appended
/// only when the meeting's `notesIncludedInOutputs` flag is set. Dictation memory is never
/// injected (plan D6: `skipMemoryInjection: true`).
@MainActor
final class MeetingLLMService: ObservableObject {
    @Published private(set) var isGenerating = false
    /// Per-meeting Q&A re-entrancy set (plan J2). Replaces the single `isAnswering` bool so asking a
    /// question in meeting A does not disable the Ask field in meeting B: a meeting id is present
    /// while that meeting's answer is in flight. Asking and generating an output stay independent.
    @Published private(set) var answeringMeetingIDs: Set<UUID> = []

    private let meetingService: MeetingService
    private let vaultService: ObsidianVaultService
    private let processor: any PromptProcessing
    /// Source of the per-folder `VaultRetrievalScope` (Amendment 1, DA6/F1): in-meeting Q&A honors the
    /// same folder scope as the brief so the two stay consistent. Optional so predating call sites/tests
    /// construct the service without it — a nil store keeps whole-vault retrieval (today's behavior).
    private let folderMetadataStore: MeetingFolderMetadataStore?
    private let charBudget: Int

    init(
        meetingService: MeetingService,
        vaultService: ObsidianVaultService,
        processor: any PromptProcessing,
        folderMetadataStore: MeetingFolderMetadataStore? = nil,
        charBudget: Int = TranscriptContextBuilder.defaultCharBudget
    ) {
        self.meetingService = meetingService
        self.vaultService = vaultService
        self.processor = processor
        self.folderMetadataStore = folderMetadataStore
        self.charBudget = charBudget
    }

    /// Generate an output for `meeting` from `template`, persist it as a new `MeetingOutput`, and
    /// return it. Regeneration always inserts a new row (history retained; the UI shows the
    /// newest per kind — plan D15). Throws if the meeting has no transcript, or the LLM call fails.
    @discardableResult
    func generateOutput(for meeting: Meeting, using template: PromptAction) async throws -> MeetingOutput {
        // Double-generation is prevented primarily by the job queue (plan J1/J2): the summary/extended
        // job dedupes on `(kind, meetingID)`, so a rapid double-click is dropped before this call ever
        // runs a second time. This synchronous flag is the last line of defense for any path that
        // reaches the service *without* going through the queue (or races its main-queue republish):
        // claimed here before the first `await`, mirroring `MeetingCaptureService.start()`'s
        // `isCapturing` placement, so two concurrent generations can never both persist an output.
        guard !isGenerating else { throw MeetingLLMError.alreadyGenerating }
        isGenerating = true
        defer { isGenerating = false }

        let segments = meeting.segments
            .sorted { $0.order < $1.order }
            .map { segment in
                TranscriptContextBuilder.Segment(
                    start: segment.start,
                    text: segment.text,
                    speaker: mappedSpeaker(for: segment, in: meeting)
                )
            }

        let transcript = TranscriptContextBuilder.renderTranscript(segments)
        guard !transcript.isEmpty else { throw MeetingLLMError.emptyTranscript }

        let notesBlock: String
        if meeting.notesIncludedInOutputs {
            let notes = meeting.notes
                .sorted { $0.createdAt < $1.createdAt }
                .map { TranscriptContextBuilder.Note(offset: $0.timestampOffset, text: $0.text) }
            notesBlock = TranscriptContextBuilder.renderNotes(notes)
        } else {
            notesBlock = ""
        }

        // Plan D4: the meeting's output language is enforced by a prompt directive appended to the
        // final-output prompt (direct path + reduce step), never the extractive map step.
        let languageDirective = MeetingLanguageDirective.instruction(for: meeting.languageCode)
        let content = try await runMapReduce(
            template: template,
            transcript: transcript,
            notes: notesBlock,
            languageDirective: languageDirective
        )

        return meetingService.addOutput(
            to: meeting,
            kind: template.meetingKind ?? .summary,
            content: content,
            templateID: template.id,
            providerUsed: resolvedProvider(for: template),
            modelUsed: resolvedModel(for: template)
        )
    }

    // MARK: - In-meeting Q&A (plan M6)

    /// Answer `question` against the meeting transcript so far plus the connected knowledge base and
    /// prior Q&A turns, then persist the result atomically as a `MeetingQATurn`. Single-turn call
    /// (plan D6: prior turns are replayed compactly inside the user text, `skipMemoryInjection`).
    ///
    /// `asOfOffset` scopes the transcript to elapsed seconds when asked mid-capture so an answer can
    /// never draw on words spoken after the question (nil = the whole transcript, for after-meeting
    /// questions). A failed LLM call throws and persists nothing; a successful call persists exactly
    /// one turn.
    @discardableResult
    func answerQuestion(
        for meeting: Meeting,
        question: String,
        asOfOffset offset: Double? = nil
    ) async throws -> MeetingQATurn {
        // Per-meeting synchronous re-entrancy guard claimed before the first `await`, mirroring
        // `generateOutput`. Scoped to *this* meeting (plan J2): a second question for the same meeting
        // while its answer is in flight is rejected, but a question for a different meeting proceeds.
        // A dedicated case (not `.alreadyGenerating`) so a Q&A double-submit surfaces a Q&A-worded
        // message via `qaErrorMessage` rather than "An output is already being generated" (M6 review
        // finding 3).
        guard !answeringMeetingIDs.contains(meeting.id) else { throw MeetingLLMError.alreadyAnswering }
        let trimmedQuestion = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuestion.isEmpty else { throw MeetingLLMError.emptyQuestion }
        answeringMeetingIDs.insert(meeting.id)
        defer { answeringMeetingIDs.remove(meeting.id) }

        let segments = meeting.segments
            .sorted { $0.order < $1.order }
            .map { segment in
                TranscriptContextBuilder.Segment(
                    start: segment.start,
                    text: segment.text,
                    speaker: mappedSpeaker(for: segment, in: meeting)
                )
            }

        let priorTurns = meeting.qaTurns
            .sorted { $0.createdAt < $1.createdAt }
            .map { MeetingQAComposer.PriorTurn(question: $0.question, answer: $0.answer) }

        // Knowledge-base passages only when a vault is connected (shared retriever with M5). Amendment 1
        // (DA6/F1) + Amendment 2 (DB5): the meeting's curated related notes ∪ folder config scope
        // retrieval identically to the brief — `.none` yields no passages, the curated union restricts,
        // no context keeps whole-vault behavior.
        let scope = retrievalScope(for: meeting)
        let passages = vaultService.isConnected
            ? vaultService.retrieve(query: trimmedQuestion, limit: 3, scope: scope)
            : []

        let userText = MeetingQAComposer.compose(
            question: trimmedQuestion,
            segments: segments,
            upTo: offset,
            priorTurns: priorTurns,
            knowledgePassages: passages,
            charBudget: charBudget
        )

        // Plan D4: the answer is the final output — append the meeting's language directive.
        let systemPrompt = MeetingLanguageDirective.appending(
            for: meeting.languageCode,
            to: String(localized: "meetings.qa.systemPrompt")
        )
        let answer = try await processor.process(
            prompt: systemPrompt,
            text: userText,
            providerOverride: nil,
            cloudModelOverride: nil,
            temperatureDirective: .inheritProviderSetting,
            skipMemoryInjection: true
        )

        return meetingService.addQATurn(to: meeting, question: trimmedQuestion, answer: answer)
    }

    /// The DB5 consumption scope for a meeting's Q&A retrieval — identical to the brief (Amendment 2,
    /// DB5): curated related notes ∪ folder attachment scope, `noVaultContext` absolute.
    private func retrievalScope(for meeting: Meeting) -> VaultRetrievalScope {
        guard let folderMetadataStore else { return .wholeVault }
        return folderMetadataStore.retrievalScope(
            forFolderPath: meeting.folderPath,
            curatedNotePaths: meeting.relatedNotePaths.map(\.path),
            excludedNotePaths: meeting.excludedNotePaths
        )
    }

    // MARK: - Map / reduce

    private func runMapReduce(
        template: PromptAction,
        transcript: String,
        notes: String,
        languageDirective: String?
    ) async throws -> String {
        let chunks = TranscriptContextBuilder.chunk(transcript, charBudget: charBudget)

        // Direct path: the transcript fits a single chunk — one call through the template prompt
        // (carrying the language directive, plan D4).
        guard chunks.count > 1 else {
            let userText = TranscriptContextBuilder.assemble(transcript: chunks.first ?? transcript, notes: notes)
            return try await run(
                template: template,
                prompt: MeetingLanguageDirective.appending(languageDirective, to: template.prompt),
                text: userText
            )
        }

        // Map: faithfully condense each chunk. The map instruction is deliberately extractive so
        // the reduce step (which applies the actual template) is not summarizing a summary of a
        // rephrase. Notes are attached only to the reduce input, never duplicated per chunk. The
        // language directive is deliberately withheld here (plan D4 / owner-veto 4) — translating at
        // the map stage would make the reduce input a lossy translation.
        let mapPrompt = String(localized: "meetings.output.mapPrompt")
        var partials: [String] = []
        partials.reserveCapacity(chunks.count)
        for (index, chunk) in chunks.enumerated() {
            let partial = try await run(template: template, prompt: mapPrompt, text: chunk)
            let trimmed = partial.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                let header = String(
                    format: String(localized: "meetings.output.partLabel"),
                    index + 1,
                    chunks.count
                )
                partials.append("\(header)\n\(trimmed)")
            }
        }

        // Reduce: apply the template's own prompt to the joined partial summaries + notes. The
        // joined partials (plus notes) can themselves exceed the char budget once there are enough
        // chunks, so use the *bounded* assembly (M4 review finding 3) to keep the single reduce call
        // within budget instead of sending an unbounded payload.
        let reduceInput = TranscriptContextBuilder.boundedAssemble(
            transcript: partials.joined(separator: "\n\n"),
            notes: notes,
            charBudget: charBudget
        )
        // Reduce is the final-output producer — it carries the language directive (plan D4).
        return try await run(
            template: template,
            prompt: MeetingLanguageDirective.appending(languageDirective, to: template.prompt),
            text: reduceInput
        )
    }

    private func run(template: PromptAction, prompt: String, text: String) async throws -> String {
        try await processor.process(
            prompt: prompt,
            text: text,
            providerOverride: template.providerType,
            cloudModelOverride: template.cloudModel,
            temperatureDirective: template.temperatureDirective,
            skipMemoryInjection: true
        )
    }

    // MARK: - Provenance

    /// Provider recorded on the output: the template override when set, else the current global
    /// selection.
    private func resolvedProvider(for template: PromptAction) -> String? {
        if let provider = template.providerType?.trimmingCharacters(in: .whitespacesAndNewlines),
           !provider.isEmpty {
            return provider
        }
        let selected = processor.selectedProviderId.trimmingCharacters(in: .whitespacesAndNewlines)
        return selected.isEmpty ? nil : selected
    }

    /// Model recorded on the output: the template override when set, else the current global
    /// selection (nil when neither exists, e.g. a provider with no model dimension).
    private func resolvedModel(for template: PromptAction) -> String? {
        if let model = template.cloudModel?.trimmingCharacters(in: .whitespacesAndNewlines),
           !model.isEmpty {
            return model
        }
        let selected = processor.selectedCloudModel.trimmingCharacters(in: .whitespacesAndNewlines)
        return selected.isEmpty ? nil : selected
    }

    /// The mapped attendee name for a segment's speaker label, if any (populated by M9). Inert
    /// while speaker maps are empty — segments render as bare text.
    private func mappedSpeaker(for segment: MeetingSegment, in meeting: Meeting) -> String? {
        guard let label = segment.speakerLabel, !label.isEmpty else { return nil }
        return meeting.speakerMap[label] ?? label
    }
}

enum MeetingLLMError: LocalizedError, Equatable {
    /// The meeting has no transcript text to generate an output from.
    case emptyTranscript
    /// A generation is already in progress on this service (re-entrancy guard, finding 1).
    case alreadyGenerating
    /// A Q&A answer is already in progress on this service (Q&A re-entrancy guard, M6 finding 3).
    case alreadyAnswering
    /// A Q&A question was empty after trimming (plan M6).
    case emptyQuestion

    var errorDescription: String? {
        switch self {
        case .emptyTranscript:
            return String(localized: "meetings.output.error.emptyTranscript")
        case .alreadyGenerating:
            return String(localized: "meetings.output.error.alreadyGenerating")
        case .alreadyAnswering:
            return String(localized: "meetings.qa.error.alreadyAnswering")
        case .emptyQuestion:
            return String(localized: "meetings.qa.error.emptyQuestion")
        }
    }
}

/// Pure, testable assembly of the single-turn user-text payload for an in-meeting Q&A question
/// (plan M6). Holds no SwiftData references so it can be unit-tested in isolation; the service maps
/// `MeetingSegment`/`MeetingQATurn`/`VaultPassage` into the value types it consumes.
///
/// Budget policy (plan D7, no tokenizer): the transcript gets ~half the char budget, prior turns a
/// quarter, and the assembled whole is truncated to the budget as a final guarantee. The transcript
/// slice keeps the chunks most *relevant to the question* (shared `LexicalRetriever` ranking) rather
/// than a blind prefix, then restores chronological order for a coherent excerpt.
enum MeetingQAComposer {
    /// A previously-answered turn, replayed compactly to give the model conversational continuity.
    struct PriorTurn: Sendable {
        let question: String
        let answer: String
    }

    static func compose(
        question: String,
        segments: [TranscriptContextBuilder.Segment],
        upTo offset: Double?,
        priorTurns: [PriorTurn],
        knowledgePassages: [VaultPassage],
        charBudget: Int = TranscriptContextBuilder.defaultCharBudget
    ) -> String {
        let question = question.trimmingCharacters(in: .whitespacesAndNewlines)

        // Only transcript up to the current offset: a mid-meeting question must not see the future.
        let visible = segments.filter { segment in
            guard let offset else { return true }
            return segment.start <= offset
        }

        let transcriptBudget = max(0, charBudget / 2)
        let relevantTranscript = selectRelevantTranscript(
            question: question,
            segments: visible,
            budget: transcriptBudget
        )

        let priorBudget = max(0, charBudget / 4)
        let priorBlock = renderPriorTurns(priorTurns, budget: priorBudget)

        // Give the knowledge base an explicit bounded slice (~a quarter of the budget) instead of
        // leaving it open-ended: `retrieve` can return up to three ~2,000-char passages (~6k chars
        // plus headers) which, added to a full transcript half and a quarter of prior turns, sum
        // well past the budget (M6 review finding 1). Mirror MeetingBriefService.assembleContext.
        let kbBudget = max(0, charBudget / 4)
        let kbBlock = TranscriptContextBuilder.truncateWords(renderPassages(knowledgePassages), to: kbBudget)

        var contextSections: [String] = []
        if !kbBlock.isEmpty {
            contextSections.append("\(String(localized: "meetings.qa.context.knowledgeHeader"))\n\(kbBlock)")
        }
        if !relevantTranscript.isEmpty {
            contextSections.append("\(String(localized: "meetings.qa.context.transcriptHeader"))\n\(relevantTranscript)")
        }
        if !priorBlock.isEmpty {
            contextSections.append("\(String(localized: "meetings.qa.context.priorHeader"))\n\(priorBlock)")
        }

        // Reserve the whole question section off the top before the final bound, then truncate only
        // the assembled context to leave room for it. The previous single `truncateWords(assembled,
        // to: charBudget)` kept the prefix, so the last section — the question — was the first thing
        // cut once the context sections summed past the budget, and the model received context with
        // no question (M6 review finding 1). Now the question always survives verbatim.
        let questionSection = "\(String(localized: "meetings.qa.context.questionHeader"))\n\(question)"
        let context = contextSections.joined(separator: "\n\n")
        let contextBudget = max(0, charBudget - questionSection.count - 2)
        let boundedContext = TranscriptContextBuilder.truncateWords(context, to: contextBudget)
        guard !boundedContext.isEmpty else { return questionSection }
        return "\(boundedContext)\n\n\(questionSection)"
    }

    // MARK: - Transcript selection

    /// Keep the transcript regions most relevant to `question` that fit `budget`, in chronological
    /// order. A transcript that already fits is returned whole; when nothing matches lexically the
    /// leading (chronological) portion is used.
    private static func selectRelevantTranscript(
        question: String,
        segments: [TranscriptContextBuilder.Segment],
        budget: Int
    ) -> String {
        guard budget > 0 else { return "" }
        let transcript = TranscriptContextBuilder.renderTranscript(segments)
        guard !transcript.isEmpty else { return "" }
        guard transcript.count > budget else { return transcript }

        // Chunk small enough that several chunks compete for the budget, so ranking has choices.
        let chunkBudget = max(1, budget / 3)
        let chunks = TranscriptContextBuilder.chunk(transcript, charBudget: chunkBudget)
        let documents = chunks.enumerated().map {
            LexicalRetriever.Document(id: String($0.offset), text: $0.element)
        }
        let ranked = LexicalRetriever.rank(query: question, documents: documents, limit: chunks.count)

        // No lexical overlap → fall back to the leading portion of the transcript.
        guard !ranked.isEmpty else {
            return TranscriptContextBuilder.truncateWords(transcript, to: budget)
        }

        var selectedIndices: [Int] = []
        var used = 0
        for result in ranked {
            guard let index = Int(result.id) else { continue }
            let addition = chunks[index].count + (selectedIndices.isEmpty ? 0 : 2)
            if used + addition > budget { continue }
            selectedIndices.append(index)
            used += addition
        }

        // Even the top chunk overflows the slice → truncate it to fit.
        guard !selectedIndices.isEmpty else {
            if let top = ranked.first, let index = Int(top.id) {
                return TranscriptContextBuilder.truncateWords(chunks[index], to: budget)
            }
            return TranscriptContextBuilder.truncateWords(transcript, to: budget)
        }

        return selectedIndices.sorted().map { chunks[$0] }.joined(separator: "\n\n")
    }

    // MARK: - Prior turns & passages

    /// Replay prior turns compactly, in chronological order, bounded to `budget`. When the history
    /// exceeds the budget the *oldest* turns are dropped, not the newest: a follow-up question
    /// depends most on the recent exchange, so recency is preserved (M6 review finding 2).
    private static func renderPriorTurns(_ turns: [PriorTurn], budget: Int) -> String {
        guard budget > 0, !turns.isEmpty else { return "" }
        let qLabel = String(localized: "meetings.qa.context.questionLabel")
        let aLabel = String(localized: "meetings.qa.context.answerLabel")
        let render: (PriorTurn) -> String = { turn in
            let q = turn.question.trimmingCharacters(in: .whitespacesAndNewlines)
            let a = turn.answer.trimmingCharacters(in: .whitespacesAndNewlines)
            return "\(qLabel) \(q)\n\(aLabel) \(a)"
        }

        // Accumulate newest-first (turns arrive oldest→newest) until the budget is spent, keeping the
        // newest turns and dropping the oldest.
        var kept: [PriorTurn] = []
        var used = 0
        for turn in turns.reversed() {
            let addition = render(turn).count + (kept.isEmpty ? 0 : 2) // "\n\n" between blocks
            if used + addition > budget { break }
            kept.append(turn)
            used += addition
        }

        // Not even the newest turn fits whole → keep it, truncated.
        guard let newest = turns.last else { return "" }
        guard !kept.isEmpty else {
            return TranscriptContextBuilder.truncateWords(render(newest), to: budget)
        }

        // Render the kept turns back in chronological order (oldest→newest).
        return kept.reversed().map(render).joined(separator: "\n\n")
    }

    private static func renderPassages(_ passages: [VaultPassage]) -> String {
        passages
            .map { passage in
                let tagSuffix = passage.tags.isEmpty ? "" : " [\(passage.tags.joined(separator: ", "))]"
                return "### \(passage.title)\(tagSuffix)\n\(passage.content)"
            }
            .joined(separator: "\n\n")
    }
}
