import SwiftUI

/// TypeWhisper is free and open source (GPLv3). All features are unlocked for
/// everyone, so there is no license to buy or activate. This view is retained as a
/// simple informational panel; it no longer surfaces any purchase or activation UI.
struct LicenseSettingsView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: "heart.fill")
                        .font(.title2)
                        .foregroundStyle(.pink)
                        .frame(width: 44, height: 44)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.pink.opacity(0.13)))
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 5) {
                        Text(String(localized: "Free & Open Source"))
                            .font(.title2.weight(.semibold))

                        Text(String(localized: "TypeWhisper is free and open source under the GPLv3 license. Every feature is unlocked for everyone — there is nothing to buy or activate."))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: 12)
                }
                .padding(18)
                .frame(maxWidth: 640, alignment: .topLeading)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.white.opacity(0.06))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
                )
            }
            .padding(22)
            .frame(maxWidth: 760, alignment: .topLeading)
        }
        .frame(minWidth: 560, minHeight: 320, alignment: .topLeading)
    }
}
