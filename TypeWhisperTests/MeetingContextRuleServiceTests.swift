import XCTest
@testable import TypeWhisper

/// [Track C] Capture-context rule matching + store isolation (addendum AD7).
@MainActor
final class MeetingContextRuleServiceTests: XCTestCase {
    private func makeService() throws -> (MeetingContextRuleService, URL) {
        let dir = try TestSupport.makeTemporaryDirectory()
        return (MeetingContextRuleService(appSupportDirectory: dir), dir)
    }

    // MARK: - Individual trigger dimensions

    func testCalendarNameTriggerMatches() throws {
        let (service, dir) = try makeService()
        defer { TestSupport.remove(dir) }
        service.createRule(name: "Work", trigger: MeetingRuleTrigger(calendarNamePatterns: ["Work"]))

        let match = service.match(MeetingContext(title: "Standup", calendarName: "Work"))
        XCTAssertEqual(match?.ruleName, "Work")
        XCTAssertNil(service.match(MeetingContext(title: "Standup", calendarName: "Personal")))
    }

    func testCalendarNameWildcardMatches() throws {
        let (service, dir) = try makeService()
        defer { TestSupport.remove(dir) }
        service.createRule(name: "AcmeCal", trigger: MeetingRuleTrigger(calendarNamePatterns: ["Acme*"]))

        XCTAssertNotNil(service.match(MeetingContext(title: "Sync", calendarName: "Acme Team")))
        XCTAssertNil(service.match(MeetingContext(title: "Sync", calendarName: "Team Acme")))
    }

    func testWildcardWithRepeatedAnchorSegments() throws {
        // Regression: the previous matcher searched for the FIRST occurrence of each
        // segment, so an end-anchored (or middle) segment that repeats in the value was
        // rejected even though the glob matches.
        XCTAssertTrue(MeetingRuleTrigger.patternMatches("a*b", "aXbYb"))
        XCTAssertTrue(MeetingRuleTrigger.patternMatches("*team", "sales team meets team"))
        XCTAssertTrue(MeetingRuleTrigger.patternMatches("*x", "x y x"))
        XCTAssertTrue(MeetingRuleTrigger.patternMatches("a*b*c", "aXbYbZc"))

        // Still correctly rejects non-matches.
        XCTAssertFalse(MeetingRuleTrigger.patternMatches("a*b", "aXbYc"))
        XCTAssertFalse(MeetingRuleTrigger.patternMatches("*x", "x y z"))
        XCTAssertFalse(MeetingRuleTrigger.patternMatches("a*b*b", "ab"))

        // Prefix/suffix anchoring and case-insensitivity preserved.
        XCTAssertTrue(MeetingRuleTrigger.patternMatches("Acme*", "Acme Team"))
        XCTAssertFalse(MeetingRuleTrigger.patternMatches("Acme*", "Team Acme"))
        XCTAssertTrue(MeetingRuleTrigger.patternMatches("acme*b", "AcmeXB"))
    }

    func testAttendeeDomainDerivedFromEmails() throws {
        let (service, dir) = try makeService()
        defer { TestSupport.remove(dir) }
        service.createRule(name: "Acme", trigger: MeetingRuleTrigger(attendeeDomains: ["acme.com"]))

        let match = service.match(MeetingContext(
            title: "Review",
            attendeeEmails: ["jane@acme.com", "bob@other.com"]
        ))
        XCTAssertEqual(match?.ruleName, "Acme")
        // Subdomain suffix matches.
        XCTAssertNotNil(service.match(MeetingContext(title: "x", attendeeEmails: ["a@eu.acme.com"])))
        XCTAssertNil(service.match(MeetingContext(title: "x", attendeeEmails: ["a@notacme.com"])))
    }

    func testExactEmailTrigger() throws {
        let (service, dir) = try makeService()
        defer { TestSupport.remove(dir) }
        service.createRule(name: "VIP", trigger: MeetingRuleTrigger(attendeeEmails: ["ceo@acme.com"]))

        XCTAssertNotNil(service.match(MeetingContext(title: "1:1", attendeeEmails: ["CEO@ACME.COM"])))
        XCTAssertNil(service.match(MeetingContext(title: "1:1", attendeeEmails: ["intern@acme.com"])))
    }

    func testTitleKeywordTrigger() throws {
        let (service, dir) = try makeService()
        defer { TestSupport.remove(dir) }
        service.createRule(name: "Interviews", trigger: MeetingRuleTrigger(titleKeywords: ["interview"]))

        XCTAssertNotNil(service.match(MeetingContext(title: "Candidate Interview – Backend")))
        XCTAssertNil(service.match(MeetingContext(title: "Weekly sync")))
    }

    func testRecurringSeriesOnlyTrigger() throws {
        let (service, dir) = try makeService()
        defer { TestSupport.remove(dir) }
        service.createRule(name: "Recurring", trigger: MeetingRuleTrigger(recurringSeriesOnly: true))

        XCTAssertNotNil(service.match(MeetingContext(title: "Standup", seriesID: "series-1")))
        XCTAssertNil(service.match(MeetingContext(title: "Standup", seriesID: nil)))
    }

