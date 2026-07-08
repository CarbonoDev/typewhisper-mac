import XCTest
@testable import TypeWhisper

/// Unit tests for the first-party Obsidian meeting exporter (plan M7): folder creation, YAML
/// frontmatter (attendees / series / tags), per-meeting folder, filename sanitization,
/// never-overwrite suffixing, and section-selection → files/body. The vault is a temp directory
/// connected through a real `ObsidianVaultService`; the store is a temp `MeetingService`.
@MainActor
final class MeetingObsidianExporterTests: XCTestCase {
    private var vaultDir: URL!
    private var service: MeetingService!
    private var vault: ObsidianVaultService!
    private var exporter: MeetingObsidianExporter!
    /// Name of the suite the exporter also reads the meetings-root-folder setting from (plan D7/M4).
    /// Left unset in setup, so `resolveFolderPath` collapses to today's behavior and the existing
    /// folder/frontmatter assertions hold; the root tests set it via `rootDefaults`.
    private var suiteName: String!

    /// A fresh handle to the exporter's settings suite (same backing store) for the root tests.
    private var rootDefaults: UserDefaults { UserDefaults(suiteName: suiteName)! }

    override func setUpWithError() throws {
        try super.setUpWithError()
        vaultDir = try TestSupport.makeTemporaryDirectory(prefix: "MeetingExportVault")
        addTeardownBlock { [vaultDir] in TestSupport.remove(vaultDir!) }

        let storeDir = try TestSupport.makeTemporaryDirectory(prefix: "MeetingExportStore")
        addTeardownBlock { TestSupport.remove(storeDir) }
        service = MeetingService(appSupportDirectory: storeDir)

        let suite = "MeetingExportTests-\(UUID().uuidString)"
        suiteName = suite
        let defaults = UserDefaults(suiteName: suite)!
        // Pin an empty root so the existing folder/frontmatter assertions are deterministic: the
        // app's registered `"Meetings"` default lives in the process-global registration domain and
        // would otherwise leak into this suite. The root tests override this explicitly.
        defaults.set("", forKey: UserDefaultsKeys.meetingsObsidianRootFolder)
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        vault = ObsidianVaultService(defaults: defaults)
        vault.connect(to: vaultDir.path)

        // Distinct handle to the same suite (a single value can't be sent into two MainActor objects
        // under Swift 6 region isolation; the suite's backing store is shared regardless).
        exporter = MeetingObsidianExporter(vaultService: vault, defaults: UserDefaults(suiteName: suite)!)
    }

    // MARK: - Fixtures

    /// A meeting with attendees, a series id, a summary + brief output, two transcript segments
    /// (one speaker-labeled), and a note.
    private func makeRichMeeting(title: String = "Acme Sync", folder: String? = "Meetings/Acme") -> Meeting {
        let meeting = service.createMeeting(
            title: title,
            source: .calendar,
            state: .completed,
            startDate: Date(timeIntervalSince1970: 1_700_000_000),
            seriesID: "series-42",
            attendees: [Attendee(name: "Marco", email: "marco@x.com"), Attendee(name: "Alex")]
        )
        if let folder { service.setObsidianFolder(folder, for: meeting) }
        service.setObsidianTags(["acme", "sales"], for: meeting)
        service.addOutput(to: meeting, kind: .summary, content: "SUMMARY_BODY: shipped it.")
        service.addOutput(to: meeting, kind: .brief, content: "BRIEF_BODY: prep notes.")
        service.appendStableSegments(
            [
                TranscriptionSegment(text: "Hello everyone.", start: 0, end: 2),
                TranscriptionSegment(text: "Let's begin.", start: 2, end: 4, speakerLabel: "SPEAKER_00")
            ],
            to: meeting
        )
        service.addNote(to: meeting, text: "Follow up next week.", timestampOffset: 3)
        return meeting
    }

    private func contents(of url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    // MARK: - Combined note

    func testCombinedExportCreatesFolderAndYAMLFrontmatter() throws {
        let meeting = makeRichMeeting()
        let urls = try exporter.export(meeting, sections: [.summary, .transcript, .notes], combined: true)

        XCTAssertEqual(urls.count, 1)
        let file = try XCTUnwrap(urls.first)

        // Written under the per-meeting folder inside the vault.
        let expectedFolder = vaultDir.appendingPathComponent("Meetings/Acme")
        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: expectedFolder.path, isDirectory: &isDir))
        XCTAssertTrue(isDir.boolValue)
        XCTAssertTrue(file.path.hasPrefix(expectedFolder.path))

