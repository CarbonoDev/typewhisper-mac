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

    // MARK: - Rule-selected default output template (AD7)

    /// The output template of `kind` that the generate flow should pre-select for `meeting`. When a
    /// capture-context rule matched the active/just-captured meeting and chose a default template
    /// (`captureService.activeMeetingDefaultTemplateID`) of this kind, that template wins; otherwise
    /// (no rule, wrong kind, or an orphaned id) it falls back to the kind's current default — the
    /// first template — so the picker is never left without a sensible selection.
    func defaultTemplate(ofKind kind: MeetingOutputKind, for meeting: Meeting) -> PromptAction? {
        let templates = meetingService.templates(ofKind: kind)
        // Scope to the meeting the rule configured (`defaultTemplateMeetingID` persists from the
        // matched-rule capture through the post-stop generate flow, until the next capture), so
        // unrelated meetings browsed afterward fall through to the plain default.
        let ruleTemplateID = (captureService.defaultTemplateMeetingID == meeting.id)
            ? captureService.activeMeetingDefaultTemplateID
            : nil
        return Self.preselectedTemplate(from: templates, ruleTemplateID: ruleTemplateID)
    }

    /// Pure resolver (testable without a live capture): the rule-selected template if its id is
    /// present, else the first template (the current default), else nil for an empty set.
    static func preselectedTemplate(
        from templates: [PromptAction],
        ruleTemplateID: UUID?
    ) -> PromptAction? {
        if let ruleTemplateID, let match = templates.first(where: { $0.id == ruleTemplateID }) {
            return match
        }
        return templates.first
    }

    // MARK: - Per-meeting final re-transcription override (AD8)

    func finalRetranscriptionOverride(for meeting: Meeting) -> FinalRetranscriptionPolicy? {
        meeting.finalRetranscriptionPolicy
    }

    /// Persist (or clear, when `nil`) the per-meeting final re-transcription override.
    func setFinalRetranscriptionOverride(_ policy: FinalRetranscriptionPolicy?, for meeting: Meeting) {
        meeting.finalRetranscriptionPolicy = policy
        meetingService.update(meeting)
        // The detail-view picker reads the override straight off the `meeting` reference; the
        // `meetingService.$meetings` mirror into `self.meetings` is an async main hop, so publish
        // synchronously here for immediate radio-button feedback (mirrors the global setter).
        objectWillChange.send()
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
