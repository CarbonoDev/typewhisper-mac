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
    /// Per-meeting set of answers currently in a model-requested **vault-search escalation** round
    /// (pass 2). Present only while the escalation retrieval + re-ask is in flight; a subset of
    /// `answeringMeetingIDs`. Exposed VM-agnostically so the UI can surface a "Searching your vault…"
    /// status. NOTE: the UI hookup is a deliberate follow-up — no view consumes this yet.
    @Published private(set) var searchingVaultMeetingIDs: Set<UUID> = []
    /// `searchingVaultMeetingIDs`' twin for the D-M4 email escalation ([Google Phase 3 · M4]):
    /// inserted before the email retrieval, cleared in the same `defer`; identical
    /// no-view-consumes-this-yet posture.
    @Published private(set) var searchingEmailsMeetingIDs: Set<UUID> = []

    private let meetingService: MeetingService
    private let vaultService: ObsidianVaultService
    private let processor: any PromptProcessing
    /// Source of the per-folder `VaultRetrievalScope` (Amendment 1, DA6/F1): in-meeting Q&A honors the
    /// same folder scope as the brief so the two stay consistent. Optional so predating call sites/tests
    /// construct the service without it — a nil store keeps whole-vault retrieval (today's behavior).
    private let folderMetadataStore: MeetingFolderMetadataStore?
    /// Per-purpose model router (plan D9/M4): resolves `template > purpose > app default` for the
    /// `summariesAnalysis` (output generation) and `qa` (in-meeting Q&A) purposes, per call. Defaulted
    /// so predating call sites/tests construct the service without it — a nil router builds one over the
    /// service's processor + `.standard` defaults, where an unset purpose collapses to the prior
    /// `template ?? app default` behavior.
    private let modelRouter: MeetingModelRouter
    /// The D-M4 email-escalation seam ([Google Phase 3 · M4]) — meeting-centric Gmail retrieval.
    /// Nil-defaulted so every predating call site and test compiles unchanged; nil means "no email
    /// escalation source" (the M3 `MeetingBriefService` pattern).
    private let gmailService: GmailContextRetrieving?
    private let charBudget: Int

    init(
        meetingService: MeetingService,
        vaultService: ObsidianVaultService,
        processor: any PromptProcessing,
        folderMetadataStore: MeetingFolderMetadataStore? = nil,
        modelRouter: MeetingModelRouter? = nil,
        gmailService: GmailContextRetrieving? = nil,
        charBudget: Int = TranscriptContextBuilder.defaultCharBudget
    ) {
        self.meetingService = meetingService
        self.vaultService = vaultService
        self.processor = processor
        self.folderMetadataStore = folderMetadataStore
        self.modelRouter = modelRouter ?? MeetingModelRouter(processor: processor)
        self.gmailService = gmailService
        self.charBudget = charBudget
    }

    /// Generate an output for `meeting` from `template`, persist it as a new `MeetingOutput`, and
    /// return it. Regeneration always inserts a new row (history retained; the UI shows the
    /// newest per kind — plan D15). Throws if the meeting has no transcript, or the LLM call fails.
    ///
    /// `providerOverride`/`modelOverride` (plan M5/D10) are a one-shot pick from a Generate/Regenerate
    /// menu: they win the routing ladder for *this run only* (`one-shot > template > purpose > app
    /// default`) and are persisted nowhere — only recorded in the output's provenance. Both default nil,
    /// so existing call sites keep today's `template > purpose > app default` behavior.
    @discardableResult
    func generateOutput(
        for meeting: Meeting,
        using template: PromptAction,
        providerOverride: String? = nil,
        modelOverride: String? = nil
    ) async throws -> MeetingOutput {
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
            languageDirective: languageDirective,
            providerOverride: providerOverride,
            modelOverride: modelOverride
        )

        return meetingService.addOutput(
            to: meeting,
            kind: template.meetingKind ?? .summary,
            content: content,
            templateID: template.id,
            providerUsed: resolvedProvider(for: template, oneShotProvider: providerOverride),
            modelUsed: resolvedModel(for: template, oneShotModel: modelOverride, oneShotProvider: providerOverride)
        )
    }

    // MARK: - In-meeting Q&A (plan M6)

    /// Answer `question` about the meeting and persist the result atomically as a `MeetingQATurn`.
    ///
    /// Grounding is **meeting-first, escalation-on-demand** (owner decision):
    ///  - Pass 1 (default) grounds ONLY on the meeting's own material — transcript so far, prior Q&A
    ///    turns, and the meeting's related documents (including auto-discovered ones the user can
    ///    remove) and explicit folder attachments. NO broad vault retrieval: neither the whole-vault
    ///    default fallback nor any folder-prefix *search* runs here.
    ///  - Pass 2 (escalation, model-chosen, at most one round) runs only if the model replies with a
    ///    single `VAULT_SEARCH: <terms>` line — its signal that the meeting material does not cover the
    ///    question but vault knowledge plausibly would. The host then runs ONE retrieval round at the
    ///    escalation scope (folder scope when the meeting has one, else whole vault), re-composes with
    ///    the retrieved excerpts clearly labeled as secondary, and re-asks. Empty results, a second
    ///    `VAULT_SEARCH` reply (loop guard), or no connected vault all resolve to a "not covered" answer;
    ///    a real pass-2 answer is prefixed with a localized disclosure that vault notes were consulted.
    ///    The marker itself never surfaces to the user.
    ///
    /// `asOfOffset` scopes the transcript to elapsed seconds when asked mid-capture so an answer can
    /// never draw on words spoken after the question (nil = the whole transcript, for after-meeting
    /// questions). A failed LLM call throws and persists nothing; a successful call persists exactly
    /// one turn. `skipMemoryInjection` on both passes (plan D6).
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
        defer {
            answeringMeetingIDs.remove(meeting.id)
            searchingVaultMeetingIDs.remove(meeting.id)
            searchingEmailsMeetingIDs.remove(meeting.id)
        }

        let segments = meeting.segments
            .sorted { $0.order < $1.order }
            .map { segment in
                TranscriptContextBuilder.Segment(
                    start: segment.start,
                    text: segment.text,
                    speaker: mappedSpeaker(for: segment, in: meeting)
                )
            }

        // The primary grounding for a Q&A answer is *this* meeting's own transcript. If that meeting
        // has no transcript visible for the question, refuse rather than silently answering from
        // retrieval-only context — the fix for the cross-meeting leak (owner report): without this
        // guard an empty own-transcript let the composer build a knowledge-base-only prompt and the
        // model answered from a *different* meeting's note that whole-vault retrieval had surfaced.
        // Mirrors `generateOutput`'s `emptyTranscript` guard. The offset filter matches the composer's
        // `segment.start <= offset` rule so a mid-capture question asked before anything is spoken is
        // refused too, instead of falling back to foreign material.
        let visibleSegments = offset.map { limit in segments.filter { $0.start <= limit } } ?? segments
        let ownTranscript = TranscriptContextBuilder.renderTranscript(visibleSegments)
        guard !ownTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MeetingLLMError.noTranscriptContext
        }

        let priorTurns = meeting.qaTurns
            .sorted { $0.createdAt < $1.createdAt }
            .map { MeetingQAComposer.PriorTurn(question: $0.question, answer: $0.answer) }

        // ── PASS 1 (DEFAULT): ground ONLY on the meeting's own material ────────────────────────────
        // Owner decision: broad vault retrieval is OFF by default. The vault contributes only the
        // meeting's related documents (including auto-discovered ones — user-visible on the meeting,
        // removable, with sticky exclusions, so effectively under user curation) and explicit folder
        // note attachments. `curatedScope` never expands a folder-prefix *search* and never falls back
        // to the whole-vault default — those are deferred to model-requested escalation below. `.none`
        // (nothing curated / `noVaultContext`) yields no passages.
        let curatedPassages = vaultService.isConnected
            ? vaultService.retrieve(query: trimmedQuestion, limit: 3, scope: curatedScope(for: meeting))
            : []

        let pass1Text = MeetingQAComposer.compose(
            question: trimmedQuestion,
            segments: segments,
            upTo: offset,
            priorTurns: priorTurns,
            knowledgePassages: curatedPassages,
            charBudget: charBudget
        )
        // The `VAULT_SEARCH` invitation is extended only when a vault is actually available to search —
        // never invite the model to escalate into a void. The pass-2 no-vault degradation below stays
        // as a safety net should the model emit the marker unprompted. Identically, the D-M4
        // `EMAIL_SEARCH` invitation is extended only when Gmail is connected for THIS meeting
        // ([Google Phase 3 · M4]) — neither, one, or both may be appended.
        var pass1Base = String(localized: "meetings.qa.systemPrompt")
        if vaultService.isConnected {
            pass1Base += " " + String(localized: "meetings.qa.systemPrompt.vaultSearchInvitation")
        }
        if let gmailService, gmailService.isConnected(for: meeting) {
            pass1Base += " " + String(localized: "meetings.qa.systemPrompt.emailSearchInvitation")
        }
        // Plan D4: the answer is the final output — append the meeting's language directive.
        let pass1Prompt = MeetingLanguageDirective.appending(for: meeting.languageCode, to: pass1Base)
        let pass1Answer = try await runQA(userText: pass1Text, systemPrompt: pass1Prompt)

        // The model is instructed to reply with exactly one marker line and nothing else — but real
        // replies sometimes wrap the marker in prose ("I couldn't find this…\nVAULT_SEARCH: …"), so
        // a marker line at ANY line start counts as the escalation request. Pass 1 is scanned for
        // BOTH markers (D-M4): either or both trigger the single escalation round below. A reply
        // with no marker line is a normal answer: persist it, stripped of marker lines (both forms)
        // as defense-in-depth — mid-sentence mentions are neither markers nor stripped.
        //
        // A marker counts as an escalation request ONLY when its source's invitation could have been
        // in the prompt — vault marker iff `vaultService.isConnected`, email marker iff Gmail is
        // connected for this meeting (review finding, symmetric on both sources). An *unprompted*
        // marker from a source that was never offered is not a request the host can serve: honoring
        // it used to route a perfectly good pass-1 answer into the empty-retrieval guard below,
        // which replaced the user's answer with the generic "not covered" text. Such a reply is a
        // normal answer — persisted with its marker lines stripped (the token never surfaces), and
        // degrading to "not covered" only when stripping leaves nothing behind.
        let vaultTerms = vaultService.isConnected ? MeetingQAComposer.vaultSearchTerms(in: pass1Answer) : nil
        let gmailConnected = gmailService?.isConnected(for: meeting) ?? false
        let emailTerms = gmailConnected ? MeetingQAComposer.emailSearchTerms(in: pass1Answer) : nil
        guard vaultTerms != nil || emailTerms != nil else {
            let sanitized = MeetingQAComposer.strippingEscalationLines(from: pass1Answer)
            return meetingService.addQATurn(
                to: meeting,
                question: trimmedQuestion,
                answer: sanitized.isEmpty ? String(localized: "meetings.qa.answer.notCovered") : sanitized
            )
        }

        // ── PASS 2 (ESCALATION, model-chosen, exactly ONE round across BOTH sources — D-M4) ───────
        // Every retrieval the model requested runs within this single round; there is never a third
        // LLM pass. Vault: the existing escalation scope (folder scope when the meeting has one,
        // else whole vault). Emails: the meeting-centric Gmail seam with the marker's terms (bare
        // marker falls back to the question text; the service's D-M2 window already covers the
        // meeting day). A Gmail failure degrades to "emails contributed nothing" — never fails the
        // answer (the M3 philosophy).
        // Both `vaultTerms` and `emailTerms` are non-nil only for a source that is actually
        // available (the gating above), so neither retrieval needs a second connectivity check.
        var retrievedPassages: [VaultPassage] = []
        if let vaultTerms {
            searchingVaultMeetingIDs.insert(meeting.id)
            let searchTerms = vaultTerms.isEmpty ? trimmedQuestion : vaultTerms
            retrievedPassages = vaultService.retrieve(
                query: searchTerms, limit: 3, scope: retrievalScope(for: meeting)
            )
        }
        var retrievedEmails: [EmailPassage] = []
        if let emailTerms, let gmailService {
            searchingEmailsMeetingIDs.insert(meeting.id)
            let searchTerms = emailTerms.isEmpty ? trimmedQuestion : emailTerms
            do {
                retrievedEmails = try await gmailService.retrieve(for: meeting, query: searchTerms, limit: 3)
            } catch {
                logger.warning("Q&A email escalation degraded to empty: \(error.localizedDescription)")
            }
        }
        // Every requested retrieval came back empty (or its source is unavailable) ⇒ skip pass 2
        // and answer "not covered". No marker ever surfaces to the user.
        guard !retrievedPassages.isEmpty || !retrievedEmails.isEmpty else {
            return meetingService.addQATurn(
                to: meeting,
                question: trimmedQuestion,
                answer: String(localized: "meetings.qa.answer.notCovered")
            )
        }

        // Re-compose: pass-1 material + every non-empty retrieved block, clearly labeled as
        // secondary to the transcript.
        let pass2Text = MeetingQAComposer.compose(
            question: trimmedQuestion,
            segments: segments,
            upTo: offset,
            priorTurns: priorTurns,
            knowledgePassages: curatedPassages,
            retrievedPassages: retrievedPassages,
            retrievedEmailPassages: retrievedEmails,
            charBudget: charBudget
        )
        let pass2Prompt = MeetingLanguageDirective.appending(
            for: meeting.languageCode,
            to: String(localized: "meetings.qa.systemPrompt.escalated")
        )
        let pass2Answer = try await runQA(userText: pass2Text, systemPrompt: pass2Prompt)

        // Loop guard + sanitizer: there is never a third round, whatever pass 2 replies. Any marker
        // line — EITHER form (D-M4) — is stripped before persisting, never honored; if the model
        // wrapped usable prose around a marker, the prose is kept, and if stripping leaves nothing
        // (a pure re-request), degrade to the localized "not covered" answer.
        let sanitizedPass2 = MeetingQAComposer.strippingEscalationLines(from: pass2Answer)
        guard !sanitizedPass2.isEmpty else {
            return meetingService.addQATurn(
                to: meeting,
                question: trimmedQuestion,
                answer: String(localized: "meetings.qa.answer.notCovered")
            )
        }

        // Disclose (localized, natural) what was actually consulted beyond the meeting: the prefix
        // reflects the non-empty retrieved blocks that fed pass 2 (D-M4).
        let disclosurePrefix: String
        if !retrievedPassages.isEmpty && !retrievedEmails.isEmpty {
            disclosurePrefix = String(localized: "meetings.qa.answer.vaultAndEmailsConsultedPrefix")
        } else if !retrievedEmails.isEmpty {
            disclosurePrefix = String(localized: "meetings.qa.answer.emailsConsultedPrefix")
        } else {
            disclosurePrefix = String(localized: "meetings.qa.answer.vaultConsultedPrefix")
        }
        let disclosedAnswer = disclosurePrefix + "\n\n" + sanitizedPass2
        return meetingService.addQATurn(to: meeting, question: trimmedQuestion, answer: disclosedAnswer)
    }

    /// The single-turn Q&A LLM call, shared by both passes so the per-purpose routing (plan D9/M4:
    /// `.qa`) and the `skipMemoryInjection` / temperature policy are applied identically on the
    /// escalation pass as on the default pass. No template rung for Q&A, so `template ?? purpose`; a nil
    /// override inherits the app default (today's behavior when the purpose is unset).
    private func runQA(userText: String, systemPrompt: String) async throws -> String {
        try await processor.process(
            prompt: systemPrompt,
            text: userText,
            providerOverride: modelRouter.overrideProvider(for: .qa),
            cloudModelOverride: modelRouter.overrideModel(for: .qa),
            temperatureDirective: .inheritProviderSetting,
            skipMemoryInjection: true
        )
    }

    /// The **pass-1** (default) Q&A retrieval scope: the meeting's related documents (including
    /// auto-discovered ones the user can remove) ∪ the folder's explicitly attached notes (minus
    /// exclusions), never a folder-prefix search and never the whole-vault fallback (owner decision —
    /// broad vault retrieval is off by default). Delegates to the folder store when present; without a
    /// store, restricts to the meeting's own related notes (`.none` when there are none, so retrieval
    /// yields nothing rather than falling back to whole-vault).
    private func curatedScope(for meeting: Meeting) -> VaultRetrievalScope {
        let curated = meeting.relatedNotePaths.map(\.path)
        let excluded = meeting.excludedNotePaths
        guard let folderMetadataStore else {
            let notePaths = Set(curated).subtracting(Set(excluded))
            guard !notePaths.isEmpty else { return .none }
            return .restricted(notePaths: notePaths, folderPrefixes: [], excludedPaths: Set(excluded))
        }
        return folderMetadataStore.curatedRetrievalScope(
            forFolderPath: meeting.folderPath,
            curatedNotePaths: curated,
            excludedNotePaths: excluded
        )
    }

    /// The **escalation** (pass-2) Q&A retrieval scope — the full DB5 consumption scope, identical to the
    /// brief (Amendment 2, DB5): curated related notes ∪ folder attachment scope (including folder-prefix
    /// search), `noVaultContext` absolute, whole-vault when nothing is configured. Only ever run after
    /// the model requests a `VAULT_SEARCH` escalation.
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
        languageDirective: String?,
        providerOverride: String? = nil,
        modelOverride: String? = nil
    ) async throws -> String {
        let chunks = TranscriptContextBuilder.chunk(transcript, charBudget: charBudget)

        // Direct path: the transcript fits a single chunk — one call through the template prompt
        // (carrying the language directive, plan D4).
        guard chunks.count > 1 else {
            let userText = TranscriptContextBuilder.assemble(transcript: chunks.first ?? transcript, notes: notes)
            return try await run(
                template: template,
                prompt: MeetingLanguageDirective.appending(languageDirective, to: template.prompt),
                text: userText,
                providerOverride: providerOverride,
                modelOverride: modelOverride
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
            let partial = try await run(
                template: template, prompt: mapPrompt, text: chunk,
                providerOverride: providerOverride, modelOverride: modelOverride
            )
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
            text: reduceInput,
            providerOverride: providerOverride,
            modelOverride: modelOverride
        )
    }

    private func run(
        template: PromptAction,
        prompt: String,
        text: String,
        providerOverride: String? = nil,
        modelOverride: String? = nil
    ) async throws -> String {
        // Plan D9/M4 + D10/M5: `one-shot > template > purpose(summariesAnalysis) > app default`, resolved
        // per call. A nil one-shot AND nil template/purpose inherits the app default (today's behavior).
        try await processor.process(
            prompt: prompt,
            text: text,
            providerOverride: modelRouter.overrideProvider(
                for: .summariesAnalysis, templateProvider: template.providerType, oneShotProvider: providerOverride
            ),
            cloudModelOverride: modelRouter.overrideModel(
                for: .summariesAnalysis, templateModel: template.cloudModel,
                oneShotModel: modelOverride, oneShotProvider: providerOverride
            ),
            temperatureDirective: template.temperatureDirective,
            skipMemoryInjection: true
        )
    }

    // MARK: - Provenance

    /// Provider recorded on the output: the effective value that actually ran under the full ladder
    /// `one-shot > template > purpose(summariesAnalysis) > app default` (plan D9/M4 + D10/M5 — provenance
    /// must follow the same rungs the call does so `providerUsed` never lies, including a one-shot pick).
    private func resolvedProvider(for template: PromptAction, oneShotProvider: String? = nil) -> String? {
        modelRouter.effectiveProvider(
            for: .summariesAnalysis, templateProvider: template.providerType, oneShotProvider: oneShotProvider
        )
    }

    /// Model recorded on the output: the effective value under the same ladder (nil when even the app
    /// default is empty, e.g. a provider with no model dimension).
    private func resolvedModel(
        for template: PromptAction, oneShotModel: String? = nil, oneShotProvider: String? = nil
    ) -> String? {
        modelRouter.effectiveModel(
            for: .summariesAnalysis, templateModel: template.cloudModel,
            oneShotModel: oneShotModel, oneShotProvider: oneShotProvider
        )
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
    /// The meeting has no transcript visible for the question, so a Q&A answer cannot be grounded in
    /// this meeting's own content. Surfaced instead of silently answering from retrieval-only context
    /// (which could draw on a different meeting's note) — cross-meeting-leak fix.
    case noTranscriptContext

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
        case .noTranscriptContext:
            return String(localized: "meetings.qa.error.noTranscript")
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

    /// The machine marker the model emits to request one vault-search escalation round (instructed to
    /// be its entire reply; detected on any line start because models sometimes wrap it in prose). NOT
    /// localized — it is a literal token the host greps for, embedded verbatim in the EN and DE
    /// `meetings.qa.systemPrompt.vaultSearchInvitation` strings.
    static let vaultSearchMarker = "VAULT_SEARCH:"

    /// The second escalation marker ([Google Phase 3 · M4], D-M4): one email-search request beside
    /// the vault one, same line-prefix detection contract. NOT localized — embedded verbatim in the
    /// EN and DE `meetings.qa.systemPrompt.emailSearchInvitation` strings (the `vaultSearchMarker`
    /// precedent above).
    static let emailSearchMarker = "EMAIL_SEARCH:"

    /// Detects the model's vault escalation request. The model is instructed to emit the marker as
    /// its *entire* reply, but real replies sometimes wrap it in prose (e.g. "I couldn't find this in
    /// the meeting.\nVAULT_SEARCH: acme roadmap"), so the FIRST line whose trimmed form begins with
    /// the marker — at any line start, case-insensitive — is honored. Returns that line's remainder,
    /// trimmed, as the search terms (`""` for a bare marker so the caller can fall back to the
    /// question's text), or `nil` when no line starts with the marker. A mid-sentence mention (not at
    /// a line start) never fires.
    static func vaultSearchTerms(in answer: String) -> String? {
        terms(in: answer, marker: vaultSearchMarker)
    }

    /// `vaultSearchTerms`' twin for the D-M4 email marker — identical line-prefix contract.
    static func emailSearchTerms(in answer: String) -> String? {
        terms(in: answer, marker: emailSearchMarker)
    }

    private static func terms(in answer: String, marker: String) -> String? {
        for line in answer.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmedLine = line.trimmingCharacters(in: .whitespaces)
            guard trimmedLine.uppercased().hasPrefix(marker) else { continue }
            return String(trimmedLine.dropFirst(marker.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    /// Removes every line whose trimmed form begins with EITHER escalation marker (case-insensitive,
    /// matching the detection predicates exactly) so a machine token is never persisted or shown,
    /// even when the model wraps it in prose. Mid-sentence mentions are kept — they are not markers.
    /// Returns the remaining text with outer whitespace trimmed; an all-marker reply collapses to
    /// `""` (the caller substitutes the localized "not covered" answer). Supersedes
    /// `strippingVaultSearchLines` (D-M4) — both marker forms are always stripped, whichever source
    /// is connected, so an unprompted token can never leak into a persisted answer.
    static func strippingEscalationLines(from answer: String) -> String {
        answer
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { line in
                let upper = line.trimmingCharacters(in: .whitespaces).uppercased()
                return !upper.hasPrefix(vaultSearchMarker) && !upper.hasPrefix(emailSearchMarker)
            }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Call-through kept for predating call sites/tests (D-M4) — stripping now always covers both
    /// marker forms.
    static func strippingVaultSearchLines(from answer: String) -> String {
        strippingEscalationLines(from: answer)
    }

    /// - Parameter retrievedPassages: pass-2 escalation excerpts, retrieved from the vault only after the
    ///   model asked for a search. Rendered under a distinct "secondary to the transcript" header so
    ///   they are dropped early under budget pressure and never displace the meeting's own content.
    ///   Empty on the default (pass-1) path.
    /// - Parameter retrievedEmailPassages: pass-2 email excerpts ([Google Phase 3 · M4], D-M4),
    ///   retrieved via the Gmail seam only after an `EMAIL_SEARCH:` request. Rendered LAST — after
    ///   the retrieved-vault block — under their own header with their own budget slice, so under
    ///   pressure the prefix-keeping final bound drops email excerpts first. Like both vault
    ///   sections, withheld entirely when the transcript is empty.
    static func compose(
        question: String,
        segments: [TranscriptContextBuilder.Segment],
        upTo offset: Double?,
        priorTurns: [PriorTurn],
        knowledgePassages: [VaultPassage],
        retrievedPassages: [VaultPassage] = [],
        retrievedEmailPassages: [EmailPassage] = [],
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

        // Escalation-only: vault excerpts retrieved because the model asked for a search. Budgeted like
        // the curated KB and rendered LAST (see ordering note below) so they can never displace the
        // transcript, prior turns, or the curated notes.
        let retrievedBudget = max(0, charBudget / 4)
        let retrievedBlock = TranscriptContextBuilder.truncateWords(renderPassages(retrievedPassages), to: retrievedBudget)

        // Escalation-only email excerpts (D-M4): own slice, rendered last of all.
        let emailBudget = max(0, charBudget / 4)
        let emailBlock = TranscriptContextBuilder.truncateWords(renderEmailPassages(retrievedEmailPassages), to: emailBudget)

        // The meeting's OWN transcript is the primary grounding and leads the context; prior turns
        // (this meeting's own Q&A history) follow; curated notes are *supplementary*; escalation-retrieved
        // excerpts are *secondary* and come last. Ordering is load-bearing for the cross-meeting-leak fix:
        // the final bound below keeps the prefix, so putting supplementary/secondary vault content last
        // means it is the first thing dropped under budget pressure and can never displace the transcript.
        // Both vault sections are withheld entirely when there is no transcript to supplement — retrieval
        // must never stand in as the sole grounding (defense-in-depth behind the service's guard).
        var contextSections: [String] = []
        if !relevantTranscript.isEmpty {
            contextSections.append("\(String(localized: "meetings.qa.context.transcriptHeader"))\n\(relevantTranscript)")
        }
        if !priorBlock.isEmpty {
            contextSections.append("\(String(localized: "meetings.qa.context.priorHeader"))\n\(priorBlock)")
        }
        if !kbBlock.isEmpty, !relevantTranscript.isEmpty {
            contextSections.append("\(String(localized: "meetings.qa.context.knowledgeHeader"))\n\(kbBlock)")
        }
        if !retrievedBlock.isEmpty, !relevantTranscript.isEmpty {
            contextSections.append("\(String(localized: "meetings.qa.context.retrievedHeader"))\n\(retrievedBlock)")
        }
        if !emailBlock.isEmpty, !relevantTranscript.isEmpty {
            contextSections.append("\(String(localized: "meetings.qa.context.emailsHeader"))\n\(emailBlock)")
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

    /// The M3 brief block's citation shape, reused for Q&A email excerpts (D-M4).
    private static func renderEmailPassages(_ passages: [EmailPassage]) -> String {
        passages
            .map { passage in
                let dateLabel = passage.date.formatted(date: .abbreviated, time: .omitted)
                return "### \(passage.subject) — \(passage.from), \(dateLabel)\n\(passage.content)"
            }
            .joined(separator: "\n\n")
    }
}
