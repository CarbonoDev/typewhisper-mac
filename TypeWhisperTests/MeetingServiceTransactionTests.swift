import XCTest
import SwiftData
@testable import TypeWhisper

/// One SQLite transaction per `MeetingService` write: the stale-facts recompute rides in the
/// write's own save (deletes included), and the context's autosave finds nothing left to commit.
@MainActor
final class MeetingServiceTransactionTests: XCTestCase {
    private var dir: URL!
    private var service: MeetingService!
    /// Bumped from the `didSave` observer (always posted on the main thread by this context).
    private final class SaveCounter: @unchecked Sendable { var value = 0 }
    private let counter = SaveCounter()
    private var saves: Int { counter.value }
    private var observer: NSObjectProtocol?

    override func setUpWithError() throws {
        dir = try TestSupport.makeTemporaryDirectory()
        service = MeetingService(appSupportDirectory: dir)
        let context = ObjectIdentifier(service.modelContext)
        let counter = counter
        observer = NotificationCenter.default.addObserver(forName: ModelContext.didSave, object: nil, queue: nil) { note in
            guard let object = note.object as AnyObject?, ObjectIdentifier(object) == context else { return }
            counter.value += 1
        }
    }

    override func tearDown() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        service = nil
        TestSupport.remove(dir)
        super.tearDown()
    }

    private func segment(_ text: String, _ start: Double) -> TranscriptionSegment {
        TranscriptionSegment(text: text, start: start, end: start + 1, speakerLabel: "SPEAKER_00")
    }

    /// Run `write`, give autosave a chance to fire, and return how many saves it produced.
    private func savesDuring(_ write: () -> Void) -> Int {
        let before = saves
        write()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        return saves - before
    }

    private func assertFactsMatch(_ meeting: Meeting, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(meeting.storedTranscriptFacts, meeting.computedTranscriptFacts(), file: file, line: line)
        XCTAssertEqual(meeting.storedOutputKinds, meeting.computedOutputKinds(), file: file, line: line)
    }

    func testTheLiveAppendIsOneTransaction() {
        let meeting = service.createMeeting(title: "Live", state: .live)
        XCTAssertEqual(savesDuring { service.appendStableSegments([segment("a", 0)], source: .liveCaptions, to: meeting) }, 1)
        XCTAssertEqual(savesDuring { service.appendStableSegments([segment("b", 1), segment("c", 2)], to: meeting) }, 1)
        assertFactsMatch(meeting)
    }

    func testStaleFactWritesAreOneTransactionIncludingDeletes() {
        let meeting = service.createMeeting(title: "Rewrites", state: .completed, startDate: Date())
        service.appendStableSegments([segment("a", 0), segment("b", 1), segment("c", 2)], to: meeting)

        XCTAssertEqual(savesDuring {
            service.replaceSegments(of: meeting, source: .liveCapture, with: [segment("final", 0)])
        }, 1, "replace deletes three rows and inserts one")
        assertFactsMatch(meeting)
        XCTAssertEqual(meeting.factSegmentCount, 1)

        XCTAssertEqual(savesDuring {
            _ = service.mergeImport(into: meeting, segments: [segment("x", 50), segment("y", 60)], source: .importedTranscript)
        }, 1)
        assertFactsMatch(meeting)

        let output = service.addOutput(to: meeting, kind: .summary, content: "s")
        XCTAssertEqual(savesDuring { service.deleteOutput(output) }, 1)
        assertFactsMatch(meeting)
        XCTAssertEqual(meeting.storedOutputKinds, [])

        XCTAssertEqual(savesDuring { service.clearSpeakerLabels(for: meeting) }, 1)
        assertFactsMatch(meeting)
        XCTAssertEqual(meeting.storedTranscriptFacts?.speakerCount, 0)
    }

    func testPlainWritesAreOneTransaction() {
        let meeting = service.createMeeting(title: "Plain")
        XCTAssertEqual(savesDuring { service.setTitle("Renamed", for: meeting) }, 1)
        XCTAssertEqual(savesDuring { _ = service.addOutput(to: meeting, kind: .brief, content: "b") }, 1)
        XCTAssertEqual(savesDuring { service.deleteMeeting(meeting) }, 1)
    }
}
