import XCTest
@testable import TypeWhisper

final class MeetingOutputParserTests: XCTestCase {
    // MARK: - English extraction

    func testEnglishActionAndDecisionSectionsExtract() {
        let markdown = """
        ## Summary

        We discussed the rollout.

        ## Action Items

        - [ ] Prepare the deck @Marco
        - Luisa: send the minutes

        ## Decisions

        - Use Postgres for the pipeline

        ## Other Notes

        Some closing remarks.
        """

        let outcomes = MeetingOutputParser.parse(markdown: markdown)

        XCTAssertEqual(outcomes.actions.count, 2)
        XCTAssertEqual(outcomes.actions[0].text, "Prepare the deck")
        XCTAssertEqual(outcomes.actions[0].assignee, "Marco")
        XCTAssertEqual(outcomes.actions[1].text, "send the minutes")
        XCTAssertEqual(outcomes.actions[1].assignee, "Luisa")
        XCTAssertEqual(outcomes.decisions, ["Use Postgres for the pipeline"])

        XCTAssertTrue(outcomes.strippedMarkdown.contains("## Summary"))
        XCTAssertTrue(outcomes.strippedMarkdown.contains("## Other Notes"))
        XCTAssertTrue(outcomes.strippedMarkdown.contains("Some closing remarks."))
        XCTAssertFalse(outcomes.strippedMarkdown.contains("Action Items"))
        XCTAssertFalse(outcomes.strippedMarkdown.contains("Prepare the deck"))
        XCTAssertFalse(outcomes.strippedMarkdown.contains("## Decisions"))
    }

    // MARK: - Spanish extraction

    func testSpanishSectionsExtractWithNumberedLists() {
        let markdown = """
        # Resumen

        Se revisó el avance del proyecto.

        # Tareas

        1. Revisar métricas de Metabase
        2) Enviar la minuta al equipo

        # Acuerdos

        - Avanzar con el Escenario B
        """

        let outcomes = MeetingOutputParser.parse(markdown: markdown)

        XCTAssertEqual(outcomes.actions.map(\.text), [
            "Revisar métricas de Metabase",
            "Enviar la minuta al equipo",
        ])
        // "Acuerdos" (agreements) is a decisions heading, not actions.
        XCTAssertEqual(outcomes.decisions, ["Avanzar con el Escenario B"])
        XCTAssertTrue(outcomes.strippedMarkdown.contains("# Resumen"))
        XCTAssertFalse(outcomes.strippedMarkdown.contains("# Tareas"))
        XCTAssertFalse(outcomes.strippedMarkdown.contains("Escenario B"))
    }

    func testProximosPasosHeadingWithDiacriticsExtracts() {
        let markdown = """
        ## Próximos Pasos

        - Confirmar integración de Slack
        """

        let outcomes = MeetingOutputParser.parse(markdown: markdown)

        XCTAssertEqual(outcomes.actions.map(\.text), ["Confirmar integración de Slack"])
    }

    // MARK: - Bold pseudo-headings

    func testBoldPseudoHeadingExtractsAndFollowingSectionSurvives() {
        let markdown = """
        **Próximos pasos:**

        - Hacer la propuesta

        **Notas**

        Texto que debe quedarse.
        """

        let outcomes = MeetingOutputParser.parse(markdown: markdown)

        XCTAssertEqual(outcomes.actions.map(\.text), ["Hacer la propuesta"])
        XCTAssertTrue(outcomes.strippedMarkdown.contains("**Notas**"))
        XCTAssertTrue(outcomes.strippedMarkdown.contains("Texto que debe quedarse."))
        XCTAssertFalse(outcomes.strippedMarkdown.contains("Próximos pasos"))
    }

    // MARK: - Assignee heuristics

    func testBoldNameColonAssignee() {
        let markdown = """
        ## Action Items
        - **Juan Carlos:** preparar la propuesta
        """

        let outcomes = MeetingOutputParser.parse(markdown: markdown)

        XCTAssertEqual(outcomes.actions.count, 1)
        XCTAssertEqual(outcomes.actions[0].assignee, "Juan Carlos")
        XCTAssertEqual(outcomes.actions[0].text, "preparar la propuesta")
    }

