import SwiftUI

@MainActor
struct PremiumSettingsView: View {
    @ObservedObject private var syncController: CloudFolderSyncController
    @AppStorage(UserDefaultsKeys.targetAppCorrectionLearningEnabled) private var targetAppCorrectionLearningEnabled = false

    init(
        syncController: CloudFolderSyncController = ServiceContainer.shared.cloudFolderSyncController
    ) {
        self.syncController = syncController
    }

    var body: some View {
        ScrollView {
            advancedControlCenter
        }
        .frame(minWidth: 560, minHeight: 360, alignment: .topLeading)
    }

    private var statusColumns: [GridItem] {
        [
            GridItem(.adaptive(minimum: 220, maximum: 320), spacing: 12, alignment: .top)
        ]
    }

    private var advancedControlCenter: some View {
        VStack(alignment: .leading, spacing: 18) {
            advancedControlHeader

            LazyVGrid(columns: statusColumns, alignment: .leading, spacing: 12) {
                premiumStatusTile(
                    icon: "wand.and.sparkles",
                    iconColor: targetAppCorrectionLearningEnabled ? .green : .secondary,
                    title: String(localized: "Learning"),
                    value: targetAppCorrectionLearningEnabled ? String(localized: "On") : String(localized: "Off"),
                    description: String(localized: "Learns after direct insertion")
                )

                premiumStatusTile(
                    icon: "cloud",
                    iconColor: cloudSyncStatusColor,
                    title: String(localized: "Sync"),
                    value: cloudSyncStatusText,
                    description: cloudSyncDetailText
                )
            }

            targetAppCorrectionLearningSection

            CloudFolderSyncSettingsView(controller: syncController)
        }
        .padding(22)
        .frame(maxWidth: 760, alignment: .topLeading)
    }

    private var advancedControlHeader: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "sparkles")
                .font(.title2)
                .foregroundStyle(.yellow)
                .frame(width: 44, height: 44)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.yellow.opacity(0.13)))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 5) {
                Text(String(localized: "Correction & Sync"))
                    .font(.title2.weight(.semibold))

                Text(String(localized: "Manage automatic correction learning and dictionary/snippet sync from one place."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)
        }
    }

    private func premiumStatusTile(
        icon: String,
        iconColor: Color,
        title: String,
        value: String,
        description: String
    ) -> some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: icon)
                .font(.headline)
                .foregroundStyle(iconColor)
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(iconColor.opacity(0.12)))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                Text(value)
                    .font(.headline)
                    .lineLimit(1)

                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(0.055))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
        )
    }

    private var targetAppCorrectionLearningSection: some View {
        PremiumControlSection(
            icon: "wand.and.sparkles",
            iconColor: .yellow,
            title: String(localized: "Automatic Correction Learning"),
            description: String(localized: "Corrections are learned only when edits are confident. Ambiguous changes are skipped."),
            statusText: targetAppCorrectionLearningEnabled ? String(localized: "On") : String(localized: "Off"),
            statusColor: targetAppCorrectionLearningEnabled ? .green : .secondary
        ) {
            Toggle(
                String(localized: "Learn corrections from edits after insertion"),
                isOn: $targetAppCorrectionLearningEnabled
            )
            .toggleStyle(.switch)

            VStack(alignment: .leading, spacing: 7) {
                Text(String(localized: "Correction examples"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                correctionExampleRow(PremiumCorrectionExample(before: "teh", after: "the"))
                correctionExampleRow(PremiumCorrectionExample(before: "recieve", after: "receive"))
            }
        }
    }

    private func correctionExampleRow(_ example: PremiumCorrectionExample) -> some View {
        HStack(spacing: 8) {
            Text(example.before)
                .font(.system(.caption, design: .monospaced).weight(.medium))
                .strikethrough(true, color: .secondary)
                .foregroundStyle(.secondary)

            Image(systemName: "arrow.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            Text(example.after)
                .font(.system(.caption, design: .monospaced).weight(.semibold))
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.black.opacity(0.16))
        )
    }

    private var cloudSyncStatusText: String {
        if syncController.isSyncing {
            return String(localized: "Syncing")
        }

        if syncController.selectedFolderURL == nil {
            return String(localized: "Not set up")
        }

        if syncController.pendingChanges > 0 {
            return String.localizedStringWithFormat(
                String(localized: "%d pending"),
                syncController.pendingChanges
            )
        }

        return String(localized: "Ready")
    }

    private var cloudSyncDetailText: String {
        syncController.selectedFolderURL == nil
            ? String(localized: "No folder selected")
            : String(localized: "Folder selected")
    }

    private var cloudSyncStatusColor: Color {
        if syncController.isSyncing {
            return .blue
        }

        if syncController.selectedFolderURL == nil {
            return .secondary
        }

        return syncController.pendingChanges > 0 ? .yellow : .green
    }
}

private struct PremiumCorrectionExample: Identifiable {
    let before: String
    let after: String

    var id: String {
        "\(before)->\(after)"
    }
}

private struct PremiumControlSection<Content: View>: View {
    let icon: String
    let iconColor: Color
    let title: String
    let description: String
    let statusText: String
    let statusColor: Color
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundStyle(iconColor)
                    .frame(width: 38, height: 38)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(iconColor.opacity(0.12)))
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.headline)

                    Text(description)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 12)

                Text(statusText)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(statusColor)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(statusColor.opacity(0.13)))
            }

            VStack(alignment: .leading, spacing: 10) {
                content
            }
            .padding(.leading, 50)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(0.065))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.white.opacity(0.11), lineWidth: 1)
        )
    }
}
