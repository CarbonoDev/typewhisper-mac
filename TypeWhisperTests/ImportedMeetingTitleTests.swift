import XCTest
@testable import TypeWhisper

final class ImportedMeetingTitleTests: XCTestCase {

    func testSpanishGeminiExportWithCounterParsesFully() {
        let parsed = ImportedMeetingTitle.parse(
            "Llamada semanal Dirección-TI - 2026_07_07 11_00 CST - Notas de Gemini (1)"
        )
        XCTAssertEqual(parsed.cleanTitle, "Llamada semanal Dirección-TI")
        XCTAssertTrue(parsed.isImported)
        XCTAssertNotNil(parsed.date)
    }

    func testEnglishGeminiExportParses() {
        let parsed = ImportedMeetingTitle.parse(
            "Weekly sync - 2026_07_07 16_29 CST - Notes by Gemini"
        )
        XCTAssertEqual(parsed.cleanTitle, "Weekly sync")
        XCTAssertTrue(parsed.isImported)
    }

    func testDateSegmentWithoutTimeZoneStillParses() {
        let parsed = ImportedMeetingTitle.parse("Revisión BI - 2026_07_09 09_30 - Notas de Gemini")
        XCTAssertEqual(parsed.cleanTitle, "Revisión BI")
        XCTAssertNotNil(parsed.date)
    }

    func testParsedDateComponentsRespectStatedTimeZone() throws {
        // "CST" states a fixed UTC−6 offset. It must NOT resolve to America/Chicago, whose July
        // DST (CDT, UTC−5) would shift the stamp an hour early.
        let parsed = ImportedMeetingTitle.parse(
            "Revisión BI - 2026_07_07 16_29 CST - Notas de Gemini"
        )
        let date = try XCTUnwrap(parsed.date)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: -6 * 3600))
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        XCTAssertEqual(components.year, 2026)
        XCTAssertEqual(components.month, 7)
        XCTAssertEqual(components.day, 7)
        XCTAssertEqual(components.hour, 16)
        XCTAssertEqual(components.minute, 29)
    }

    func testPlainTitlePassesThroughUntouched() {
        let parsed = ImportedMeetingTitle.parse("Seguimiento BD")
        XCTAssertEqual(parsed.cleanTitle, "Seguimiento BD")
        XCTAssertFalse(parsed.isImported)
        XCTAssertNil(parsed.date)
    }

    func testTitleEndingInParenthesizedNumberIsNotACopyCounter() {
        let parsed = ImportedMeetingTitle.parse("Planning poker (2)")
        XCTAssertEqual(parsed.cleanTitle, "Planning poker (2)")
        XCTAssertFalse(parsed.isImported)
    }

    func testSuffixOnlyExportWithoutDateStripsSuffix() {
        let parsed = ImportedMeetingTitle.parse("Demo día - Notas de Gemini")
        XCTAssertEqual(parsed.cleanTitle, "Demo día")
        XCTAssertTrue(parsed.isImported)
        XCTAssertNil(parsed.date)
    }

    func testEnDashSeparatorIsAccepted() {
        let parsed = ImportedMeetingTitle.parse("Standup – 2026_07_10 09_00 CST – Notas de Gemini")
        XCTAssertEqual(parsed.cleanTitle, "Standup")
        XCTAssertTrue(parsed.isImported)
    }

    func testWholeTitleBeingAnExportPatternPassesThrough() {
        // Stripping everything would leave an empty title — passthrough instead.
        let parsed = ImportedMeetingTitle.parse("2026_07_07 11_00 CST - Notas de Gemini")
        XCTAssertEqual(parsed.cleanTitle, "2026_07_07 11_00 CST - Notas de Gemini")
        XCTAssertFalse(parsed.isImported)
    }

    func testDisplayTitleConvenience() {
        XCTAssertEqual(
            ImportedMeetingTitle.displayTitle(
                for: "Revisión BI - 2026_07_07 16_29 CST - Notas de Gemini (1)"
            ),
            "Revisión BI"
        )
        XCTAssertEqual(ImportedMeetingTitle.displayTitle(for: "Seguimiento BD"), "Seguimiento BD")
    }
}

final class MeetingAgendaParserTests: XCTestCase {

    func testSpanishTalkingPointsExtractAndStrip() {
        let markdown = """
        # Resumen Previa Reunión

        Contexto de la reunión anterior.

        # Puntos de Discusión Sugeridos

        1. Revisar el seguimiento de Metabase.
        2. Analizar el progreso de los cursos.

        # Temas Abiertos

        Texto adicional.
        """
        let agenda = MeetingOutputParser.parseAgenda(markdown: markdown)
        XCTAssertEqual(agenda.items.map(\.text), [
            "Revisar el seguimiento de Metabase.",
            "Analizar el progreso de los cursos.",
        ])
        XCTAssertTrue(agenda.items.allSatisfy { $0.assignee == nil })
        XCTAssertFalse(agenda.strippedMarkdown.contains("Puntos de Discusión Sugeridos"))
        XCTAssertFalse(agenda.strippedMarkdown.contains("Revisar el seguimiento"))
        XCTAssertTrue(agenda.strippedMarkdown.contains("Contexto de la reunión anterior."))
        XCTAssertTrue(agenda.strippedMarkdown.contains("Texto adicional."))
    }

    func testEnglishTalkingPointsWithBulletsExtract() {
        let markdown = """
        ## Suggested talking points
        - Budget review
        - Hiring plan
        """
        let agenda = MeetingOutputParser.parseAgenda(markdown: markdown)
        XCTAssertEqual(agenda.items.map(\.text), ["Budget review", "Hiring plan"])
    }

    func testBriefWithoutAgendaSectionPassesThrough() {
        let markdown = "# Summary\n\nJust prose, no talking points."
        let agenda = MeetingOutputParser.parseAgenda(markdown: markdown)
        XCTAssertTrue(agenda.items.isEmpty)
        XCTAssertEqual(agenda.strippedMarkdown, markdown)
    }

    func testAgendaHeadingWithoutItemsPassesThrough() {
        let markdown = "# Agenda\n\nProse only under the heading."
        let agenda = MeetingOutputParser.parseAgenda(markdown: markdown)
        XCTAssertTrue(agenda.items.isEmpty)
        XCTAssertEqual(agenda.strippedMarkdown, markdown)
    }

    func testAgendaStableIDsAreDeterministicAndUnique() {
        let markdown = "# Agenda\n- Point A\n- Point A\n- Point B"
        let first = MeetingOutputParser.parseAgenda(markdown: markdown)
        let second = MeetingOutputParser.parseAgenda(markdown: markdown)
        XCTAssertEqual(first.items.map(\.stableID), second.items.map(\.stableID))
        XCTAssertEqual(Set(first.items.map(\.stableID)).count, first.items.count)
    }
}