    func testMentionTokenAssigneeIsStrippedFromText() {
        let markdown = """
        ## Tasks
        - Enviar el reporte @luisa mañana
        """

        let outcomes = MeetingOutputParser.parse(markdown: markdown)

        XCTAssertEqual(outcomes.actions.count, 1)
        XCTAssertEqual(outcomes.actions[0].assignee, "luisa")
        XCTAssertEqual(outcomes.actions[0].text, "Enviar el reporte mañana")
    }

    func testLowercaseColonPrefixIsNotAnAssignee() {
        let markdown = """
        ## Tasks
        - revisar: la documentación pendiente
        """

        let outcomes = MeetingOutputParser.parse(markdown: markdown)

        XCTAssertEqual(outcomes.actions.count, 1)
        XCTAssertNil(outcomes.actions[0].assignee)
        XCTAssertEqual(outcomes.actions[0].text, "revisar: la documentación pendiente")
    }

    // MARK: - Checkbox markers

    func testCheckedCheckboxMarkerIsStripped() {
        let markdown = """
        ## Action Items
        - [x] Enviar minuta
        """

        let outcomes = MeetingOutputParser.parse(markdown: markdown)

        XCTAssertEqual(outcomes.actions.map(\.text), ["Enviar minuta"])
    }

    // MARK: - Passthrough behavior

    func testNoMatchingHeadingsReturnsOriginalUnchanged() {
        let markdown = """
        ## Summary

        Nothing actionable here.

        ## Discussion

        - A bullet that is not an action section
        """

        let outcomes = MeetingOutputParser.parse(markdown: markdown)

        XCTAssertTrue(outcomes.actions.isEmpty)
        XCTAssertTrue(outcomes.decisions.isEmpty)
        XCTAssertEqual(outcomes.strippedMarkdown, markdown)
    }

    func testMatchingHeadingWithoutListItemsIsLeftInPlace() {
        let markdown = """
        ## Action Items

        Everyone should keep doing what they are doing.
        """

        let outcomes = MeetingOutputParser.parse(markdown: markdown)

        XCTAssertTrue(outcomes.actions.isEmpty)
        XCTAssertTrue(outcomes.decisions.isEmpty)
        XCTAssertEqual(outcomes.strippedMarkdown, markdown)
    }

    func testEmptyInputPassesThrough() {
        let outcomes = MeetingOutputParser.parse(markdown: "")
        XCTAssertTrue(outcomes.actions.isEmpty)
        XCTAssertTrue(outcomes.decisions.isEmpty)
        XCTAssertEqual(outcomes.strippedMarkdown, "")
    }

    func testGarbageInputPassesThrough() {
        let markdown = "%%%\u{0007} not markdown at all ###### \n\n***"
        let outcomes = MeetingOutputParser.parse(markdown: markdown)
        XCTAssertTrue(outcomes.actions.isEmpty)
        XCTAssertTrue(outcomes.decisions.isEmpty)
        XCTAssertEqual(outcomes.strippedMarkdown, markdown)
    }

    // MARK: - Stable IDs

    func testStableIDIsDeterministicAcrossParses() {
        let markdown = """
        ## Action Items
        - Prepare the quarterly report
        """

        let first = MeetingOutputParser.parse(markdown: markdown)
        let second = MeetingOutputParser.parse(markdown: markdown)

        XCTAssertEqual(first.actions[0].stableID, second.actions[0].stableID)
        XCTAssertFalse(first.actions[0].stableID.isEmpty)
    }

    func testStableIDNormalizesCaseDiacriticsAndWhitespace() {
        XCTAssertEqual(
            MeetingOutputParser.stableID(for: "Enviar   la Minuta"),
            MeetingOutputParser.stableID(for: "enviar la minuta")
        )
        XCTAssertEqual(
            MeetingOutputParser.stableID(for: "Revisar métricas"),
            MeetingOutputParser.stableID(for: "revisar metricas")
        )
        XCTAssertNotEqual(
            MeetingOutputParser.stableID(for: "Item one"),
            MeetingOutputParser.stableID(for: "Item two")
        )
    }

    // MARK: - Tables

