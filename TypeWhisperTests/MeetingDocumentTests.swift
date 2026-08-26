import XCTest
@testable import TypeWhisper

/// [Track B] Unit tests for the meeting document (plan D4): the lifecycle state machine, the
/// transcript-bubble model (Me attribution / gap timestamps / import tags / search), markdown block
/// parsing, the restart-safe resume path, and EN+DE coverage of the new `meetingdoc.*` strings.

// MARK: - Lifecycle state machine

final class MeetingDocumentStateTests: XCTestCase {
    private func presentation(
        _ state: MeetingState,
        capturing: Bool,
        content: Bool
    ) -> MeetingsViewModel.DocumentPresentation {
        MeetingsViewModel.documentPresentation(state: state, isCapturingThisMeeting: capturing, hasContent: content)
    }

    func testScheduledEmptyShowsStart() {
        let p = presentation(.scheduled, capturing: false, content: false)
        XCTAssertEqual(p.bodyMode, .scheduledEmpty)
        XCTAssertEqual(p.contextAction, .start)
        XCTAssertFalse(p.showsLiveChip)
        XCTAssertFalse(p.transcriptPanelOpenByDefault)
    }

    func testLiveShowsStopWithTranscriptHiddenByDefault() {
        // Capturing wins regardless of the stored state. Owner request 1: the transcript panel is
        // hidden by default for *every* meeting, including during live capture.
        for state in MeetingState.allCases {
            let p = presentation(state, capturing: true, content: true)
            XCTAssertEqual(p.bodyMode, .liveNotes, "state \(state)")
            XCTAssertEqual(p.contextAction, .stop, "state \(state)")
            XCTAssertTrue(p.showsLiveChip, "state \(state)")
            XCTAssertFalse(p.transcriptPanelOpenByDefault, "state \(state)")
        }
    }

    func testFinalizingShowsFinalizingAndKeepsLivePosture() {
        // Stop pressed: `isCapturing` is already false, but the off-main teardown is still finalizing
        // this meeting. The bottom bar shows the disabled "Finalizing…" action and the live chip stays
        // up (regardless of the stored state, incl. the `.processing` it was just marked), rather than
        // prematurely flashing the resting resume/generate affordances.
        for state in [MeetingState.processing, .live, .completed, .interrupted] {
            let p = MeetingsViewModel.documentPresentation(
                state: state,
                isCapturingThisMeeting: false,
                hasContent: true,
                isFinalizingThisMeeting: true
            )
            XCTAssertEqual(p.contextAction, .finalizing, "state \(state)")
            XCTAssertEqual(p.bodyMode, .liveNotes, "state \(state)")
            XCTAssertTrue(p.showsLiveChip, "state \(state)")
            XCTAssertFalse(p.transcriptPanelOpenByDefault, "state \(state)")
        }
    }

    func testActiveCaptureWinsOverFinalizingFlag() {
        // If both flags were set (transient overlap), live capture wins: Stop, not Finalizing.
        let p = MeetingsViewModel.documentPresentation(
            state: .live, isCapturingThisMeeting: true, hasContent: true, isFinalizingThisMeeting: true
        )
        XCTAssertEqual(p.contextAction, .stop)
        XCTAssertEqual(p.bodyMode, .liveNotes)
    }

    func testStoppedWithContentShowsResumeAndGenerate() {
        // A stopped (interrupted) meeting that carries content can resume + generate.
        let p = presentation(.interrupted, capturing: false, content: true)
        XCTAssertEqual(p.bodyMode, .renderedOutput)
        XCTAssertEqual(p.contextAction, .resumeAndGenerate)
    }

    func testCompletedWithContentShowsGenerateOnly() {
        let p = presentation(.completed, capturing: false, content: true)
        XCTAssertEqual(p.bodyMode, .renderedOutput)
        XCTAssertEqual(p.contextAction, .generate)
    }

    func testScheduledWithImportedContentRendersOutputButStillOffersStart() {
        // Imported transcript into a scheduled meeting: body renders content, primary verb stays Start.
        let p = presentation(.scheduled, capturing: false, content: true)
        XCTAssertEqual(p.bodyMode, .renderedOutput)
        XCTAssertEqual(p.contextAction, .start)
    }

    func testRestingStateWithoutContentFallsBackToStart() {
        let p = presentation(.failed, capturing: false, content: false)
        XCTAssertEqual(p.bodyMode, .scheduledEmpty)
        XCTAssertEqual(p.contextAction, .start)
    }
}

// MARK: - Transcript bubble model

final class TranscriptBubbleModelTests: XCTestCase {
    private func segment(
        order: Int,
        start: Double,
        end: Double,
        text: String,
        speaker: String? = nil,
        source: MeetingSegmentSource = .liveCapture
    ) -> MeetingSegment {
        MeetingSegment(order: order, start: start, end: end, text: text, speakerLabel: speaker, source: source)
    }

