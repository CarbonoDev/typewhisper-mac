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
    private let charBudget: Int

    init(
        meetingService: MeetingService,
        vaultService: ObsidianVaultService,
        processor: any PromptProcessing,
        charBudget: Int = TranscriptContextBuilder.defaultCharBudget
    ) {
        self.meetingService = meetingService
        self.vaultService = vaultService
        self.processor = processor
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
        let systemPrompt = String(localized: "meetings.brief.systemPrompt")
        let content = try await processor.process(
            prompt: systemPrompt,
            text: context,
            providerOverride: nil,
            cloudModelOverride: nil,
            temperatureDirective: .inheritProviderSetting,
            skipMemoryInjection: true
        )

        return meetingService.addOutput(
            to: meeting,
            kind: .brief,
            content: content,
            templateID: nil,
            providerUsed: resolvedProvider(),
            modelUsed: resolvedModel()
        )
    }

    // MARK: - Context blocks

    /// Prior related meetings rendered as labeled excerpts (their latest summary/extended/brief
    /// output when present, else a bounded transcript excerpt). Empty when there are none.
    private func priorMeetingsBlock(for meeting: Meeting) -> String {
        let prior = meetingService.priorMeetings(matching: meeting)
        guard !prior.isEmpty else { return "" }

        // Deterministic ordering: most recent first.
        let ordered = prior.sorted { lhs, rhs in
            (lhs.startDate ?? lhs.createdAt) > (rhs.startDate ?? rhs.createdAt)
        }

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
        let query = retrievalQuery(for: meeting)
        guard !query.isEmpty else { return "" }
        let passages = vaultService.retrieve(query: query, limit: 3)
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
    /// knowledge-base passages, truncated to the char budget (plan D7). Section headers are
    /// localized so the scaffolding matches the rest of the UI.
    private func assembleContext(meeting: Meeting, priorBlock: String, kbBlock: String) -> String {
        var sections: [String] = []

        var meta = ["\(String(localized: "meetings.brief.context.meetingLabel")) \(meeting.title)"]
        if let start = meeting.startDate {
            meta.append("\(String(localized: "meetings.brief.context.dateLabel")) \(start.formatted(date: .abbreviated, time: .shortened))")
        }
        let attendeeNames = meeting.attendees.map(\.name).filter { !$0.isEmpty }
        if !attendeeNames.isEmpty {
            meta.append("\(String(localized: "meetings.brief.context.attendeesLabel")) \(attendeeNames.joined(separator: ", "))")
        }
        sections.append(meta.joined(separator: "\n"))

        if !priorBlock.isEmpty {
            sections.append("\(String(localized: "meetings.brief.context.priorHeader"))\n\(priorBlock)")
        }
        if !kbBlock.isEmpty {
            sections.append("\(String(localized: "meetings.brief.context.knowledgeHeader"))\n\(kbBlock)")
        }

        let assembled = sections.joined(separator: "\n\n")
        return TranscriptContextBuilder.truncateWords(assembled, to: charBudget)
    }

    // MARK: - Provenance

    private func resolvedProvider() -> String? {
        let selected = processor.selectedProviderId.trimmingCharacters(in: .whitespacesAndNewlines)
        return selected.isEmpty ? nil : selected
    }

    private func resolvedModel() -> String? {
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
