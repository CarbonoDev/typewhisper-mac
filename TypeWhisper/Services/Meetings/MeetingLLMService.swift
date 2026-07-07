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

/// Runs a `MeetingTemplate` over a meeting's transcript to produce a persisted `MeetingOutput`
/// (plan M4). Long transcripts are handled with a char-budget map/reduce (plan D7): each chunk is
/// summarized (map), then the partial summaries are reduced through the template's own prompt.
/// Transcripts that fit one chunk take the direct single-call path. In-meeting notes are appended
/// only when the meeting's `notesIncludedInOutputs` flag is set. Dictation memory is never
/// injected (plan D6: `skipMemoryInjection: true`).
@MainActor
final class MeetingLLMService: ObservableObject {
    @Published private(set) var isGenerating = false

    private let meetingService: MeetingService
    private let processor: any PromptProcessing
    private let charBudget: Int

    init(
        meetingService: MeetingService,
        processor: any PromptProcessing,
        charBudget: Int = TranscriptContextBuilder.defaultCharBudget
    ) {
        self.meetingService = meetingService
        self.processor = processor
        self.charBudget = charBudget
    }

    /// Generate an output for `meeting` from `template`, persist it as a new `MeetingOutput`, and
    /// return it. Regeneration always inserts a new row (history retained; the UI shows the
    /// newest per kind — plan D15). Throws if the meeting has no transcript, or the LLM call fails.
    @discardableResult
    func generateOutput(for meeting: Meeting, using template: MeetingTemplate) async throws -> MeetingOutput {
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

        isGenerating = true
        defer { isGenerating = false }

        let content = try await runMapReduce(template: template, transcript: transcript, notes: notesBlock)

        return meetingService.addOutput(
            to: meeting,
            kind: template.kind,
            content: content,
            templateID: template.id,
            providerUsed: resolvedProvider(for: template),
            modelUsed: resolvedModel(for: template)
        )
    }

    // MARK: - Map / reduce

    private func runMapReduce(template: MeetingTemplate, transcript: String, notes: String) async throws -> String {
        let chunks = TranscriptContextBuilder.chunk(transcript, charBudget: charBudget)

        // Direct path: the transcript fits a single chunk — one call through the template prompt.
        guard chunks.count > 1 else {
            let userText = TranscriptContextBuilder.assemble(transcript: chunks.first ?? transcript, notes: notes)
            return try await run(template: template, prompt: template.prompt, text: userText)
        }

        // Map: faithfully condense each chunk. The map instruction is deliberately extractive so
        // the reduce step (which applies the actual template) is not summarizing a summary of a
        // rephrase. Notes are attached only to the reduce input, never duplicated per chunk.
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

        // Reduce: apply the template's own prompt to the joined partial summaries + notes.
        let reduceInput = TranscriptContextBuilder.assemble(
            transcript: partials.joined(separator: "\n\n"),
            notes: notes
        )
        return try await run(template: template, prompt: template.prompt, text: reduceInput)
    }

    private func run(template: MeetingTemplate, prompt: String, text: String) async throws -> String {
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
    private func resolvedProvider(for template: MeetingTemplate) -> String? {
        if let provider = template.providerType?.trimmingCharacters(in: .whitespacesAndNewlines),
           !provider.isEmpty {
            return provider
        }
        let selected = processor.selectedProviderId.trimmingCharacters(in: .whitespacesAndNewlines)
        return selected.isEmpty ? nil : selected
    }

    /// Model recorded on the output: the template override when set, else the current global
    /// selection (nil when neither exists, e.g. a provider with no model dimension).
    private func resolvedModel(for template: MeetingTemplate) -> String? {
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

    var errorDescription: String? {
        switch self {
        case .emptyTranscript:
            return String(localized: "meetings.output.error.emptyTranscript")
        }
    }
}