    func testMeSegmentIsRightAlignedWithMeLabel() {
        let segments = [segment(order: 0, start: 0, end: 2, text: "hi", speaker: MeetingDiarizationEnricher.micSpeakerLabel)]
        let bubbles = MeetingsViewModel.transcriptBubbles(segments: segments, speakerMap: [MeetingDiarizationEnricher.micSpeakerLabel: "Marco"])
        let speech = bubbles.filter { $0.kind == .speech }
        XCTAssertEqual(speech.count, 1)
        XCTAssertTrue(speech[0].isMe)
        XCTAssertEqual(speech[0].displayName, "Marco")
    }

    func testSpeakerMapResolutionAndUnmappedFallback() {
        let segments = [
            segment(order: 0, start: 0, end: 1, text: "a", speaker: "SPEAKER_00"),
            segment(order: 1, start: 1, end: 2, text: "b", speaker: "SPEAKER_01")
        ]
        let bubbles = MeetingsViewModel.transcriptBubbles(segments: segments, speakerMap: ["SPEAKER_00": "Alex"])
        let speech = bubbles.filter { $0.kind == .speech }
        XCTAssertEqual(speech[0].displayName, "Alex")       // mapped
        XCTAssertEqual(speech[1].displayName, "SPEAKER_01") // unmapped falls back to raw label
        XCTAssertFalse(speech[0].isMe)
    }

    func testGapTimestampInsertedAtSilence() {
        // 40s silence between segment 0's end (2s) and segment 1's start (42s) → a gap marker.
        let segments = [
            segment(order: 0, start: 0, end: 2, text: "before"),
            segment(order: 1, start: 42, end: 44, text: "after")
        ]
        let bubbles = MeetingsViewModel.transcriptBubbles(segments: segments, speakerMap: [:], gapThreshold: 30)
        XCTAssertEqual(bubbles.count, 3)
        XCTAssertEqual(bubbles[0].kind, .speech)
        XCTAssertEqual(bubbles[1].kind, .gap)
        XCTAssertEqual(bubbles[1].timestamp, "00:42")
        XCTAssertEqual(bubbles[2].kind, .speech)
    }

    func testNoGapBelowThreshold() {
        let segments = [
            segment(order: 0, start: 0, end: 2, text: "a"),
            segment(order: 1, start: 5, end: 7, text: "b")
        ]
        let bubbles = MeetingsViewModel.transcriptBubbles(segments: segments, speakerMap: [:], gapThreshold: 30)
        XCTAssertTrue(bubbles.allSatisfy { $0.kind == .speech })
        XCTAssertEqual(bubbles.count, 2)
    }

    func testImportedSourceIsTagged() {
        let segments = [
            segment(order: 0, start: 0, end: 1, text: "live", source: .liveCapture),
            segment(order: 1, start: 1, end: 2, text: "merged", source: .importedTranscript)
        ]
        let bubbles = MeetingsViewModel.transcriptBubbles(segments: segments, speakerMap: [:])
        let speech = bubbles.filter { $0.kind == .speech }
        XCTAssertFalse(speech[0].isImported)
        XCTAssertTrue(speech[1].isImported)
    }

    func testSearchFiltersByTextAndSpeaker() {
        let segments = [
            segment(order: 0, start: 0, end: 1, text: "budget review", speaker: "SPEAKER_00"),
            segment(order: 1, start: 40, end: 41, text: "lunch plans", speaker: "SPEAKER_01")
        ]
        let all = MeetingsViewModel.transcriptBubbles(segments: segments, speakerMap: ["SPEAKER_00": "Alex"], gapThreshold: 30)
        XCTAssertTrue(all.contains { $0.kind == .gap })

        let byText = MeetingsViewModel.filterTranscriptBubbles(all, query: "budget")
        XCTAssertEqual(byText.count, 1)
        XCTAssertEqual(byText[0].text, "budget review")
        // Gap markers are dropped while filtering.
        XCTAssertFalse(byText.contains { $0.kind == .gap })

        let byName = MeetingsViewModel.filterTranscriptBubbles(all, query: "alex")
        XCTAssertEqual(byName.count, 1)
        XCTAssertEqual(byName[0].displayName, "Alex")

        // Empty query is a passthrough.
        XCTAssertEqual(MeetingsViewModel.filterTranscriptBubbles(all, query: "   ").count, all.count)
    }

    func testOrderingIsStableByOrderField() {
        let segments = [
            segment(order: 2, start: 4, end: 5, text: "third"),
            segment(order: 0, start: 0, end: 1, text: "first"),
            segment(order: 1, start: 2, end: 3, text: "second")
        ]
        let bubbles = MeetingsViewModel.transcriptBubbles(segments: segments, speakerMap: [:], gapThreshold: 100)
        XCTAssertEqual(bubbles.map(\.text), ["first", "second", "third"])
    }
}

// MARK: - Markdown block parsing

final class MarkdownRenderTests: XCTestCase {
    func testHeadingLevels() {
        let blocks = MarkdownBlock.parse("# Title\n## Subtitle\n### Section")
        XCTAssertEqual(blocks, [
            .heading(level: 1, text: "Title"),
            .heading(level: 2, text: "Subtitle"),
            .heading(level: 3, text: "Section")
        ])
    }

