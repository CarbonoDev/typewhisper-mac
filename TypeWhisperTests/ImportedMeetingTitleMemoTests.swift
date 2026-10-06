import XCTest
@testable import TypeWhisper

/// [Perf 1C] Guards the precompiled patterns and the per-title memo in `ImportedMeetingTitle`:
/// matches must equal the per-call `String.range(of:options:)` they replaced, and a memoized parse
/// must never serve a result computed under a different time zone.
final class ImportedMeetingTitleMemoTests: XCTestCase {
    private let corpus = [
        "Llamada semanal Dirección-TI - 2026_07_07 11_00 CST - Notas de Gemini (1)",
        "Weekly sync - 2026_07_07 16_29 CST - Notes by Gemini",
        "Revisión BI - 2026_07_09 09_30 - Notas de Gemini",
        "Standup – 2026_07_10 09_00 CST – NOTAS DE GEMINI",
        "Seguimiento BD - 2026_09_17 09_01 CST - Transcripción",
        "Standup — Transcripcion (2)",
        "Weekly sync - Transcript",
        "Transcript review - Q3 budget",
        "Notas de Gemini para el equipo",
        "Planning poker (2)",
        "2026_07_07 11_00 CST - Notas de Gemini",
        "2026_07_07",
        "Q3 budget",
        "",
        "  padded - gemini notes  \n",
    ]

    func testPrecompiledPatternsMatchStringRangeSearch() {
        for compiled in ImportedMeetingTitle.Patterns.all {
            var options: String.CompareOptions = [.regularExpression]
            if compiled.caseInsensitive { options.insert(.caseInsensitive) }
            for text in corpus {
                XCTAssertEqual(
                    compiled.firstRange(in: text),
                    text.range(of: compiled.pattern, options: options),
                    "pattern \(compiled.pattern) on \(text)"
                )
            }
        }
    }

    func testRepeatedParseReturnsTheSameResult() {
        for title in corpus {
            XCTAssertEqual(ImportedMeetingTitle.parse(title), ImportedMeetingTitle.parse(title))
        }
    }

    func testMemoDoesNotServeAStampResolvedInAnotherTimeZone() throws {
        // No zone token: the stamp resolves in the current (here: the passed) zone.
        let title = "Memo zone check - 2026_07_09 09_30 - Notas de Gemini"
        let utcZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let minusSixZone = try XCTUnwrap(TimeZone(secondsFromGMT: -6 * 3600))

        let utc = try XCTUnwrap(ImportedMeetingTitle.parse(title, fallbackTimeZone: utcZone).date)
        let minusSix = try XCTUnwrap(ImportedMeetingTitle.parse(title, fallbackTimeZone: minusSixZone).date)
        XCTAssertEqual(ImportedMeetingTitle.parse(title, fallbackTimeZone: utcZone).date, utc)

        XCTAssertEqual(minusSix.timeIntervalSince(utc), 6 * 3600)
    }

    func testConcurrentParsesAgree() async {
        let titles = corpus
        let expected = titles.map(ImportedMeetingTitle.parse)
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    for (index, title) in titles.enumerated() {
                        XCTAssertEqual(ImportedMeetingTitle.parse(title), expected[index])
                    }
                }
            }
        }
    }
}