    func testRealWorldEnglishTableWithOwnerTaskDue() {
        let markdown = """
        ### Action Items

        | Owner | Task | Due |
        |---|---|---|
        | Juan Carlos | Schedule meeting with Ema (support) re: formal QA assistance for Samuel | Short-term |
        | Sergio | Formalize test automation as a project with milestone tracking | — |
        """

        let outcomes = MeetingOutputParser.parse(markdown: markdown)

        XCTAssertEqual(outcomes.actions.count, 2)
        XCTAssertEqual(outcomes.actions[0].assignee, "Juan Carlos")
        XCTAssertEqual(
            outcomes.actions[0].text,
            "Schedule meeting with Ema (support) re: formal QA assistance for Samuel — Short-term"
        )
        XCTAssertTrue(outcomes.actions[0].text.hasSuffix(" — Short-term"))
        XCTAssertEqual(outcomes.actions[1].assignee, "Sergio")
        // Dash-only due cell is not appended.
        XCTAssertEqual(
            outcomes.actions[1].text,
            "Formalize test automation as a project with milestone tracking"
        )
        XCTAssertFalse(outcomes.strippedMarkdown.contains("| Owner |"))
        XCTAssertFalse(outcomes.strippedMarkdown.contains("Action Items"))
    }

    func testSpanishTableWithResponsableTareaFecha() {
        let markdown = """
        ### Tareas

        | Responsable | Tarea | Fecha |
        |---|---|---|
        | Luisa | Revisar métricas de Metabase | 20 de julio |
        """

        let outcomes = MeetingOutputParser.parse(markdown: markdown)

        XCTAssertEqual(outcomes.actions.count, 1)
        XCTAssertEqual(outcomes.actions[0].assignee, "Luisa")
        XCTAssertEqual(outcomes.actions[0].text, "Revisar métricas de Metabase — 20 de julio")
    }

    func testHeaderlessTableFallsBackToWidestColumn() {
        let markdown = """
        ## Next Steps

        | Juan | Preparar el reporte trimestral completo |
        | Ana | Enviar correo |
        """

        let outcomes = MeetingOutputParser.parse(markdown: markdown)

        XCTAssertEqual(outcomes.actions.map(\.text), [
            "Preparar el reporte trimestral completo",
            "Enviar correo",
        ])
        XCTAssertEqual(outcomes.actions.map(\.assignee), [nil, nil])
    }

    func testDashOnlyOwnerBecomesNilAssignee() {
        let markdown = """
        ## Tasks

        | Owner | Task | Due |
        |---|---|---|
        | – | Send the recap | - |
        """

        let outcomes = MeetingOutputParser.parse(markdown: markdown)

        XCTAssertEqual(outcomes.actions.count, 1)
        XCTAssertNil(outcomes.actions[0].assignee)
        XCTAssertEqual(outcomes.actions[0].text, "Send the recap")
    }

    func testMixedListAndTableSectionExtractsBoth() {
        let markdown = """
        ## Action Items

        - [ ] Review the budget @Ana

        | Owner | Task |
        |---|---|
        | Luis | Update the roadmap |
        """

        let outcomes = MeetingOutputParser.parse(markdown: markdown)

        XCTAssertEqual(outcomes.actions.count, 2)
        XCTAssertEqual(outcomes.actions[0].text, "Review the budget")
        XCTAssertEqual(outcomes.actions[0].assignee, "Ana")
        XCTAssertEqual(outcomes.actions[1].text, "Update the roadmap")
        XCTAssertEqual(outcomes.actions[1].assignee, "Luis")
        XCTAssertFalse(outcomes.strippedMarkdown.contains("roadmap"))
        XCTAssertFalse(outcomes.strippedMarkdown.contains("budget"))
    }

    func testDecisionTableRowsBecomeDecisionStrings() {
        let markdown = """
        ## Decisiones

        | Decisión | Contexto |
        |---|---|
        | Avanzar con el Escenario B | Discusión larga |
        """

        let outcomes = MeetingOutputParser.parse(markdown: markdown)

        XCTAssertEqual(outcomes.decisions, ["Avanzar con el Escenario B"])
        XCTAssertTrue(outcomes.actions.isEmpty)
    }

