import Foundation
import Combine
import TypeWhisperPluginSDK
import os.log

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "TypeWhisper", category: "MeetingBriefService")

/// Generates a pre-meeting brief (plan M5): it gathers summaries of prior related meetings
/// (`MeetingService.priorMeetings(matching:)` — shared attendee email OR recurrence series) and
/// relevant knowledge-base passages from the connected Obsidian vault, assembles them into a
/// budget-bounded context (plan D7), makes one single-turn LLM call (`skipMemoryInjection: true`,
/// plan D6), and persists the result as a `MeetingOutput(kind: .brief)` (plan D15).
///
/// Degrades gracefully: with no vault it uses prior meetings only; with no prior meetings it uses
/// vault passages only; with neither it throws `insufficientContext` (never a crash).
@MainActor
final class MeetingBriefService: ObservableObject {
    @Published private(set) var isGenerating = false

    private let meetingService: MeetingService
    private let vaultService: ObsidianVaultService
    private let processor: any PromptProcessing
    /// Source of the editable `.brief` template (plan M6, amendment DA2). Optional so unit tests and
    /// any call site that predates templating construct the service without a prompt store; a nil
    /// store (or no `.brief` template) falls back to the built-in `meetings.brief.systemPrompt`.
    private let promptActionService: PromptActionService?
    /// Source of the per-folder `VaultRetrievalScope` (Amendment 1, DA5): the meeting's folder config
    /// restricts brief knowledge-base retrieval to attached notes/folders (or disables it). Optional so
    /// tests/call sites that predate folder context construct the service without it — a nil store
    /// keeps whole-vault retrieval (today's behavior).
    private let folderMetadataStore: MeetingFolderMetadataStore?
    private let charBudget: Int

    /// Cap on how many prior related meetings feed a brief (most recent first). Bounds cost and
    /// stops a long history from dominating the budget (M5 review finding 2).
    private let maxPriorMeetings = 5

    init(
        meetingService: MeetingService,
        vaultService: ObsidianVaultService,
        processor: any PromptProcessing,
        promptActionService: PromptActionService? = nil,
        folderMetadataStore: MeetingFolderMetadataStore? = nil,
        charBudget: Int = TranscriptContextBuilder.defaultCharBudget
    ) {
        self.meetingService = meetingService
        self.vaultService = vaultService
        self.processor = processor
        self.promptActionService = promptActionService
        self.folderMetadataStore = folderMetadataStore
        self.charBudget = charBudget
    }

    /// Build and persist a brief for `meeting`. Regeneration inserts a new `.brief` row; the UI
    /// shows the newest (history retained — plan D15).
    @discardableResult
    func generateBrief(for meeting: Meeting) async throws -> MeetingOutput {
        // Synchronous re-entrancy guard (mirrors `MeetingLLMService`): claim the flag before the
        // first `await` so a double-click can't launch two concurrent briefs.
        guard !isGenerating else { throw MeetingBriefError.alreadyGenerating }
        isGenerating = true
        defer { isGenerating = false }

        let priorBlock = priorMeetingsBlock(for: meeting)
        let kbBlock = knowledgeBaseBlock(for: meeting)

        guard !priorBlock.isEmpty || !kbBlock.isEmpty else {
            throw MeetingBriefError.insufficientContext
        }

        let context = assembleContext(meeting: meeting, priorBlock: priorBlock, kbBlock: kbBlock)

        // Plan M6 (amendment DA1/DA2): the brief prompt is now a user-editable `.brief` template.
        // Resolve the first `.brief` template (sort-ordered) as the system prompt — identical to how
        // summary/extended templates work (`template.prompt` = instruction layer, the assembled
        // context stays the `text` argument). Falls back to the built-in `meetings.brief.systemPrompt`
        // so a user who deleted every brief template never breaks briefs. The template's
        // provider/model/temperature overrides are honored (mirroring `MeetingLLMService.run`), and
        // its id is recorded on the output.
        let template = promptActionService?.meetingTemplates(ofKind: .brief).first
        let basePrompt = template?.prompt ?? String(localized: "meetings.brief.systemPrompt")
        // Plan D4: the brief is a final output — the meeting's language directive is appended on top
        // of the resolved template (or the fallback default).
        let systemPrompt = MeetingLanguageDirective.appending(
            for: meeting.languageCode,
            to: basePrompt
        )
        let content = try await processor.process(
            prompt: systemPrompt,
            text: context,
            providerOverride: template?.providerType,
            cloudModelOverride: template?.cloudModel,
            temperatureDirective: template?.temperatureDirective ?? .inheritProviderSetting,
            skipMemoryInjection: true
        )

        return meetingService.addOutput(
            to: meeting,
            kind: .brief,
            content: content,
            templateID: template?.id,
            providerUsed: resolvedProvider(for: template),
            modelUsed: resolvedModel(for: template)
        )
    }

