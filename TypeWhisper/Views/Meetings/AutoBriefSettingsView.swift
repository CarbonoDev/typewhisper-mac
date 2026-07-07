import SwiftUI

/// [Track D] Automatic pre-meeting brief settings (plan AD9). Toggle plus lead time, minimum
/// attendees, and brief freshness. Backed directly by the `meetings.brief.auto.*` UserDefaults keys
/// the `MeetingBriefScheduler` reads, so changes take effect on the next calendar poll.
struct AutoBriefSettingsView: View {
    @AppStorage(UserDefaultsKeys.meetingsAutoBriefEnabled) private var enabled = true
    @AppStorage(UserDefaultsKeys.meetingsAutoBriefLeadMinutes) private var leadMinutes = 20
    @AppStorage(UserDefaultsKeys.meetingsAutoBriefFreshnessHours) private var freshnessHours = 6
    @AppStorage(UserDefaultsKeys.meetingsAutoBriefMinAttendees) private var minAttendees = 1

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(String(localized: "meetings.brief.auto.sectionTitle"))
                .font(.headline)

            Toggle(String(localized: "meetings.brief.auto.enabledToggle"), isOn: $enabled)

            Text(String(localized: "meetings.brief.auto.explanation"))
                .font(.callout)
                .foregroundStyle(.secondary)

            if enabled {
                Stepper(
                    value: $leadMinutes,
                    in: 5...60,
                    step: 5
                ) {
                    Text(String(
                        format: String(localized: "meetings.brief.auto.leadMinutesLabel"),
                        leadMinutes
                    ))
                }

                Stepper(
                    value: $minAttendees,
                    in: 0...20
                ) {
                    Text(String(
                        format: String(localized: "meetings.brief.auto.minAttendeesLabel"),
                        minAttendees
                    ))
                }

                Stepper(
                    value: $freshnessHours,
                    in: 1...48
                ) {
                    Text(String(
                        format: String(localized: "meetings.brief.auto.freshnessHoursLabel"),
                        freshnessHours
                    ))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