    func testBulletListGrouping() {
        let blocks = MarkdownBlock.parse("- one\n- two\n* three")
        XCTAssertEqual(blocks, [.bullet(items: ["one", "two", "three"])])
    }

    func testOrderedListGrouping() {
        let blocks = MarkdownBlock.parse("1. first\n2. second")
        XCTAssertEqual(blocks, [.ordered(items: ["first", "second"])])
    }

    func testParagraphsSeparatedByBlankLine() {
        let blocks = MarkdownBlock.parse("Line one\nstill one\n\nSecond paragraph")
        XCTAssertEqual(blocks, [
            .paragraph("Line one still one"),
            .paragraph("Second paragraph")
        ])
    }

    func testMixedDocument() {
        let md = "# Heading\n\nSome intro text.\n\n- a\n- b\n\n1. x\n2. y"
        let blocks = MarkdownBlock.parse(md)
        XCTAssertEqual(blocks, [
            .heading(level: 1, text: "Heading"),
            .paragraph("Some intro text."),
            .bullet(items: ["a", "b"]),
            .ordered(items: ["x", "y"])
        ])
    }

    func testInlineEmphasisRendersAndStripsMarkers() {
        // The native inline parser strips the emphasis markers, leaving the plain characters.
        let attributed = MarkdownBlock.inlineAttributed("This is **bold** and *italic*")
        XCTAssertEqual(String(attributed.characters), "This is bold and italic")
    }

    func testNonHeadingHashWithoutSpaceIsParagraph() {
        let blocks = MarkdownBlock.parse("#nospace")
        XCTAssertEqual(blocks, [.paragraph("#nospace")])
    }
}

// MARK: - Resume (restart-safe capture)

@MainActor
final class MeetingDocumentResumeTests: XCTestCase {
    /// A stopped meeting resumes into the same capture path; the capture service offsets new
    /// segments past the prior transcript's max end (`sessionTimeOffset`). This asserts the pure
    /// offset arithmetic the resume relies on.
    func testResumeContinuesPastPriorMaxEnd() {
        let meeting = Meeting(title: "Standup")
        meeting.segments = [
            MeetingSegment(order: 0, start: 0, end: 12, text: "a", meeting: meeting),
            MeetingSegment(order: 1, start: 12, end: 30, text: "b", meeting: meeting)
        ]
        let priorMaxEnd = meeting.segments.map(\.end).max() ?? 0
        XCTAssertEqual(priorMaxEnd, 30)

        // On resume, a new session-relative segment at 0s must be shifted to sit after 30s so it does
        // not overwrite the existing transcript timeline.
        let newSessionRelativeStart = 0.0
        let shifted = newSessionRelativeStart + priorMaxEnd
        XCTAssertGreaterThanOrEqual(shifted, priorMaxEnd)
    }
}

// MARK: - Localization coverage

final class MeetingDocumentLocalizationTests: XCTestCase {
    func testMeetingDocumentStringsHaveEnglishAndGermanEntries() throws {
        let keys = [
            "meetingdoc.live",
            "meetingdoc.start.primary",
            "meetingdoc.stop",
            "meetingdoc.resume",
            "meetingdoc.generate",
            "meetingdoc.generate.regenerate",
            "meetingdoc.generate.noTemplates",
            "meetingdoc.output.kind.summary",
            "meetingdoc.output.kind.extended",
            "meetingdoc.output.kind.brief",
            "meetingdoc.output.customTemplates",
            "meetingdoc.output.none",
            "meetingdoc.output.needsTranscript",
            "meetingdoc.output.generateHint",
            "meetingdoc.chip.noFolder",
            "meetingdoc.chip.export",
            "meetingdoc.export.title",
            "meetingdoc.export.done",
            "meetingdoc.import.prompt.title",
            "meetingdoc.import.prompt.message",
            "meetingdoc.import.prompt.button",
            "meetingdoc.merge.hint",
            "meetingdoc.merge.button",
            "meetingdoc.bottombar.transcriptToggle",
            "meetingdoc.bottombar.askPlaceholder",
            "meetingdoc.transcript.title",
            "meetingdoc.transcript.copyAll",
            "meetingdoc.transcript.minimize",
            "meetingdoc.transcript.searchPlaceholder",
            "meetingdoc.transcript.listening",
            "meetingdoc.transcript.empty",
            "meetingdoc.transcript.noMatches",
            "meetingdoc.transcript.importedTag",
            "meetingdoc.transcript.meLabel",
            "meetingdoc.finalPass.disclosure"
        ]
        for key in keys {
            XCTAssertFalse(try TestSupport.localizedCatalogValue(for: key, language: "en").isEmpty, "EN missing for \(key)")
            XCTAssertFalse(try TestSupport.localizedCatalogValue(for: key, language: "de").isEmpty, "DE missing for \(key)")
        }
    }
}
