import XCTest
import TypeWhisperPluginSDK
@testable import TypeWhisper

/// Merge-import default fix: the import sheet leads with *merging* into an existing meeting when a
/// merge target is present (so the natural first click no longer duplicates the meeting), the
/// import/merge action is reachable on any meeting with a transcript or completed state, and a merge
/// re-triggers language auto-detection just like a new-meeting transcript import.

// MARK: - Sheet posture (pure)

final class MeetingImportSheetModeTests: XCTestCase {

    func testNoMergeTargetLeadsWithCreate() {
        XCTAssertEqual(MeetingsViewModel.importSheetMode(mergeTargetTitle: nil), .createPrimary)
    }

    func testMergeTargetLeadsWithMergePrimaryCarryingTitle() {
        XCTAssertEqual(
            MeetingsViewModel.importSheetMode(mergeTargetTitle: "Weekly Sync"),
            .mergePrimary(meetingTitle: "Weekly Sync")
        )
    }

    // MARK: - Reachability of the import/merge action (requirement 1)

    func testCompletedMeetingOffersImportEvenWithoutTranscript() {
        // The owner's regression: a completed meeting had no import entry point. It must now offer one
        // whether or not it already carries a transcript.
        XCTAssertTrue(
            MeetingsViewModel.showsImportMergeAction(state: .completed, isCapturingThisMeeting: false, hasTranscript: false)
        )
        XCTAssertTrue(
            MeetingsViewModel.showsImportMergeAction(state: .completed, isCapturingThisMeeting: false, hasTranscript: true)
        )
    }

    func testAnyRestingMeetingWithTranscriptOffersImport() {
        for state in MeetingState.allCases {
            XCTAssertTrue(
                MeetingsViewModel.showsImportMergeAction(state: state, isCapturingThisMeeting: false, hasTranscript: true),
                "state \(state) with a transcript should offer import/merge"
            )
        }
    }

    func testScheduledEmptyMeetingDoesNotShowTheChip() {
        // A brand-new scheduled meeting has the prominent "import a transcript" prompt in its empty
        // body; the compact header chip is reserved for meetings with a transcript or completed state.
        XCTAssertFalse(
            MeetingsViewModel.showsImportMergeAction(state: .scheduled, isCapturingThisMeeting: false, hasTranscript: false)
        )
    }

    func testActivelyCapturingMeetingSuppressesImport() {
        // A merge rewrites all segments; it must never race the live capture writer.
        XCTAssertFalse(
            MeetingsViewModel.showsImportMergeAction(state: .live, isCapturingThisMeeting: true, hasTranscript: true)
        )
    }

    // MARK: - Localization (EN + DE) for the new strings

    func testNewImportStringsHaveEnglishAndGermanEntries() throws {
        let keys = [
            "meetingdoc.chip.import",
            "meetingdoc.chip.import.help",
            "meetings.import.merge.title",
            "meetings.import.merge.description",
            "meetings.import.merge.primaryButton",
            "meetings.import.merge.createInstead"
        ]
        for key in keys {
            XCTAssertFalse(try TestSupport.localizedCatalogValue(for: key, language: "en").isEmpty, "EN missing for \(key)")
            XCTAssertFalse(try TestSupport.localizedCatalogValue(for: key, language: "de").isEmpty, "DE missing for \(key)")
        }
    }
}

// MARK: - Merge re-triggers language auto-detection (requirement 3)

@MainActor
final class MeetingMergeLanguageDetectionTests: XCTestCase {

    private final class NoopTranscriber: MeetingAudioTranscribing {
        func transcribeImportedAudio(samples: [Float], languageSelection: LanguageSelection) async throws -> TranscriptionResult {
            TranscriptionResult(text: "", detectedLanguage: nil, duration: 0, processingTime: 0, engineUsed: "stub", segments: [])
        }
    }

    private final class StubProcessor: PromptProcessing {
        var selectedProviderId = "p"
        var selectedCloudModel = "m"
        func process(
            prompt: String,
            text: String,
            providerOverride: String?,
            cloudModelOverride: String?,
            temperatureDirective: PluginLLMTemperatureDirective,
            skipMemoryInjection: Bool
        ) async throws -> String { "en" }
    }

    private func writeTranscript(in dir: URL) throws -> URL {
        let url = dir.appendingPathComponent("merge.txt")
        try """
        Alice  00:00:05
        Opening remarks.

        Bob  00:00:20
        Follow-up point.
        """.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// The exact sequence `MeetingsViewModel.mergeTranscriptFile` now performs: merge the file, then
    /// enqueue an auto-detection. A merged, language-unset meeting must get a `.languageDetection` job.
    func testMergeIntoLanguageUnsetMeetingEnqueuesDetection() async throws {
        let dir = try TestSupport.makeTemporaryDirectory(prefix: "MergeLangUnset")
        defer { TestSupport.remove(dir) }

        let meetingService = MeetingService(appSupportDirectory: dir)
        let jobQueue = JobQueueService()
        let languageService = MeetingLanguageService(
            meetingService: meetingService, processor: StubProcessor(), jobQueue: jobQueue
        )
        let importService = MeetingImportService(
            meetingService: meetingService, audioFileService: AudioFileService(), transcriber: NoopTranscriber()
        )

        let meeting = meetingService.createMeeting(title: "Retro", source: .adHoc, state: .completed)
        XCTAssertNil(meeting.languageCode)

        try importService.mergeTranscriptFile(at: writeTranscript(in: dir), into: meeting)
        languageService.enqueueAutoDetection(for: meeting)

        XCTAssertTrue(
            jobQueue.hasActiveJob(kind: .languageDetection, meetingID: meeting.id),
            "a merge into a language-unset meeting must enqueue detection"
        )
        await jobQueue.drain()
    }

    /// A meeting that already has a manual language must NOT get a detection job on merge (the
    /// enqueue's own `languageCode == nil` guard makes the call a no-op).
    func testMergeIntoLanguageSetMeetingEnqueuesNothing() async throws {
        let dir = try TestSupport.makeTemporaryDirectory(prefix: "MergeLangSet")
        defer { TestSupport.remove(dir) }

        let meetingService = MeetingService(appSupportDirectory: dir)
        let jobQueue = JobQueueService()
        let languageService = MeetingLanguageService(
            meetingService: meetingService, processor: StubProcessor(), jobQueue: jobQueue
        )
        let importService = MeetingImportService(
            meetingService: meetingService, audioFileService: AudioFileService(), transcriber: NoopTranscriber()
        )

        let meeting = meetingService.createMeeting(title: "Retro", source: .adHoc, state: .completed)
        meetingService.setLanguage("de", for: meeting)

        try importService.mergeTranscriptFile(at: writeTranscript(in: dir), into: meeting)
        languageService.enqueueAutoDetection(for: meeting)

        XCTAssertFalse(
            jobQueue.hasActiveJob(kind: .languageDetection, meetingID: meeting.id),
            "a merge into a language-set meeting must not enqueue detection"
        )
        await jobQueue.drain()
    }
}
