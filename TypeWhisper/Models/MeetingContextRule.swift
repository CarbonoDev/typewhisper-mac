import Foundation
import SwiftData

/// A capture-context rule (addendum AD7): when an about-to-start meeting matches the rule's
/// trigger, the rule's actions override the live engine/model/language, pre-select a default
/// output template, and set the final re-transcription policy.
///
/// Modeled on `Workflow`: opaque `Codable` `Data` columns for the trigger and action payloads so
/// the SwiftData schema shape never changes as those value types evolve. Lives in its own
/// isolated `meeting-rules.store` (never touches `meetings.store`).
@Model
final class MeetingContextRule {
    @Attribute(.unique) var id: UUID
    var name: String
    var isEnabled: Bool
    var sortOrder: Int
    /// JSON-encoded `MeetingRuleTrigger`.
    var triggerData: Data
    /// JSON-encoded `MeetingRuleActions`.
    var actionsData: Data
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        isEnabled: Bool = true,
        sortOrder: Int = 0,
        trigger: MeetingRuleTrigger = MeetingRuleTrigger(),
        actions: MeetingRuleActions = MeetingRuleActions(),
        createdAt: Date = Date(),
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.isEnabled = isEnabled
        self.sortOrder = sortOrder
        self.triggerData = (try? JSONEncoder().encode(trigger)) ?? Data()
        self.actionsData = (try? JSONEncoder().encode(actions)) ?? Data()
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
    }

    var trigger: MeetingRuleTrigger {
        get { (try? JSONDecoder().decode(MeetingRuleTrigger.self, from: triggerData)) ?? MeetingRuleTrigger() }
        set { triggerData = (try? JSONEncoder().encode(newValue)) ?? triggerData }
    }

    var actions: MeetingRuleActions {
        get { (try? JSONDecoder().decode(MeetingRuleActions.self, from: actionsData)) ?? MeetingRuleActions() }
        set { actionsData = (try? JSONEncoder().encode(newValue)) ?? actionsData }
    }
}

extension MeetingContextRule: Identifiable {}

/// The conditions under which a rule fires. Any non-empty dimension must be satisfied (AND
/// semantics); a trigger with every dimension empty never matches (addendum AD7).
struct MeetingRuleTrigger: Codable, Sendable, Equatable {
    /// Calendar (source list) name patterns, e.g. "Work". `*` wildcards supported; otherwise a
    /// case-insensitive substring match.
    var calendarNamePatterns: [String]
    /// Attendee email domains, e.g. "acme.com". Matched against domains derived from attendee
    /// emails (equality or `sub.acme.com` suffix, mirroring `WorkflowService.domainMatches`).
    var attendeeDomains: [String]
    /// Exact attendee email addresses (case-insensitive).
    var attendeeEmails: [String]
    /// Case-insensitive substrings matched against the meeting title.
    var titleKeywords: [String]
    /// When true, only meetings that belong to a recurring calendar series match.
    var recurringSeriesOnly: Bool

    init(
        calendarNamePatterns: [String] = [],
        attendeeDomains: [String] = [],
        attendeeEmails: [String] = [],
        titleKeywords: [String] = [],
        recurringSeriesOnly: Bool = false
    ) {
        self.calendarNamePatterns = calendarNamePatterns
        self.attendeeDomains = attendeeDomains
        self.attendeeEmails = attendeeEmails
        self.titleKeywords = titleKeywords
        self.recurringSeriesOnly = recurringSeriesOnly
    }

    private enum CodingKeys: String, CodingKey {
        case calendarNamePatterns, attendeeDomains, attendeeEmails, titleKeywords, recurringSeriesOnly
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        calendarNamePatterns = try c.decodeIfPresent([String].self, forKey: .calendarNamePatterns) ?? []
        attendeeDomains = try c.decodeIfPresent([String].self, forKey: .attendeeDomains) ?? []
        attendeeEmails = try c.decodeIfPresent([String].self, forKey: .attendeeEmails) ?? []
        titleKeywords = try c.decodeIfPresent([String].self, forKey: .titleKeywords) ?? []
        recurringSeriesOnly = try c.decodeIfPresent(Bool.self, forKey: .recurringSeriesOnly) ?? false
    }