    // MARK: - AND semantics + empty trigger

    func testEmptyTriggerNeverMatches() throws {
        let (service, dir) = try makeService()
        defer { TestSupport.remove(dir) }
        service.createRule(name: "Empty", trigger: MeetingRuleTrigger())

        XCTAssertNil(service.match(MeetingContext(title: "Anything", calendarName: "Work")))
    }

    func testAllDeclaredDimensionsMustMatch() throws {
        let (service, dir) = try makeService()
        defer { TestSupport.remove(dir) }
        service.createRule(name: "Both", trigger: MeetingRuleTrigger(
            calendarNamePatterns: ["Work"],
            attendeeDomains: ["acme.com"]
        ))

        // Calendar matches but domain does not → no match.
        XCTAssertNil(service.match(MeetingContext(
            title: "x", attendeeEmails: ["a@other.com"], calendarName: "Work"
        )))
        // Both match.
        XCTAssertNotNil(service.match(MeetingContext(
            title: "x", attendeeEmails: ["a@acme.com"], calendarName: "Work"
        )))
    }

    // MARK: - Precedence + tie-break

    func testSpecificityPrecedence() throws {
        let (service, dir) = try makeService()
        defer { TestSupport.remove(dir) }
        // Least specific first so sortOrder cannot be the deciding factor.
        service.createRule(name: "TitleRule", trigger: MeetingRuleTrigger(titleKeywords: ["sync"]))
        service.createRule(name: "DomainRule", trigger: MeetingRuleTrigger(attendeeDomains: ["acme.com"]))
        service.createRule(name: "EmailRule", trigger: MeetingRuleTrigger(attendeeEmails: ["a@acme.com"]))
        service.createRule(name: "CalDomainRule", trigger: MeetingRuleTrigger(
            calendarNamePatterns: ["Work"], attendeeDomains: ["acme.com"]
        ))

        let context = MeetingContext(
            title: "sync",
            attendeeEmails: ["a@acme.com"],
            calendarName: "Work"
        )
        XCTAssertEqual(service.match(context)?.ruleName, "CalDomainRule")
    }

    func testTieBreakBySortOrderThenName() throws {
        let (service, dir) = try makeService()
        defer { TestSupport.remove(dir) }
        // Same specificity (title keyword). First created gets lower sortOrder and wins.
        let first = service.createRule(name: "Zeta", trigger: MeetingRuleTrigger(titleKeywords: ["sync"]))
        service.createRule(name: "Alpha", trigger: MeetingRuleTrigger(titleKeywords: ["sync"]))

        let match = service.match(MeetingContext(title: "team sync"))
        XCTAssertEqual(match?.ruleID, first.id, "Lower sortOrder must win the tie-break")
    }

    func testDisabledRulesIgnored() throws {
        let (service, dir) = try makeService()
        defer { TestSupport.remove(dir) }
        let rule = service.createRule(name: "Disabled", trigger: MeetingRuleTrigger(titleKeywords: ["sync"]))
        service.setEnabled(false, for: rule)

        XCTAssertNil(service.match(MeetingContext(title: "team sync")))
    }

    // MARK: - Actions round-trip

    func testActionsSurviveStore() throws {
        let (service, dir) = try makeService()
        defer { TestSupport.remove(dir) }
        let templateID = UUID()
        let actions = MeetingRuleActions(
            liveEngineId: "parakeet",
            liveModelId: "small",
            languageSelection: "en",
            defaultOutputTemplateID: templateID,
            finalRetranscription: .engine(id: "assemblyai", model: "best")
        )
        service.createRule(name: "Full", trigger: MeetingRuleTrigger(titleKeywords: ["sync"]), actions: actions)

        let match = service.match(MeetingContext(title: "sync"))
        XCTAssertEqual(match?.actions, actions)
    }

    // MARK: - Store isolation

    func testSecondInstanceRequeriesPersistedRules() throws {
        let dir = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(dir) }
        let first = MeetingContextRuleService(appSupportDirectory: dir)
        first.createRule(name: "Persisted", trigger: MeetingRuleTrigger(titleKeywords: ["sync"]))

        let second = MeetingContextRuleService(appSupportDirectory: dir)
        XCTAssertEqual(second.rules.map(\.name), ["Persisted"])
        XCTAssertNotNil(second.match(MeetingContext(title: "sync")))
    }

    func testRuleCRUDDoesNotTouchMeetingsStore() throws {
        let dir = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(dir) }
        let meetingService = MeetingService(appSupportDirectory: dir)
        _ = meetingService.createMeeting(title: "Existing", source: .adHoc, state: .scheduled)

        let ruleService = MeetingContextRuleService(appSupportDirectory: dir)
        let rule = ruleService.createRule(name: "R", trigger: MeetingRuleTrigger(titleKeywords: ["x"]))
        ruleService.delete(rule)

        let reader = MeetingService(appSupportDirectory: dir)
        XCTAssertEqual(reader.meetings.map(\.title), ["Existing"])
    }
}
