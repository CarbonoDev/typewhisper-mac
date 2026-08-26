import Foundation

// Meetings coverage for the settings backup (fork adaptation of #932). The upstream backup only knew
// the dictation-side stores; this fork additionally persists three isolated SwiftData stores —
// `meetings.store` (the Meeting aggregate + its cascade children), `participants.store` (the Person
// directory) and `meeting-rules.store` (capture-context rules) — plus a handful of portable
// meetings preferences. Without these DTOs a backup silently drops all meetings data on migration.
//
// Fidelity notes:
//   - Saved meeting audio is intentionally excluded (mirrors History's "text only, no saved audio");
//     `audioFileName` is carried as metadata only and resolves to nil playback on the destination.
//   - Meeting output templates already migrated into `PromptActionService`, so they ride along with
//     the existing `promptActions` backup category and are not duplicated here.
//   - Machine-specific meetings settings (the absolute Obsidian vault path, per-purpose engine/model
//     selections) are excluded for the same reason upstream excludes engine/model choices.
extension SettingsBackupExporter {
    struct MeetingSegmentDTO: Codable {
        var id: UUID
        var order: Int
        var start: Double
        var end: Double
        var text: String
        var speakerLabel: String?
        var speakerConfidence: Double?
        var sourceRaw: String
        var isStable: Bool
    }

    struct MeetingNoteDTO: Codable {
        var id: UUID
        var text: String
        var timestampOffset: Double?
        var createdAt: Date
    }

    struct MeetingOutputDTO: Codable {
        var id: UUID
        var kindRaw: String
        var templateID: UUID?
        var content: String
        var providerUsed: String?
        var modelUsed: String?
        var createdAt: Date
    }

    struct MeetingQATurnDTO: Codable {
        var id: UUID
        var question: String
        var answer: String
        var createdAt: Date
    }

    struct MeetingDTO: Codable {
        var id: UUID
        var title: String
        var stateRaw: String
        var sourceRaw: String
        var startDate: Date?
        var endDate: Date?
        var calendarEventID: String?
        var seriesID: String?
        var attendeesJSON: String?
        var speakerMapJSON: String?
        /// Metadata only — the recording itself is never exported.
        var audioFileName: String?
        var finalRetranscriptionRaw: String?
        var notesIncludedInOutputs: Bool
        var languageCode: String?
        var languageProvenanceRaw: String?
        var obsidianFolder: String?
        var obsidianTagsJSON: String?
        var lastObsidianExportAt: Date?
        var relatedNotePathsJSON: String?
        var excludedNotePathsJSON: String?
        var relatedDiscoveryAt: Date?
        var twoPersonCall: Bool?
        var timestampsRefined: Bool?
        var createdAt: Date
        var updatedAt: Date
        var segments: [MeetingSegmentDTO]
        var notes: [MeetingNoteDTO]
        var outputs: [MeetingOutputDTO]
        var qaTurns: [MeetingQATurnDTO]
    }

    struct PersonDTO: Codable {
        var id: UUID
        var emailKey: String?
        var displayName: String
        var aliasesJSON: String?
        var altEmailsJSON: String?
        var createdAt: Date
        var updatedAt: Date
    }

    struct MeetingContextRuleDTO: Codable {
        var id: UUID
        var name: String
        var isEnabled: Bool
        var sortOrder: Int
        /// `MeetingRuleTrigger` / `MeetingRuleActions`, base64-encoded by JSON `Data` coding.
        var triggerData: Data
        var actionsData: Data
        var createdAt: Date
        var updatedAt: Date
    }

    /// Portable meetings preferences (the machine-agnostic subset). The absolute Obsidian vault path
    /// and per-purpose engine/model selections are deliberately omitted.
    struct MeetingPreferencesDTO: Codable {
        var obsidianRootFolder: String?
        var preferProviderSpeakerLabels: Bool?
        var finalPassDefaultMode: String?
        var autoBriefEnabled: Bool?
        var bridgeToDictationEvents: Bool?
        var calendarDeselectedIDs: [String]?

        static let empty = MeetingPreferencesDTO()

        var nonNilCount: Int {
            var count = 0
            if obsidianRootFolder != nil { count += 1 }
            if preferProviderSpeakerLabels != nil { count += 1 }
            if finalPassDefaultMode != nil { count += 1 }
            if autoBriefEnabled != nil { count += 1 }
            if bridgeToDictationEvents != nil { count += 1 }
            if calendarDeselectedIDs != nil { count += 1 }
            return count
        }
    }

    // MARK: - Meeting DTO mapping

