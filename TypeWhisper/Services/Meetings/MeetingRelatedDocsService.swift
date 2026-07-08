import Foundation
import Combine
import TypeWhisperPluginSDK
import os.log

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "TypeWhisper", category: "MeetingRelatedDocsService")

/// Agentic related-document discovery for a meeting (Amendment 2, DB1/DB2). Searches the connected
/// vault folder-first (already-known material auto-kept) then wider (junk-filtered by an LLM relevance
/// judge) to produce a per-meeting curated set of `discovered` related notes. The only writer of the
/// `discovered` set is `MeetingService.setDiscoveredRelatedNotes` (DB4).
///
/// Staged pipeline (DB2):
/// - **Stage (a) — folder-attached context** (Amendment 1, DA4): auto-kept, **never** sent to the
///   judge, **never** persisted here (it stays live folder scope, DB5). It is the known-good floor.
/// - **Stage (b) — wider-vault lexical candidates**: the whole vault ranked against the meeting query,
///   with every already-covered path excluded (stage-(a) notes, attached folder prefixes, existing
///   `manual` paths, and `excludedNotePaths`). Capped at `maxCandidates` (DB7).
/// - **Judge**: one `process()` call (`skipMemoryInjection: true`) returning the kept candidate indices
///   under the strict integer-list / `NONE` contract (DB3). **Fail-closed**: an unparseable reply
///   persists nothing and throws so the job is `.failed` and visible.
@MainActor
final class MeetingRelatedDocsService: ObservableObject {
    nonisolated(unsafe) static var _shared: MeetingRelatedDocsService?
    static var shared: MeetingRelatedDocsService {
        guard let instance = _shared else {
            fatalError("MeetingRelatedDocsService not initialized")
        }
        return instance
    }

    private let meetingService: MeetingService
    private let vaultService: ObsidianVaultService
    private let folderMetadataStore: MeetingFolderMetadataStore
    private let processor: any PromptProcessing

    /// Budget caps (DB7); constructor-injected so tests can shrink them.
    private let charBudget: Int
    private let maxCandidates: Int
    private let candidateExcerptCap: Int
    /// Cap on how many prior related meetings feed the judge signal (mirrors `MeetingBriefService`).
    private let maxPriorMeetings = 5

    init(
        meetingService: MeetingService,
        vaultService: ObsidianVaultService,
        folderMetadataStore: MeetingFolderMetadataStore,
        processor: any PromptProcessing,
        charBudget: Int = TranscriptContextBuilder.defaultCharBudget,
        maxCandidates: Int = 24,
        candidateExcerptCap: Int = 240
    ) {
        self.meetingService = meetingService
        self.vaultService = vaultService
        self.folderMetadataStore = folderMetadataStore
        self.processor = processor
        self.charBudget = charBudget
        self.maxCandidates = maxCandidates
        self.candidateExcerptCap = candidateExcerptCap
    }

    /// Discover related documents for `meeting`. The single entry point (DB1). On a parseable judgment
    /// it replaces the `discovered` set (empty on `NONE` / no candidates); on an unparseable judge reply
    /// it **throws** and persists nothing (fail-closed, DB3). A missing vault is a no-op (nothing to do).
    func discoverRelated(for meeting: Meeting) async throws {
        guard vaultService.isConnected else { return }

        let config = folderMetadataStore.config(for: meeting.folderPath ?? "")

        // Stage (a): folder-attached context — auto-kept, never judged, never persisted here.
        let folderNotes = Set(config.attachedNotePaths)
        let folderPrefixes = config.attachedFolderPaths
        let manualPaths = Set(meeting.relatedNotePaths.filter { $0.provenance == .manual }.map(\.path))
        let excluded = Set(meeting.excludedNotePaths)
        // Every already-covered *path* (stage-(a) notes + existing manual + excluded); prefixes handled
        // component-wise inside `candidateNotes`.
        let coveredPaths = folderNotes.union(manualPaths).union(excluded)

        let query = retrievalQuery(for: meeting)
        guard !query.isEmpty else {
            // No signal to search on — a valid "nothing found" result (success, zero discovered).
            meetingService.setDiscoveredRelatedNotes([], for: meeting)
            return
        }

        // Stage (b): wider-vault lexical candidates (capped, DB7).
        let candidates = vaultService.candidateNotes(
            query: query,
            limit: maxCandidates,
            excludingPaths: coveredPaths,
            excludingFolderPrefixes: folderPrefixes,
            excerptCap: candidateExcerptCap
        )
        guard !candidates.isEmpty else {
            meetingService.setDiscoveredRelatedNotes([], for: meeting)
            return
        }

        // Judge: one single-turn call over the meeting signals + candidate list.
        let judgeInput = assembleJudgeInput(meeting: meeting, candidates: candidates)
        let reply = try await processor.process(
            prompt: String(localized: "meetings.related.judge.systemPrompt"),
            text: judgeInput,
            providerOverride: nil,
            cloudModelOverride: nil,
            temperatureDirective: .inheritProviderSetting,
            skipMemoryInjection: true
        )

        // Fail-closed parse (DB3): a throw here persists nothing and marks the job `.failed`.
        let keptIndices = try Self.parseJudgeReply(reply, candidateCount: candidates.count)
        let keptPaths = keptIndices.map { candidates[$0].path }
        meetingService.setDiscoveredRelatedNotes(keptPaths, for: meeting)
    }

    // MARK: - Judge input assembly (DB2/DB7)

