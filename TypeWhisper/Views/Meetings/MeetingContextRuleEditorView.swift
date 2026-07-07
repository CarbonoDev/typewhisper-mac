import SwiftUI

/// [Track C] Editor for a single capture-context rule (addendum AD7). Edits a local draft and
/// commits on Done. Array trigger dimensions are entered as comma-separated text.
struct MeetingContextRuleEditorView: View {
    @ObservedObject private var viewModel = MeetingsViewModel.shared
    @Environment(\.dismiss) private var dismiss

    let rule: MeetingContextRule

    // Draft state
    @State private var name: String
    @State private var isEnabled: Bool
    @State private var calendarNames: String
    @State private var attendeeDomains: String
    @State private var attendeeEmails: String
    @State private var titleKeywords: String
    @State private var recurringSeriesOnly: Bool
    @State private var liveEngineId: String
    @State private var languageSelection: String
    @State private var defaultTemplateID: UUID?
    @State private var finalMode: FinalMode
    @State private var finalEngineId: String
    @State private var finalModel: String

    private enum FinalMode: Hashable {
        case inherit
        case off
        case sameEngine
        case engine
    }

    /// Sentinel engine id meaning "no override".
    private static let noEngine = ""

    init(rule: MeetingContextRule) {
        self.rule = rule
        let trigger = rule.trigger
        let actions = rule.actions
        _name = State(initialValue: rule.name)
        _isEnabled = State(initialValue: rule.isEnabled)
        _calendarNames = State(initialValue: trigger.calendarNamePatterns.joined(separator: ", "))
        _attendeeDomains = State(initialValue: trigger.attendeeDomains.joined(separator: ", "))
        _attendeeEmails = State(initialValue: trigger.attendeeEmails.joined(separator: ", "))
        _titleKeywords = State(initialValue: trigger.titleKeywords.joined(separator: ", "))
        _recurringSeriesOnly = State(initialValue: trigger.recurringSeriesOnly)
        _liveEngineId = State(initialValue: actions.liveEngineId ?? Self.noEngine)
        _languageSelection = State(initialValue: actions.languageSelection ?? "")
        _defaultTemplateID = State(initialValue: actions.defaultOutputTemplateID)
        _finalEngineId = State(initialValue: "")
        _finalModel = State(initialValue: "")
        switch actions.finalRetranscription {
        case .none: _finalMode = State(initialValue: .inherit)
        case .off: _finalMode = State(initialValue: .off)
        case .sameEngine: _finalMode = State(initialValue: .sameEngine)
        case .engine(let id, let model):
            _finalMode = State(initialValue: .engine)
            _finalEngineId = State(initialValue: id)
            _finalModel = State(initialValue: model ?? "")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section {
                    TextField(String(localized: "meetings.rule.name"), text: $name)
                    Toggle(String(localized: "meetings.rule.enabled"), isOn: $isEnabled)
                }

                Section(String(localized: "meetings.rule.trigger.section")) {
                    labeledField(String(localized: "meetings.rule.trigger.calendarNames"), text: $calendarNames)
                    labeledField(String(localized: "meetings.rule.trigger.attendeeDomains"), text: $attendeeDomains)
                    labeledField(String(localized: "meetings.rule.trigger.attendeeEmails"), text: $attendeeEmails)
                    labeledField(String(localized: "meetings.rule.trigger.titleKeywords"), text: $titleKeywords)
                    Toggle(String(localized: "meetings.rule.trigger.recurringOnly"), isOn: $recurringSeriesOnly)
                }

                Section(String(localized: "meetings.rule.actions.section")) {
                    Picker(String(localized: "meetings.rule.actions.liveEngine"), selection: $liveEngineId) {
                        Text(String(localized: "meetings.rule.actions.useDefault")).tag(Self.noEngine)
                        ForEach(viewModel.transcriptionEngineOptions, id: \.id) { option in
                            Text(option.name).tag(option.id)
                        }
                    }
                    labeledField(String(localized: "meetings.rule.actions.language"), text: $languageSelection)
                    templatePicker
                    finalPassPicker
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Button(String(localized: "meetings.rule.delete"), role: .destructive) {
                    viewModel.deleteRule(rule)
                    dismiss()
                }
                Spacer()
                Button(String(localized: "meetings.rule.done")) {
                    commit()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(minWidth: 460, minHeight: 520)
    }

    private var templatePicker: some View {
        Picker(String(localized: "meetings.rule.actions.defaultTemplate"), selection: $defaultTemplateID) {
            Text(String(localized: "meetings.rule.actions.noTemplate")).tag(UUID?.none)
            ForEach(viewModel.templates, id: \.id) { template in
                Text(template.name).tag(UUID?.some(template.id))
            }
        }
    }

    private var finalPassPicker: some View {
        Group {
            Picker(String(localized: "meetings.rule.actions.finalPass"), selection: $finalMode) {
                Text(String(localized: "meetings.rule.actions.inherit")).tag(FinalMode.inherit)
                Text(String(localized: "meetings.finalPass.mode.off")).tag(FinalMode.off)
                Text(String(localized: "meetings.finalPass.mode.sameEngine")).tag(FinalMode.sameEngine)
                Text(String(localized: "meetings.finalPass.mode.engine")).tag(FinalMode.engine)
            }
            if finalMode == .engine {
                Picker(String(localized: "meetings.finalPass.engine"), selection: $finalEngineId) {
                    ForEach(viewModel.transcriptionEngineOptions, id: \.id) { option in
                        Text(option.name).tag(option.id)
                    }
                }
                labeledField(String(localized: "meetings.finalPass.model"), text: $finalModel)
            }
        }
    }

    private func labeledField(_ label: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            TextField(label, text: text)
            Text(String(localized: "meetings.rule.trigger.commaHint"))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func commit() {
        let trigger = MeetingRuleTrigger(
            calendarNamePatterns: Self.split(calendarNames),
            attendeeDomains: Self.split(attendeeDomains),
            attendeeEmails: Self.split(attendeeEmails),
            titleKeywords: Self.split(titleKeywords),
            recurringSeriesOnly: recurringSeriesOnly
        )
        let finalPolicy: FinalRetranscriptionPolicy?
        switch finalMode {
        case .inherit: finalPolicy = nil
        case .off: finalPolicy = .off
        case .sameEngine: finalPolicy = .sameEngine
        case .engine:
            let trimmedModel = finalModel.trimmingCharacters(in: .whitespacesAndNewlines)
            finalPolicy = .engine(
                id: finalEngineId.isEmpty ? (viewModel.transcriptionEngineOptions.first?.id ?? "") : finalEngineId,
                model: trimmedModel.isEmpty ? nil : trimmedModel
            )
        }
        let trimmedLanguage = languageSelection.trimmingCharacters(in: .whitespacesAndNewlines)
        let actions = MeetingRuleActions(
            liveEngineId: liveEngineId.isEmpty ? nil : liveEngineId,
            liveModelId: nil,
            languageSelection: trimmedLanguage.isEmpty ? nil : trimmedLanguage,
            defaultOutputTemplateID: defaultTemplateID,
            finalRetranscription: finalPolicy
        )
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        viewModel.updateRule(
            rule,
            name: trimmedName.isEmpty ? rule.name : trimmedName,
            trigger: trigger,
            actions: actions,
            isEnabled: isEnabled
        )
    }

    /// Split a comma-separated field into trimmed, non-empty entries.
    private static func split(_ raw: String) -> [String] {
        raw.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}