    static func meetingDTOs(from meetings: [Meeting]) -> [MeetingDTO] {
        meetings.map { meeting in
            MeetingDTO(
                id: meeting.id,
                title: meeting.title,
                stateRaw: meeting.stateRaw,
                sourceRaw: meeting.sourceRaw,
                startDate: meeting.startDate,
                endDate: meeting.endDate,
                calendarEventID: meeting.calendarEventID,
                seriesID: meeting.seriesID,
                attendeesJSON: meeting.attendeesJSON,
                speakerMapJSON: meeting.speakerMapJSON,
                audioFileName: meeting.audioFileName,
                finalRetranscriptionRaw: meeting.finalRetranscriptionRaw,
                notesIncludedInOutputs: meeting.notesIncludedInOutputs,
                languageCode: meeting.languageCode,
                languageProvenanceRaw: meeting.languageProvenanceRaw,
                obsidianFolder: meeting.obsidianFolder,
                obsidianTagsJSON: meeting.obsidianTagsJSON,
                lastObsidianExportAt: meeting.lastObsidianExportAt,
                relatedNotePathsJSON: meeting.relatedNotePathsJSON,
                excludedNotePathsJSON: meeting.excludedNotePathsJSON,
                relatedDiscoveryAt: meeting.relatedDiscoveryAt,
                twoPersonCall: meeting.twoPersonCall,
                timestampsRefined: meeting.timestampsRefined,
                createdAt: meeting.createdAt,
                updatedAt: meeting.updatedAt,
                segments: meeting.segments
                    .sorted { $0.order < $1.order }
                    .map { segment in
                        MeetingSegmentDTO(
                            id: segment.id,
                            order: segment.order,
                            start: segment.start,
                            end: segment.end,
                            text: segment.text,
                            speakerLabel: segment.speakerLabel,
                            speakerConfidence: segment.speakerConfidence,
                            sourceRaw: segment.sourceRaw,
                            isStable: segment.isStable
                        )
                    },
                notes: meeting.notes
                    .sorted { $0.createdAt < $1.createdAt }
                    .map { note in
                        MeetingNoteDTO(
                            id: note.id,
                            text: note.text,
                            timestampOffset: note.timestampOffset,
                            createdAt: note.createdAt
                        )
                    },
                outputs: meeting.outputs
                    .sorted { $0.createdAt < $1.createdAt }
                    .map { output in
                        MeetingOutputDTO(
                            id: output.id,
                            kindRaw: output.kindRaw,
                            templateID: output.templateID,
                            content: output.content,
                            providerUsed: output.providerUsed,
                            modelUsed: output.modelUsed,
                            createdAt: output.createdAt
                        )
                    },
                qaTurns: meeting.qaTurns
                    .sorted { $0.createdAt < $1.createdAt }
                    .map { turn in
                        MeetingQATurnDTO(
                            id: turn.id,
                            question: turn.question,
                            answer: turn.answer,
                            createdAt: turn.createdAt
                        )
                    }
            )
        }
    }

    static func personDTOs(from persons: [Person]) -> [PersonDTO] {
        persons.map { person in
            PersonDTO(
                id: person.id,
                emailKey: person.emailKey,
                displayName: person.displayName,
                aliasesJSON: person.aliasesJSON,
                altEmailsJSON: person.altEmailsJSON,
                createdAt: person.createdAt,
                updatedAt: person.updatedAt
            )
        }
    }

    static func meetingRuleDTOs(from rules: [MeetingContextRule]) -> [MeetingContextRuleDTO] {
        rules.map { rule in
            MeetingContextRuleDTO(
                id: rule.id,
                name: rule.name,
                isEnabled: rule.isEnabled,
                sortOrder: rule.sortOrder,
                triggerData: rule.triggerData,
                actionsData: rule.actionsData,
                createdAt: rule.createdAt,
                updatedAt: rule.updatedAt
            )
        }
    }

    // MARK: - Meetings preferences

    static func meetingPreferences(from userDefaults: UserDefaults) -> MeetingPreferencesDTO {
        MeetingPreferencesDTO(
            obsidianRootFolder: userDefaults.string(forKey: UserDefaultsKeys.meetingsObsidianRootFolder),
            preferProviderSpeakerLabels: userDefaults.object(forKey: UserDefaultsKeys.meetingsPreferProviderSpeakerLabels) as? Bool,
            finalPassDefaultMode: userDefaults.string(forKey: UserDefaultsKeys.meetingsFinalPassDefaultMode),
            autoBriefEnabled: userDefaults.object(forKey: UserDefaultsKeys.meetingsAutoBriefEnabled) as? Bool,
            bridgeToDictationEvents: userDefaults.object(forKey: UserDefaultsKeys.meetingsBridgeToDictationEvents) as? Bool,
            calendarDeselectedIDs: userDefaults.stringArray(forKey: UserDefaultsKeys.meetingsCalendarDeselectedIDs)
        )
    }

    /// Applies the portable meetings preferences, mirroring the settings backup's preference
    /// semantics (`#932`): a preference present in the backup is written on import. Registered
    /// defaults (e.g. `meetingsObsidianRootFolder`) mean a "skip if unset" gate could never fire —
    /// `object(forKey:)` returns the registered default, not nil — so, like every other backed-up
    /// preference, a non-nil value is applied. Returns the number of preferences written.
    @discardableResult
    static func applyMeetingPreferences(_ dto: MeetingPreferencesDTO, to userDefaults: UserDefaults) -> Int {
        var applied = 0
        func apply<Value>(_ value: Value?, forKey key: String) {
            guard let value else { return }
            userDefaults.set(value, forKey: key)
            applied += 1
        }
        apply(dto.obsidianRootFolder, forKey: UserDefaultsKeys.meetingsObsidianRootFolder)
        apply(dto.preferProviderSpeakerLabels, forKey: UserDefaultsKeys.meetingsPreferProviderSpeakerLabels)
        apply(dto.finalPassDefaultMode, forKey: UserDefaultsKeys.meetingsFinalPassDefaultMode)
        apply(dto.autoBriefEnabled, forKey: UserDefaultsKeys.meetingsAutoBriefEnabled)
        apply(dto.bridgeToDictationEvents, forKey: UserDefaultsKeys.meetingsBridgeToDictationEvents)
        apply(dto.calendarDeselectedIDs, forKey: UserDefaultsKeys.meetingsCalendarDeselectedIDs)
        return applied
    }
}