    /// True when the trigger declares no dimension at all (never a match candidate).
    var isEmpty: Bool {
        calendarNamePatterns.isEmpty
            && attendeeDomains.isEmpty
            && attendeeEmails.isEmpty
            && titleKeywords.isEmpty
            && !recurringSeriesOnly
    }
}

/// What a matched rule imposes on the capture session (addendum AD7). All fields optional so a
/// rule can override just one dimension.
struct MeetingRuleActions: Codable, Sendable, Equatable {
    /// Live transcription engine (plugin provider id) to use during capture.
    var liveEngineId: String?
    /// Cloud model id for the live engine (when applicable).
    var liveModelId: String?
    /// Stored language selection string (see `LanguageSelection(storedValue:nilBehavior:)`).
    var languageSelection: String?
    /// Default output template (opaque UUID resolved via `MeetingService.templates(ofKind:)`).
    var defaultOutputTemplateID: UUID?
    /// Final re-transcription policy for meetings captured under this rule.
    var finalRetranscription: FinalRetranscriptionPolicy?

    init(
        liveEngineId: String? = nil,
        liveModelId: String? = nil,
        languageSelection: String? = nil,
        defaultOutputTemplateID: UUID? = nil,
        finalRetranscription: FinalRetranscriptionPolicy? = nil
    ) {
        self.liveEngineId = liveEngineId
        self.liveModelId = liveModelId
        self.languageSelection = languageSelection
        self.defaultOutputTemplateID = defaultOutputTemplateID
        self.finalRetranscription = finalRetranscription
    }

    private enum CodingKeys: String, CodingKey {
        case liveEngineId, liveModelId, languageSelection, defaultOutputTemplateID, finalRetranscription
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        liveEngineId = try c.decodeIfPresent(String.self, forKey: .liveEngineId)
        liveModelId = try c.decodeIfPresent(String.self, forKey: .liveModelId)
        languageSelection = try c.decodeIfPresent(String.self, forKey: .languageSelection)
        defaultOutputTemplateID = try c.decodeIfPresent(UUID.self, forKey: .defaultOutputTemplateID)
        finalRetranscription = try c.decodeIfPresent(FinalRetranscriptionPolicy.self, forKey: .finalRetranscription)
    }
}

/// A plain, EventKit-free description of a meeting used to evaluate rules (addendum AD7). Built
/// from a `Meeting` and/or a `CalendarEventDTO`, so matching is unit-testable without a live
/// calendar store. Attendee domains are derived from the emails.
struct MeetingContext: Equatable, Sendable {
    var title: String
    var attendeeEmails: [String]
    var calendarName: String?
    var seriesID: String?
    var isRecurringSeries: Bool

    init(
        title: String,
        attendeeEmails: [String] = [],
        calendarName: String? = nil,
        seriesID: String? = nil,
        isRecurringSeries: Bool? = nil
    ) {
        self.title = title
        self.attendeeEmails = attendeeEmails
        self.calendarName = calendarName
        self.seriesID = seriesID
        self.isRecurringSeries = isRecurringSeries ?? (seriesID != nil)
    }

