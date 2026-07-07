import SwiftUI

/// [Track B] The meeting document header (plan D4): a serif title, a status line (date, LIVE chip
/// while capturing, attendee count), a chip row (output selector incl. custom templates, date +
/// attendees, folder / tags, export), the **primary prominent Start button** on scheduled meetings
/// (owner discoverability requirement #1), and the interrupted / degraded status banners.
struct MeetingDocumentHeader: View {
    @ObservedObject private var viewModel = MeetingsViewModel.shared
    @ObservedObject var model: MeetingDocumentModel
    let meeting: Meeting
    let presentation: MeetingsViewModel.DocumentPresentation

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            titleBlock
            chipRow
            if presentation.contextAction == .start {
                primaryStartButton
            }
            banners
        }
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(meeting.title)
                .font(.largeTitle)
                .fontDesign(.serif)
                .bold()
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 10) {
                if presentation.showsLiveChip {
                    liveChip
                }
                if let start = meeting.startDate {
                    Label {
                        Text(start, format: .dateTime.weekday().month().day().hour().minute())
                    } icon: {
                        Image(systemName: "calendar")
                    }
                }
                if !meeting.attendees.isEmpty {
                    Label {
                        Text("\(meeting.attendees.count)")
                    } icon: {
                        Image(systemName: "person.2")
                    }
                }
                if !presentation.showsLiveChip {
                    Text(meeting.state.displayName)
                }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
    }

    private var liveChip: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(.red)
                .frame(width: 8, height: 8)
            Text(String(localized: "meetingdoc.live"))
                .font(.caption.bold())
            Text(MeetingTranscriptPanel.timestamp(viewModel.captureElapsedSeconds))
                .font(.caption.monospacedDigit())
        }
        .foregroundStyle(.red)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(.red.opacity(0.12), in: Capsule())
    }

    // MARK: - Chip row

    private var chipRow: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) { chips }
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) { chips }
            }
        }
    }

    @ViewBuilder
    private var chips: some View {
        outputSelectorChip
        folderTagsChip
        exportChip
    }

    private var outputSelectorChip: some View {
        Menu {
            ForEach(MeetingsViewModel.selectableOutputKinds, id: \.self) { kind in
                Button {
                    model.selectedOutputKind = kind
                } label: {
                    if kind == model.selectedOutputKind {
                        Label(MeetingsViewModel.outputKindLabel(kind), systemImage: "checkmark")
                    } else {
                        Text(MeetingsViewModel.outputKindLabel(kind))
                    }
                }
            }
            let customTemplates = customTemplateRows
            if !customTemplates.isEmpty {
                Divider()
                Section(String(localized: "meetingdoc.output.customTemplates")) {
                    ForEach(customTemplates, id: \.id) { template in
                        Button(template.name) {
                            model.selectedOutputKind = kind(of: template)
                            Task { await viewModel.generateOutput(for: meeting, using: template) }
                        }
                    }
                }
            }
        } label: {
            chipLabel(
                icon: "doc.text",
                text: MeetingsViewModel.outputKindLabel(model.selectedOutputKind)
            )
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private var folderTagsChip: some View {
        Button {
            model.isPresentingExport = true
        } label: {
            let folder = meeting.obsidianFolder?.trimmingCharacters(in: .whitespaces)
            let text = (folder?.isEmpty == false)
                ? folder!
                : String(localized: "meetingdoc.chip.noFolder")
            chipLabel(icon: "folder", text: text, trailingCount: meeting.obsidianTags.count)
        }
        .buttonStyle(.plain)
    }

    private var exportChip: some View {
        Button {
            model.isPresentingExport = true
        } label: {
            chipLabel(icon: "square.and.arrow.up", text: String(localized: "meetingdoc.chip.export"))
        }
        .buttonStyle(.plain)
    }

    private func chipLabel(icon: String, text: String, trailingCount: Int = 0) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
            Text(text)
                .lineLimit(1)
            if trailingCount > 0 {
                Text("\(trailingCount)")
                    .font(.caption2)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(.secondary.opacity(0.2), in: Capsule())
            }
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.secondary.opacity(0.12), in: Capsule())
    }

    // MARK: - Primary Start button (owner requirement #1)

    private var primaryStartButton: some View {
        Button {
            Task { await viewModel.startCapture(for: meeting) }
        } label: {
            Label(String(localized: "meetingdoc.start.primary"), systemImage: "record.circle.fill")
                .font(.title3.bold())
                .padding(.vertical, 4)
                .padding(.horizontal, 8)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .tint(.red)
        .disabled(!viewModel.canStartCapture)
    }

    // MARK: - Banners

    @ViewBuilder
    private var banners: some View {
        if meeting.state == .interrupted {
            banner(String(localized: "meetings.detail.interruptedBanner"), icon: "exclamationmark.triangle")
        }
        if viewModel.finalRetranscriptionDegradedMeetingID == meeting.id {
            banner(String(localized: "meetings.finalPass.degradedStatus"), icon: "wifi.exclamationmark")
        }
        if let error = viewModel.captureErrorMessage {
            banner(error, icon: "exclamationmark.octagon", tint: .red)
        }
    }

    private func banner(_ text: String, icon: String, tint: Color = .orange) -> some View {
        Label(text, systemImage: icon)
            .font(.callout)
            .foregroundStyle(tint)
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Custom template helpers

    private var customTemplateRows: [PromptAction] {
        // Templates beyond the first (default) per kind surface as explicit "custom" generate rows.
        MeetingsViewModel.selectableOutputKinds.flatMap { kind in
            viewModel.templates(ofKind: kind).dropFirst()
        }
    }

    private func kind(of template: PromptAction) -> MeetingOutputKind {
        for kind in MeetingsViewModel.selectableOutputKinds
        where viewModel.templates(ofKind: kind).contains(where: { $0.id == template.id }) {
            return kind
        }
        return model.selectedOutputKind
    }
}