        let body = try contents(of: file)
        // Frontmatter with title, date, attendees (name + email), series, tags.
        XCTAssertTrue(body.hasPrefix("---\n"))
        XCTAssertTrue(body.contains("title: Acme Sync"))
        XCTAssertTrue(body.contains("date: "))
        XCTAssertTrue(body.contains("attendees:"))
        XCTAssertTrue(body.contains("- Marco <marco@x.com>"))
        XCTAssertTrue(body.contains("- Alex"))
        XCTAssertTrue(body.contains("series: series-42"))
        XCTAssertTrue(body.contains("tags:"))
        XCTAssertTrue(body.contains("- acme"))
        XCTAssertTrue(body.contains("- sales"))

        // Selected section content is present; the unselected brief is not.
        XCTAssertTrue(body.contains("SUMMARY_BODY"))
        XCTAssertTrue(body.contains("Hello everyone."))
        XCTAssertTrue(body.contains("Follow up next week."))
        XCTAssertFalse(body.contains("BRIEF_BODY"))

        // Transcript renders timestamps and the speaker label when present.
        XCTAssertTrue(body.contains("**00:02** SPEAKER_00: Let's begin."))
        XCTAssertTrue(body.contains("**00:00** Hello everyone."))
    }

    // MARK: - Separate notes

    func testSeparateExportWritesOneFilePerNonEmptySection() throws {
        let meeting = makeRichMeeting(folder: nil)
        let urls = try exporter.export(meeting, sections: [.summary, .transcript, .notes], combined: false)

        XCTAssertEqual(urls.count, 3)
        let names = urls.map { $0.lastPathComponent }.sorted()
        XCTAssertEqual(names, [
            "Acme Sync - Notes.md",
            "Acme Sync - Summary.md",
            "Acme Sync - Transcript.md"
        ].sorted())

        // Each file contains only its own section content.
        let byName = Dictionary(uniqueKeysWithValues: try urls.map { ($0.lastPathComponent, try contents(of: $0)) })
        XCTAssertTrue(try XCTUnwrap(byName["Acme Sync - Summary.md"]).contains("SUMMARY_BODY"))
        XCTAssertFalse(try XCTUnwrap(byName["Acme Sync - Summary.md"]).contains("Hello everyone."))
        XCTAssertTrue(try XCTUnwrap(byName["Acme Sync - Transcript.md"]).contains("Hello everyone."))
        XCTAssertTrue(try XCTUnwrap(byName["Acme Sync - Notes.md"]).contains("Follow up next week."))
    }

    // MARK: - Imported-source annotation (M8: sources distinguishable)

    func testImportedSegmentsAreTaggedInExportedTranscript() throws {
        let meeting = service.createMeeting(title: "Merged", source: .adHoc, state: .completed)
        service.appendStableSegments(
            [TranscriptionSegment(text: "Live line.", start: 0, end: 2)],
            source: .liveCapture,
            to: meeting
        )
        service.appendStableSegments(
            [TranscriptionSegment(text: "Imported line.", start: 2, end: 4)],
            source: .importedTranscript,
            to: meeting
        )

        let urls = try exporter.export(meeting, sections: [.transcript], combined: false)
        let body = try contents(of: try XCTUnwrap(urls.first))

        let importedTag = String(localized: "meetings.export.importedTag")
        // The imported line carries the marker; the live line does not.
        let importedRow = try XCTUnwrap(body.split(separator: "\n").first { $0.contains("Imported line.") })
        XCTAssertTrue(importedRow.contains("_(\(importedTag))_"))
        let liveRow = try XCTUnwrap(body.split(separator: "\n").first { $0.contains("Live line.") })
        XCTAssertFalse(liveRow.contains(importedTag))
    }

    // MARK: - Empty-section skipping / no content

    func testEmptySectionsAreSkipped() throws {
        // A meeting with only a transcript; brief/summary/extended are empty and must not produce files.
        let meeting = service.createMeeting(title: "Bare", source: .adHoc, state: .completed)
        service.appendStableSegments([TranscriptionSegment(text: "Just this.", start: 0, end: 1)], to: meeting)

        let urls = try exporter.export(meeting, sections: [.brief, .summary, .extended, .transcript], combined: false)
        XCTAssertEqual(urls.count, 1)
        XCTAssertEqual(urls.first?.lastPathComponent, "Bare - Transcript.md")
    }

    func testSelectingOnlyEmptySectionsThrowsNoContent() throws {
        let meeting = service.createMeeting(title: "Empty", source: .adHoc, state: .scheduled)
        XCTAssertThrowsError(try exporter.export(meeting, sections: [.summary, .extended], combined: true)) { error in
            XCTAssertEqual(error as? MeetingExportError, .noContent)
        }
    }

    // MARK: - Filename sanitization

    func testIllegalFilenameCharsAreSanitized() throws {
        let meeting = makeRichMeeting(title: "Q3: Plan/Review*?", folder: nil)
        let urls = try exporter.export(meeting, sections: [.summary], combined: true)
        let file = try XCTUnwrap(urls.first)

        // No illegal path characters survive in the filename.
        let name = file.lastPathComponent
        for ch in "/:\\*?\"<>|" where ch != "/" { // '/' can't appear in a lastPathComponent anyway
            XCTAssertFalse(name.contains(ch), "Illegal char \(ch) leaked into filename \(name)")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        // A title containing a colon is YAML-quoted in the frontmatter.
        let body = try contents(of: file)
        XCTAssertTrue(body.contains("title: \"Q3: Plan/Review*?\""))
    }

    // MARK: - Never overwrite

    func testRepeatedExportNeverOverwrites() throws {
        let meeting = makeRichMeeting(folder: nil)
        let first = try exporter.export(meeting, sections: [.summary], combined: true)
        let second = try exporter.export(meeting, sections: [.summary], combined: true)

        let firstURL = try XCTUnwrap(first.first)
        let secondURL = try XCTUnwrap(second.first)
        XCTAssertNotEqual(firstURL.path, secondURL.path)
        XCTAssertEqual(firstURL.lastPathComponent, "Acme Sync.md")
        XCTAssertEqual(secondURL.lastPathComponent, "Acme Sync 1.md")
        XCTAssertTrue(FileManager.default.fileExists(atPath: firstURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: secondURL.path))
    }

    // MARK: - Guard conditions

    func testExportWithoutVaultThrows() throws {
        vault.disconnect()
        let meeting = makeRichMeeting()
        XCTAssertThrowsError(try exporter.export(meeting, sections: [.summary], combined: true)) { error in
            XCTAssertEqual(error as? MeetingExportError, .noVaultConnected)
        }
    }

    func testExportWithNoSectionsThrows() throws {
        let meeting = makeRichMeeting()
        XCTAssertThrowsError(try exporter.export(meeting, sections: [], combined: true)) { error in
            XCTAssertEqual(error as? MeetingExportError, .noSectionsSelected)
        }
    }

    // MARK: - Meetings root folder (plan D7/M4)

    /// A configured root folder is prepended (sanitized) before the per-meeting folder, so the note
    /// lands under `<vault>/<root>/<folderPath>`.
    func testRootFolderIsPrependedToExportPath() throws {
        rootDefaults.set("Team Meetings", forKey: UserDefaultsKeys.meetingsObsidianRootFolder)
        let meeting = makeRichMeeting(folder: "Clients/Acme")
        let urls = try exporter.export(meeting, sections: [.summary], combined: true)
        let file = try XCTUnwrap(urls.first)

        let expectedFolder = vaultDir
            .appendingPathComponent("Team Meetings")
            .appendingPathComponent("Clients")
            .appendingPathComponent("Acme")
        XCTAssertTrue(file.path.hasPrefix(expectedFolder.path), "note under <vault>/<root>/<folderPath>; got \(file.path)")
    }

    /// A meeting with no per-meeting folder still lands under the root folder.
    func testRootFolderAppliesWhenMeetingHasNoFolder() throws {
        rootDefaults.set("Meetings", forKey: UserDefaultsKeys.meetingsObsidianRootFolder)
        let meeting = makeRichMeeting(folder: nil)
        let urls = try exporter.export(meeting, sections: [.summary], combined: true)
        let file = try XCTUnwrap(urls.first)

        let expectedFolder = vaultDir.appendingPathComponent("Meetings")
        XCTAssertEqual((file.path as NSString).deletingLastPathComponent, expectedFolder.path)
    }

    /// An empty root collapses to today's behavior (the escape hatch) — export at the vault root.
    func testEmptyRootCollapsesToVaultRoot() throws {
        rootDefaults.set("", forKey: UserDefaultsKeys.meetingsObsidianRootFolder)
        let meeting = makeRichMeeting(folder: nil)
        let urls = try exporter.export(meeting, sections: [.summary], combined: true)
        let file = try XCTUnwrap(urls.first)
        XCTAssertEqual((file.path as NSString).deletingLastPathComponent, vaultDir.path)
    }

    // MARK: - Metadata setters

    func testFolderAndTagSettersNormalizeAndPersist() throws {
        let meeting = service.createMeeting(title: "Setters", source: .adHoc)
        service.setObsidianFolder("  Meetings/Acme  ", for: meeting)
        XCTAssertEqual(meeting.obsidianFolder, "Meetings/Acme")
        service.setObsidianFolder("   ", for: meeting)
        XCTAssertNil(meeting.obsidianFolder)

        service.setObsidianTags([" acme ", "", "sales", "acme"], for: meeting)
        XCTAssertEqual(meeting.obsidianTags, ["acme", "sales"])
    }
}