    /// Domains parsed from the attendee emails (the part after `@`), lowercased and de-duplicated.
    var attendeeDomains: [String] {
        var seen = Set<String>()
        var result: [String] = []
        for email in attendeeEmails {
            guard let at = email.firstIndex(of: "@") else { continue }
            let domain = String(email[email.index(after: at)...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            guard !domain.isEmpty, seen.insert(domain).inserted else { continue }
            result.append(domain)
        }
        return result
    }
}

/// Result of a successful rule match (addendum AD7). Carries the winning rule's identity,
/// specificity, and resolved actions — a value type (does not expose the `@Model`), so it is
/// `Equatable` and safe to hand to view models and tests.
struct MeetingRuleMatchResult: Equatable, Sendable {
    let ruleID: UUID
    let ruleName: String
    /// Specificity tier of the winning trigger (higher = more specific). See
    /// `MeetingRuleTrigger.specificity`.
    let specificity: Int
    let actions: MeetingRuleActions
}

extension MeetingRuleTrigger {
    /// Specificity tier used for precedence (addendum AD7):
    /// calendar-name+attendee-domain (5) > attendee-email (4) > attendee-domain / calendar-name (3)
    /// > title-keyword (2) > recurring-series-only (1). Empty trigger = 0 (never a candidate).
    var specificity: Int {
        let hasCalendarName = !calendarNamePatterns.isEmpty
        let hasDomains = !attendeeDomains.isEmpty
        let hasEmails = !attendeeEmails.isEmpty
        let hasTitle = !titleKeywords.isEmpty
        if hasCalendarName && hasDomains { return 5 }
        if hasEmails { return 4 }
        if hasDomains { return 3 }
        if hasCalendarName { return 3 }
        if hasTitle { return 2 }
        if recurringSeriesOnly { return 1 }
        return 0
    }

    /// True when every non-empty dimension of the trigger is satisfied by the context (AND
    /// semantics). An empty trigger never matches.
    func matches(_ context: MeetingContext) -> Bool {
        guard !isEmpty else { return false }

        if !calendarNamePatterns.isEmpty {
            guard let calendarName = context.calendarName,
                  calendarNamePatterns.contains(where: { Self.patternMatches($0, calendarName) }) else {
                return false
            }
        }

        if !attendeeDomains.isEmpty {
            let contextDomains = context.attendeeDomains
            guard attendeeDomains.contains(where: { pattern in
                contextDomains.contains { Self.domainMatches($0, pattern: pattern) }
            }) else {
                return false
            }
        }

        if !attendeeEmails.isEmpty {
            let contextEmails = context.attendeeEmails.map { $0.lowercased() }
            guard attendeeEmails.contains(where: { contextEmails.contains($0.lowercased()) }) else {
                return false
            }
        }

        if !titleKeywords.isEmpty {
            let title = context.title.lowercased()
            guard titleKeywords.contains(where: { keyword in
                let k = keyword.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                return !k.isEmpty && title.contains(k)
            }) else {
                return false
            }
        }

        if recurringSeriesOnly {
            guard context.isRecurringSeries else { return false }
        }

        return true
    }

    /// Case-insensitive domain match: equality or a proper subdomain suffix
    /// (`sub.acme.com` matches pattern `acme.com`). Mirrors `WorkflowService.domainMatches`.
    static func domainMatches(_ domain: String, pattern: String) -> Bool {
        let d = domain.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let p = pattern.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !p.isEmpty else { return false }
        return d == p || d.hasSuffix("." + p)
    }

    /// Calendar-name pattern match. Supports `*` wildcards; a bare pattern is a case-insensitive
    /// substring match.
    static func patternMatches(_ pattern: String, _ value: String) -> Bool {
        let p = pattern.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let v = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !p.isEmpty else { return false }
        guard p.contains("*") else { return v.contains(p) }

        // Convert the glob into anchored segments split on `*`.
        let segments = p.components(separatedBy: "*")
        var searchRange = v.startIndex..<v.endIndex
        for (index, segment) in segments.enumerated() where !segment.isEmpty {
            guard let found = v.range(of: segment, range: searchRange) else { return false }
            // First segment (no leading `*`) must anchor at the start.
            if index == 0, !p.hasPrefix("*"), found.lowerBound != v.startIndex { return false }
            searchRange = found.upperBound..<v.endIndex
            // Last segment (no trailing `*`) must anchor at the end.
            if index == segments.count - 1, !p.hasSuffix("*"), found.upperBound != v.endIndex {
                return false
            }
        }
        return true
    }
}
