import SwiftUI

/// [Track C] Capture-context rules list (addendum AD7). Rules pick the live engine/model/language,
/// a default output template, and the final re-transcription policy for matching meetings.
struct MeetingContextRulesView: View {
    @ObservedObject private var viewModel = MeetingsViewModel.shared
    /// Observe the rules store directly so the list reacts to CRUD.
    @ObservedObject private var ruleService = MeetingsViewModel.shared.contextRuleService

    @State private var editingRule: MeetingContextRule?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(String(localized: "meetings.rule.section.title"))
                    .font(.headline)
                Spacer()
                Button {
                    let rule = viewModel.createRule(name: String(localized: "meetings.rule.newRuleName"))
                    editingRule = rule
                } label: {
                    Label(String(localized: "meetings.rule.add"), systemImage: "plus")
                }
            }
            Text(String(localized: "meetings.rule.section.subtitle"))
                .font(.caption)
                .foregroundStyle(.secondary)

            if ruleService.rules.isEmpty {
                Text(String(localized: "meetings.rule.empty"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            } else {
                ForEach(ruleService.rules, id: \.id) { rule in
                    ruleRow(rule)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .sheet(item: $editingRule) { rule in
            MeetingContextRuleEditorView(rule: rule)
        }
    }

    private func ruleRow(_ rule: MeetingContextRule) -> some View {
        HStack(spacing: 8) {
            Toggle("", isOn: Binding(
                get: { rule.isEnabled },
                set: { viewModel.setRuleEnabled($0, for: rule) }
            ))
            .labelsHidden()

            VStack(alignment: .leading, spacing: 2) {
                Text(rule.name)
                    .font(.body)
                Text(triggerSummary(rule.trigger))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button(String(localized: "meetings.rule.edit")) {
                editingRule = rule
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    /// A short human summary of what the rule triggers on.
    private func triggerSummary(_ trigger: MeetingRuleTrigger) -> String {
        var parts: [String] = []
        if !trigger.calendarNamePatterns.isEmpty {
            parts.append(trigger.calendarNamePatterns.joined(separator: ", "))
        }
        if !trigger.attendeeDomains.isEmpty {
            parts.append(trigger.attendeeDomains.joined(separator: ", "))
        }
        if !trigger.attendeeEmails.isEmpty {
            parts.append(trigger.attendeeEmails.joined(separator: ", "))
        }
        if !trigger.titleKeywords.isEmpty {
            parts.append(trigger.titleKeywords.joined(separator: ", "))
        }
        if trigger.recurringSeriesOnly {
            parts.append(String(localized: "meetings.rule.trigger.recurringOnly"))
        }
        return parts.isEmpty
            ? String(localized: "meetings.rule.trigger.empty")
            : parts.joined(separator: " · ")
    }
}
