import SwiftUI

/// Settings › Meetings: open a calendar meeting's join link automatically when it starts
/// (`MeetingAutoJoinService`). Self-contained `@AppStorage` bindings; the service reads the same
/// keys on every calendar tick, so a change takes effect without a relaunch.
struct MeetingAutoJoinSettingsSection: View {
    @AppStorage(UserDefaultsKeys.meetingsAutoJoinEnabled) private var enabled = true
    @AppStorage(UserDefaultsKeys.meetingsAutoJoinLeadMinutes) private var leadMinutes = MeetingAutoJoinService.defaultLeadMinutes

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(String(localized: "meetings.autoJoin.toggle"), isOn: $enabled)

            Picker(String(localized: "meetings.autoJoin.lead.label"), selection: $leadMinutes) {
                ForEach(MeetingAutoJoinService.leadMinuteChoices, id: \.self) { minutes in
                    Text(label(forMinutes: minutes)).tag(minutes)
                }
            }
            .pickerStyle(.menu)
            .fixedSize()
            .disabled(!enabled)

            Text(String(localized: "meetings.autoJoin.footnote"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func label(forMinutes minutes: Int) -> String {
        minutes == 0
            ? String(localized: "meetings.autoJoin.lead.atStart")
            : String(format: String(localized: "meetings.autoJoin.lead.minutesBefore"), minutes)
    }
}