    // MARK: - Context blocks

    /// Prior related meetings rendered as labeled excerpts (their latest summary/extended/brief
    /// output when present, else a bounded transcript excerpt). Empty when there are none.
    private func priorMeetingsBlock(for meeting: Meeting) -> String {
        let prior = meetingService.priorMeetings(matching: meeting)
        guard !prior.isEmpty else { return "" }

        // Deterministic ordering: most recent first, capped so a long history can't crowd out the
        // knowledge-base section (M5 review finding 2).
        let ordered = prior.sorted { lhs, rhs in
            (lhs.startDate ?? lhs.createdAt) > (rhs.startDate ?? rhs.createdAt)
        }.prefix(maxPriorMeetings)

        var entries: [String] = []
        for prev in ordered {
            guard let excerpt = summaryExcerpt(for: prev) else { continue }
            let dateLabel = (prev.startDate ?? prev.createdAt).formatted(date: .abbreviated, time: .omitted)
            entries.append("### \(prev.title) (\(dateLabel))\n\(excerpt)")
        }
        return entries.joined(separator: "\n\n")
    }

    /// The best available textual summary of a prior meeting for brief context: newest summary,
    /// else newest extended, else newest brief, else a bounded transcript excerpt.
    private func summaryExcerpt(for meeting: Meeting) -> String? {
        for kind in [MeetingOutputKind.summary, .extended, .brief] {
            if let output = meetingService.latestOutput(ofKind: kind, for: meeting) {
                let trimmed = output.content.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    return TranscriptContextBuilder.truncateWords(trimmed, to: charBudget / 4)
                }
            }
        }
        let transcript = TranscriptContextBuilder.renderTranscript(
            meeting.segments
                .sorted { $0.order < $1.order }
                .map { TranscriptContextBuilder.Segment(start: $0.start, text: $0.text) }
        )
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return TranscriptContextBuilder.truncateWords(trimmed, to: charBudget / 4)
    }

    /// Relevant vault passages rendered as labeled excerpts. Empty when no vault is connected or
    /// nothing matches.
    private func knowledgeBaseBlock(for meeting: Meeting) -> String {
        guard vaultService.isConnected else { return "" }
        // Amendment 1 (DA5): the meeting's folder config scopes vault retrieval. `.none` (the folder's
        // "No vault context" toggle) ⇒ an empty KB block (brief falls back to prior meetings only);
        // no folder config / no attachments ⇒ `.wholeVault` (today's behavior).
        let scope = folderMetadataStore?.retrievalScope(forFolderPath: meeting.folderPath) ?? .wholeVault
        if case .none = scope { return "" }
        let query = retrievalQuery(for: meeting)
        guard !query.isEmpty else { return "" }
        let passages = vaultService.retrieve(query: query, limit: 3, scope: scope)
        guard !passages.isEmpty else { return "" }
        return passages
            .map { passage in
                let tagSuffix = passage.tags.isEmpty ? "" : " [\(passage.tags.joined(separator: ", "))]"
                return "### \(passage.title)\(tagSuffix)\n\(passage.content)"
            }
            .joined(separator: "\n\n")
    }

    /// The lexical query used to find relevant vault notes: the meeting title plus attendee names.
    private func retrievalQuery(for meeting: Meeting) -> String {
        var terms = [meeting.title]
        terms.append(contentsOf: meeting.attendees.map(\.name))
        return terms.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Assembly

    /// Compose and bound the final brief context: meeting metadata, prior-meeting summaries, and
    /// knowledge-base passages (plan D7). Section headers are localized so the scaffolding matches
    /// the rest of the UI.
    ///
    /// Rather than truncate the whole joined string at the end — which let several substantial prior
    /// meetings silently truncate the knowledge-base block away entirely (M5 review finding 2) — the
    /// KB block is guaranteed a reserved slice (~a quarter of the budget) and the prior-meeting block
    /// absorbs the remainder. Each block carries a localized truncation notice when it is cut.
    private func assembleContext(meeting: Meeting, priorBlock: String, kbBlock: String) -> String {
        let notice = String(localized: "meetings.output.truncationNotice")
        var sections: [String] = []

        var meta = ["\(String(localized: "meetings.brief.context.meetingLabel")) \(meeting.title)"]
        if let start = meeting.startDate {
            meta.append("\(String(localized: "meetings.brief.context.dateLabel")) \(start.formatted(date: .abbreviated, time: .shortened))")
        }
        let attendeeNames = meeting.attendees.map(\.name).filter { !$0.isEmpty }
        if !attendeeNames.isEmpty {
            meta.append("\(String(localized: "meetings.brief.context.attendeesLabel")) \(attendeeNames.joined(separator: ", "))")
        }
        let metaSection = meta.joined(separator: "\n")
        sections.append(metaSection)

        // Reserve a quarter of the budget for the knowledge base so prior meetings can't crowd it
        // out; the prior block gets whatever is left after meta + that reservation.
        var runningLength = metaSection.count
        let kbReserve = kbBlock.isEmpty ? 0 : charBudget / 4

        if !priorBlock.isEmpty {
            let priorHeader = String(localized: "meetings.brief.context.priorHeader")
            let priorBudget = max(0, charBudget - runningLength - kbReserve - priorHeader.count - 4)
            let bounded = bound(priorBlock, to: priorBudget, notice: notice)
            let section = "\(priorHeader)\n\(bounded)"
            sections.append(section)
            runningLength += section.count + 2
        }
        if !kbBlock.isEmpty {
            let kbHeader = String(localized: "meetings.brief.context.knowledgeHeader")
            // The KB block gets all the remaining budget (at least the reserved slice).
            let kbBudget = max(0, charBudget - runningLength - kbHeader.count - 4)
            let bounded = bound(kbBlock, to: kbBudget, notice: notice)
            sections.append("\(kbHeader)\n\(bounded)")
        }

        let assembled = sections.joined(separator: "\n\n")
        return TranscriptContextBuilder.truncateWords(assembled, to: charBudget)
    }

    /// Truncate `text` at a word boundary to `budget`, appending `notice` when content is cut.
    private func bound(_ text: String, to budget: Int, notice: String) -> String {
        guard budget > 0, text.count > budget else { return text }
        let truncated = TranscriptContextBuilder.truncateWords(text, to: max(0, budget - notice.count - 1))
        return "\(truncated) \(notice)"
    }

    // MARK: - Provenance

    /// Provider recorded on the brief: the resolved template's override when set, else the current
    /// global selection (mirrors `MeetingLLMService.resolvedProvider`).
    private func resolvedProvider(for template: PromptAction?) -> String? {
        if let provider = template?.providerType?.trimmingCharacters(in: .whitespacesAndNewlines),
           !provider.isEmpty {
            return provider
        }
        let selected = processor.selectedProviderId.trimmingCharacters(in: .whitespacesAndNewlines)
        return selected.isEmpty ? nil : selected
    }

    /// Model recorded on the brief: the resolved template's override when set, else the current
    /// global selection (mirrors `MeetingLLMService.resolvedModel`).
    private func resolvedModel(for template: PromptAction?) -> String? {
        if let model = template?.cloudModel?.trimmingCharacters(in: .whitespacesAndNewlines),
           !model.isEmpty {
            return model
        }
        let selected = processor.selectedCloudModel.trimmingCharacters(in: .whitespacesAndNewlines)
        return selected.isEmpty ? nil : selected
    }
}

enum MeetingBriefError: LocalizedError, Equatable {
    /// Neither a prior related meeting nor a connected vault produced any usable context.
    case insufficientContext
    /// A brief generation is already in progress on this service.
    case alreadyGenerating

    var errorDescription: String? {
        switch self {
        case .insufficientContext:
            return String(localized: "meetings.brief.error.insufficientContext")
        case .alreadyGenerating:
            return String(localized: "meetings.brief.error.alreadyGenerating")
        }
    }
}