    /// The lexical query the wider-vault ranking runs on: the meeting title plus attendee names
    /// (mirrors `MeetingBriefService.retrievalQuery`).
    private func retrievalQuery(for meeting: Meeting) -> String {
        var terms = [meeting.title]
        terms.append(contentsOf: meeting.attendees.map(\.name))
        return terms.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Assemble the judge's `text` payload: the meeting signals, a bounded prior-meeting summary
    /// excerpt, and the 1-based candidate list (title + folder path + capped excerpt). Truncated to
    /// `charBudget` as the final guarantee (DB7).
    private func assembleJudgeInput(meeting: Meeting, candidates: [ObsidianVaultService.VaultCandidate]) -> String {
        var sections: [String] = []

        var meta = ["\(String(localized: "meetings.brief.context.meetingLabel")) \(meeting.title)"]
        if let start = meeting.startDate {
            meta.append("\(String(localized: "meetings.brief.context.dateLabel")) \(start.formatted(date: .abbreviated, time: .omitted))")
        }
        let attendeeNames = meeting.attendees.map(\.name).filter { !$0.isEmpty }
        if !attendeeNames.isEmpty {
            meta.append("\(String(localized: "meetings.brief.context.attendeesLabel")) \(attendeeNames.joined(separator: ", "))")
        }
        if let folder = meeting.folderPath, !folder.isEmpty {
            meta.append("\(String(localized: "meetings.brief.context.folderLabel")) \(folder)")
        }
        sections.append(meta.joined(separator: "\n"))

        let priorBlock = priorMeetingsBlock(for: meeting)
        if !priorBlock.isEmpty {
            sections.append("\(String(localized: "meetings.brief.context.priorHeader"))\n\(priorBlock)")
        }

        var candidateLines: [String] = []
        for (index, candidate) in candidates.enumerated() {
            let folderCaption = candidate.folderPath.isEmpty ? "" : " — \(candidate.folderPath)"
            candidateLines.append("\(index + 1). \(candidate.title)\(folderCaption)\n\(candidate.excerpt)")
        }
        sections.append("\(String(localized: "meetings.related.judge.candidatesHeader"))\n\(candidateLines.joined(separator: "\n\n"))")

        let assembled = sections.joined(separator: "\n\n")
        return TranscriptContextBuilder.truncateWords(assembled, to: charBudget)
    }

    /// A bounded prior-meeting signal (mirrors `MeetingBriefService.priorMeetingsBlock`): most-recent
    /// first, capped at `maxPriorMeetings`, each excerpt bounded to `charBudget / 4`.
    private func priorMeetingsBlock(for meeting: Meeting) -> String {
        let prior = meetingService.priorMeetings(matching: meeting)
        guard !prior.isEmpty else { return "" }
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

    private func summaryExcerpt(for meeting: Meeting) -> String? {
        for kind in [MeetingOutputKind.summary, .extended, .brief] {
            if let output = meetingService.latestOutput(ofKind: kind, for: meeting) {
                let trimmed = output.content.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    return TranscriptContextBuilder.truncateWords(trimmed, to: charBudget / 4)
                }
            }
        }
        return nil
    }

    // MARK: - Judge output contract (DB3)

    /// Parse the judge reply into kept **0-based** candidate indices, or throw on an unparseable reply
    /// (Amendment 2, DB3). Grammar:
    /// 1. The `NONE` sentinel (case-insensitive, ignoring surrounding punctuation) ⇒ success, keep zero.
    /// 2. Otherwise extract all integers; the 1-based values inside `1...candidateCount` (deduped,
    ///    order-preserving) map to kept indices. Out-of-range integers are dropped silently — a reply
    ///    with integers but none valid is still a **success** with zero kept.
    /// 3. Otherwise (a non-empty reply that is neither `NONE` nor contains **any** integer — hallucinated
    ///    prose) ⇒ **throw** (`.unparseableJudgeReply`) so the job fails and nothing is persisted.
    static func parseJudgeReply(_ reply: String, candidateCount: Int) throws -> [Int] {
        let trimmed = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        let stripped = trimmed.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        if stripped.uppercased() == "NONE" { return [] }

        let integers = extractIntegers(from: trimmed)
        if integers.isEmpty {
            // Neither the sentinel nor any integer — hallucinated prose. Fail closed.
            throw MeetingRelatedDocsError.unparseableJudgeReply
        }
        var seen = Set<Int>()
        var kept: [Int] = []
        for value in integers where value >= 1 && value <= candidateCount && seen.insert(value).inserted {
            kept.append(value - 1)
        }
        return kept
    }

    /// Every maximal run of digits parsed as an `Int` (order-preserving).
    private static func extractIntegers(from text: String) -> [Int] {
        var result: [Int] = []
        var current = ""
        for character in text {
            if character.isNumber {
                current.append(character)
            } else if let value = Int(current) {
                result.append(value)
                current = ""
            } else {
                current = ""
            }
        }
        if let value = Int(current) { result.append(value) }
        return result
    }
}

enum MeetingRelatedDocsError: LocalizedError, Equatable {
    /// The judge reply was neither the `NONE` sentinel nor contained any integer — hallucinated prose.
    /// Fail-closed (DB3): nothing is persisted and the job is marked `.failed`.
    case unparseableJudgeReply

    var errorDescription: String? {
        switch self {
        case .unparseableJudgeReply:
            return String(localized: "meetings.related.error.unparseable")
        }
    }
}