    func testTableStrippingLeavesSurroundingContentIntact() {
        let prologue = """
        ## Summary

        Intro paragraph stays.
        """
        let epilogue = """
        ## Wrap-up

        Closing remarks stay.
        """
        let markdown = prologue + """


        ### Acciones

        | Tarea |
        |---|
        | Hacer algo |

        """ + epilogue

        let outcomes = MeetingOutputParser.parse(markdown: markdown)

        XCTAssertEqual(outcomes.actions.map(\.text), ["Hacer algo"])
        XCTAssertTrue(outcomes.strippedMarkdown.hasPrefix(prologue))
        XCTAssertTrue(outcomes.strippedMarkdown.contains(epilogue))
        XCTAssertFalse(outcomes.strippedMarkdown.contains("Acciones"))
        XCTAssertFalse(outcomes.strippedMarkdown.contains("|"))
    }

    // MARK: - Structure preservation

    func testUnrelatedContentSurvivesByteForByte() {
        let prologue = """
        ## Summary

        First paragraph stays.

        Second paragraph — with dashes - and *emphasis* stays too.
        """
        let markdown = prologue + "\n\n## Next Steps\n\n- Do the thing\n"

        let outcomes = MeetingOutputParser.parse(markdown: markdown)

        XCTAssertTrue(outcomes.strippedMarkdown.hasPrefix(prologue))
        XCTAssertFalse(outcomes.strippedMarkdown.contains("Do the thing"))
    }
}

final class MeetingChecklistStoreTests: XCTestCase {
    private static let suiteName = "MeetingChecklistStoreTests"

    private func makeIsolatedDefaults() -> UserDefaults {
        let defaults = UserDefaults(suiteName: Self.suiteName)!
        defaults.removePersistentDomain(forName: Self.suiteName)
        return defaults
    }

    override func tearDown() {
        UserDefaults(suiteName: Self.suiteName)?.removePersistentDomain(forName: Self.suiteName)
        super.tearDown()
    }

    @MainActor
    func testSetDoneRoundTripsThroughPersistence() {
        let defaults = makeIsolatedDefaults()
        let meetingID = UUID()
        let store = MeetingChecklistStore(defaults: defaults)

        XCTAssertFalse(store.isDone(meetingID: meetingID, itemID: "abc"))
        store.setDone(true, meetingID: meetingID, itemID: "abc")
        XCTAssertTrue(store.isDone(meetingID: meetingID, itemID: "abc"))

        // A fresh instance over the same defaults sees the persisted state.
        let reloaded = MeetingChecklistStore(defaults: defaults)
        XCTAssertTrue(reloaded.isDone(meetingID: meetingID, itemID: "abc"))

        reloaded.setDone(false, meetingID: meetingID, itemID: "abc")
        XCTAssertFalse(reloaded.isDone(meetingID: meetingID, itemID: "abc"))

        let reloadedAgain = MeetingChecklistStore(defaults: defaults)
        XCTAssertFalse(reloadedAgain.isDone(meetingID: meetingID, itemID: "abc"))
    }

    @MainActor
    func testDoneCountCountsOnlyRequestedItems() {
        let defaults = makeIsolatedDefaults()
        let meetingID = UUID()
        let store = MeetingChecklistStore(defaults: defaults)

        store.setDone(true, meetingID: meetingID, itemID: "a")
        store.setDone(true, meetingID: meetingID, itemID: "b")
        store.setDone(true, meetingID: meetingID, itemID: "orphan")

        XCTAssertEqual(store.doneCount(meetingID: meetingID, itemIDs: ["a", "b", "c"]), 2)
        XCTAssertEqual(store.doneCount(meetingID: UUID(), itemIDs: ["a"]), 0)
    }

    @MainActor
    func testRemoveAllDropsMeetingState() {
        let defaults = makeIsolatedDefaults()
        let meetingID = UUID()
        let other = UUID()
        let store = MeetingChecklistStore(defaults: defaults)

        store.setDone(true, meetingID: meetingID, itemID: "a")
        store.setDone(true, meetingID: other, itemID: "b")
        store.removeAll(meetingID: meetingID)

        XCTAssertFalse(store.isDone(meetingID: meetingID, itemID: "a"))
        XCTAssertTrue(store.isDone(meetingID: other, itemID: "b"))

        let reloaded = MeetingChecklistStore(defaults: defaults)
        XCTAssertFalse(reloaded.isDone(meetingID: meetingID, itemID: "a"))
        XCTAssertTrue(reloaded.isDone(meetingID: other, itemID: "b"))
    }
}
