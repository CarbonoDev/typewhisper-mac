import Foundation
import SwiftData
import Combine
import os.log

private let ruleLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "TypeWhisper",
    category: "MeetingContextRuleService"
)

/// Fakeable matching seam so `MeetingCaptureService` (and tests) can resolve a context to a rule
/// without owning the store.
@MainActor
protocol MeetingContextRuleMatching: AnyObject {
    func match(_ context: MeetingContext) -> MeetingRuleMatchResult?
}

/// Owns the isolated `meeting-rules.store` and evaluates capture-context rules (addendum AD7).
/// Matching mirrors `WorkflowService.matchWorkflow`: specificity tiers with a `sortOrder`-then-name
/// tie-break over `Codable` `Data` trigger/action columns. Pure `match(_:)` is unit-testable via
/// the `init(appSupportDirectory:)` seam.
@MainActor
final class MeetingContextRuleService: ObservableObject, MeetingContextRuleMatching {
    @Published private(set) var rules: [MeetingContextRule] = []

    private let modelContainer: ModelContainer
    private let modelContext: ModelContext

    init(appSupportDirectory: URL = AppConstants.appSupportDirectory) {
        do {
            let (container, context) = try SwiftDataStoreFactory.create(
                for: [MeetingContextRule.self],
                storeName: "meeting-rules",
                in: appSupportDirectory
            )
            modelContainer = container
            modelContext = context
        } catch {
            fatalError("Failed to initialize meeting-rules store: \(error)")
        }
        fetchRules()
    }

    // MARK: - CRUD

    @discardableResult
    func createRule(
        name: String,
        trigger: MeetingRuleTrigger = MeetingRuleTrigger(),
        actions: MeetingRuleActions = MeetingRuleActions(),
        isEnabled: Bool = true
    ) -> MeetingContextRule {
        let nextSortOrder = (rules.map(\.sortOrder).max() ?? -1) + 1
        let rule = MeetingContextRule(
            name: name,
            isEnabled: isEnabled,
            sortOrder: nextSortOrder,
            trigger: trigger,
            actions: actions
        )
        modelContext.insert(rule)
        save()
        fetchRules()
        return rule
    }

    func update(
        _ rule: MeetingContextRule,
        name: String? = nil,
        trigger: MeetingRuleTrigger? = nil,
        actions: MeetingRuleActions? = nil,
        isEnabled: Bool? = nil
    ) {
        if let name { rule.name = name }
        if let trigger { rule.trigger = trigger }
        if let actions { rule.actions = actions }
        if let isEnabled { rule.isEnabled = isEnabled }
        rule.updatedAt = Date()
        save()
        fetchRules()
    }

    func setEnabled(_ enabled: Bool, for rule: MeetingContextRule) {
        guard rule.isEnabled != enabled else { return }
        rule.isEnabled = enabled
        rule.updatedAt = Date()
        save()
        fetchRules()
    }

    func delete(_ rule: MeetingContextRule) {
        modelContext.delete(rule)
        save()
        fetchRules()
    }

    /// Restore capture-context rules from a settings backup (fork adaptation of #932). Additive by
    /// `id`: a rule whose id already exists in `meeting-rules.store` is skipped, never overwritten.
    /// The encoded `triggerData`/`actionsData` blobs and `sortOrder` are preserved verbatim so the
    /// round-trip is faithful. Single-writer on the MainActor. Returns the number of rules inserted.
    @discardableResult
    func importRules(_ dtos: [SettingsBackupExporter.MeetingContextRuleDTO]) -> Int {
        let existingIDs = Set(rules.map(\.id))
        var imported = 0
        for dto in dtos where !existingIDs.contains(dto.id) {
            let rule = MeetingContextRule(
                id: dto.id,
                name: dto.name,
                isEnabled: dto.isEnabled,
                sortOrder: dto.sortOrder,
                createdAt: dto.createdAt,
                updatedAt: dto.updatedAt
            )
            rule.triggerData = dto.triggerData
            rule.actionsData = dto.actionsData
            modelContext.insert(rule)
            imported += 1
        }
        if imported > 0 {
            save()
            fetchRules()
        }
        return imported
    }

    /// Persist a new ordering (drag-to-reorder in the rules list); `sortOrder` drives the match
    /// tie-break.
    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        var reordered = rules
        reordered.move(fromOffsets: source, toOffset: destination)
        for (index, rule) in reordered.enumerated() where rule.sortOrder != index {
            rule.sortOrder = index
            rule.updatedAt = Date()
        }
        save()
        fetchRules()
    }

    // MARK: - Matching

    /// The highest-specificity enabled rule whose trigger matches `context`, tie-broken by
    /// `sortOrder` then case-insensitive name (addendum AD7). Returns `nil` when nothing matches.
    func match(_ context: MeetingContext) -> MeetingRuleMatchResult? {
        let candidates = rules
            .filter(\.isEnabled)
            .compactMap { rule -> (rule: MeetingContextRule, specificity: Int)? in
                let trigger = rule.trigger
                guard trigger.matches(context) else { return nil }
                let specificity = trigger.specificity
                guard specificity > 0 else { return nil }
                return (rule, specificity)
            }

        let best = candidates.max { lhs, rhs in
            if lhs.specificity != rhs.specificity {
                return lhs.specificity < rhs.specificity
            }
            if lhs.rule.sortOrder != rhs.rule.sortOrder {
                // Lower sortOrder wins → it must sort as "greater" for `max`.
                return lhs.rule.sortOrder > rhs.rule.sortOrder
            }
            // Earlier name (case-insensitive) wins → sorts as "greater" for `max`.
            return lhs.rule.name.localizedCaseInsensitiveCompare(rhs.rule.name) == .orderedDescending
        }

        guard let best else { return nil }
        return MeetingRuleMatchResult(
            ruleID: best.rule.id,
            ruleName: best.rule.name,
            specificity: best.specificity,
            actions: best.rule.actions
        )
    }

    // MARK: - Store plumbing

    private func fetchRules() {
        let descriptor = FetchDescriptor<MeetingContextRule>(
            sortBy: [SortDescriptor(\.sortOrder, order: .forward), SortDescriptor(\.name)]
        )
        do {
            rules = try modelContext.fetch(descriptor)
        } catch {
            ruleLogger.error("Fetch failed: \(error.localizedDescription)")
            rules = []
        }
    }

    private func save() {
        do {
            try modelContext.save()
        } catch {
            ruleLogger.error("Save failed: \(error.localizedDescription)")
        }
    }
}
