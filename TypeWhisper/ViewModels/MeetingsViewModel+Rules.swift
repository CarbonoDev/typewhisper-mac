import Foundation

/// [Track C] Capture-context rules (addendum AD7) and configurable final re-transcription
/// (addendum AD8) surface for the Meetings view model. Rule CRUD delegates to
/// `contextRuleService`; the per-meeting override and global default persist through
/// `meetingService` / `UserDefaults`. Views observe `contextRuleService` directly for rule-list
/// reactivity.
extension MeetingsViewModel {
    // MARK: - Rule CRUD (delegates to the isolated rules store)

    var contextRules: [MeetingContextRule] {
        contextRuleService.rules
    }

    @discardableResult
    func createRule(
        name: String,
        trigger: MeetingRuleTrigger = MeetingRuleTrigger(),
        actions: MeetingRuleActions = MeetingRuleActions(),
        isEnabled: Bool = true
    ) -> MeetingContextRule {
        contextRuleService.createRule(name: name, trigger: trigger, actions: actions, isEnabled: isEnabled)
    }

    func updateRule(
        _ rule: MeetingContextRule,
        name: String? = nil,
        trigger: MeetingRuleTrigger? = nil,
        actions: MeetingRuleActions? = nil,
        isEnabled: Bool? = nil
    ) {
        contextRuleService.update(rule, name: name, trigger: trigger, actions: actions, isEnabled: isEnabled)
    }

    func setRuleEnabled(_ enabled: Bool, for rule: MeetingContextRule) {
        contextRuleService.setEnabled(enabled, for: rule)
    }

    func deleteRule(_ rule: MeetingContextRule) {
        contextRuleService.delete(rule)
    }

    func moveRules(fromOffsets source: IndexSet, toOffset destination: Int) {
        contextRuleService.move(fromOffsets: source, toOffset: destination)
    }

    // MARK: - Context building + resolution preview

    /// Build the rule-matching context from a persisted meeting (calendar name is unavailable
    /// post-creation, so nil).
    func ruleContext(for meeting: Meeting) -> MeetingContext {
        MeetingContext(
            title: meeting.title,
            attendeeEmails: meeting.attendees.compactMap(\.email),
            calendarName: nil,
            seriesID: meeting.seriesID,
            isRecurringSeries: meeting.seriesID != nil
        )
    }

    /// Build the rule-matching context from a calendar event (full context including calendar
    /// name) — used for the settings resolution preview and by auto-brief windowing.
    func ruleContext(for event: CalendarEventDTO) -> MeetingContext {
        MeetingContext(
            title: event.title,
            attendeeEmails: event.attendees.compactMap(\.email),
            calendarName: event.calendarName,
            seriesID: event.seriesID,
            isRecurringSeries: event.seriesID != nil
        )
    }

    /// The rule that would win for a given calendar event (preview in the rules UI), or nil.
    func resolvedRule(for event: CalendarEventDTO) -> MeetingRuleMatchResult? {
        contextRuleService.match(ruleContext(for: event))
    }

    /// The rule that would win for a given meeting, or nil.
    func resolvedRule(for meeting: Meeting) -> MeetingRuleMatchResult? {
        contextRuleService.match(ruleContext(for: meeting))
    }

    // MARK: - Per-meeting final re-transcription override (AD8)

    func finalRetranscriptionOverride(for meeting: Meeting) -> FinalRetranscriptionPolicy? {
        meeting.finalRetranscriptionPolicy
    }

    /// Persist (or clear, when `nil`) the per-meeting final re-transcription override.
    func setFinalRetranscriptionOverride(_ policy: FinalRetranscriptionPolicy?, for meeting: Meeting) {
        meeting.finalRetranscriptionPolicy = policy
        meetingService.update(meeting)
    }

    // MARK: - Global final re-transcription default (AD8)

    var globalFinalRetranscriptionPolicy: FinalRetranscriptionPolicy {
        get {
            FinalRetranscriptionPolicy(
                mode: UserDefaults.standard.string(forKey: UserDefaultsKeys.meetingsFinalPassDefaultMode),
                engineId: UserDefaults.standard.string(forKey: UserDefaultsKeys.meetingsFinalPassEngineId),
                model: UserDefaults.standard.string(forKey: UserDefaultsKeys.meetingsFinalPassModel)
            ) ?? .sameEngine
        }
        set {
            let defaults = UserDefaults.standard
            defaults.set(newValue.modeRawValue, forKey: UserDefaultsKeys.meetingsFinalPassDefaultMode)
            switch newValue {
            case .engine(let id, let model):
                defaults.set(id, forKey: UserDefaultsKeys.meetingsFinalPassEngineId)
                defaults.set(model ?? "", forKey: UserDefaultsKeys.meetingsFinalPassModel)
            case .off, .sameEngine:
                defaults.removeObject(forKey: UserDefaultsKeys.meetingsFinalPassEngineId)
                defaults.removeObject(forKey: UserDefaultsKeys.meetingsFinalPassModel)
            }
            objectWillChange.send()
        }
    }

    // MARK: - Picker options

    /// Installed transcription engines for the rule/final-pass engine pickers.
    var transcriptionEngineOptions: [(id: String, name: String)] {
        PluginManager.shared.transcriptionEngines.map { ($0.providerId, $0.providerDisplayName) }
    }
}
