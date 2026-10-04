import SwiftUI
import TranscriberCore

/// The left pane: everything that decides what a batch does, top to bottom in the
/// order you decide it. Pick a model, pick a language, pick where the files go,
/// then press the one button at the bottom.
struct ConfigurationPanel: View {
    @ObservedObject var store: TranscriptionStore
    @State private var isShowingOptions = false

    private var isBusy: Bool { store.isRunning || store.isPreparingModel }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.page + Space.close) {
                    modelSection
                    languageSection
                    outputSection

                    if let issue = store.setupIssue {
                        IssueBanner(issue: issue) { tab in
                            store.page = .settings(tab)
                        }
                    }
                }
                .padding(Space.page)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()

            startArea
        }
        .background(Palette.contentBackground)
    }

    // MARK: Model

    private var modelSection: some View {
        PanelSection(title: "Model", step: 1) {
            VStack(spacing: Space.close) {
                ForEach(store.installedModelPresets) { preset in
                    ModelCard(
                        title: preset.displayName,
                        subtitle: ModelChoice.tagline(for: preset),
                        footnote: store.modelStatus(for: preset)?.sizeDescription,
                        badge: nil,
                        isSelected: store.isActiveModel(preset),
                        isDisabled: isBusy
                    ) {
                        store.selectModel(preset)
                    }
                }

                ModelCard(
                    title: "Google Gemini",
                    subtitle: "Cloud · sends audio to Google",
                    footnote: nil,
                    badge: store.geminiUsableAPIKeyCount == 0 ? "Needs API key" : nil,
                    isSelected: store.isUsingGeminiTranscription,
                    isDisabled: isBusy
                ) {
                    store.useGeminiTranscription()
                }

                if store.installedModelPresets.isEmpty && store.didFinishModelScan {
                    Text("No speech models are installed on this Mac yet.")
                        .font(Typography.caption)
                        .foregroundStyle(Palette.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Button(store.installedModelPresets.isEmpty ? "Download a Model…" : "Get More Models…") {
                    store.page = .settings(.models)
                }
                .buttonStyle(.link)
                .font(Typography.caption)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: Language

    private var languageSection: some View {
        PanelSection(title: "Language", step: 2) {
            Picker("Language", selection: $store.localeIdentifier) {
                ForEach(WhisperLanguagePreset.all) { preset in
                    Text(preset.displayName).tag(preset.id)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .disabled(isBusy)
            .accessibilityLabel("Language")
        }
    }

    // MARK: Output

    private var outputSection: some View {
        PanelSection(title: "Output", step: 3) {
            VStack(alignment: .leading, spacing: Space.close) {
                DisclosureGroup(isExpanded: $isShowingOptions) {
                    OutputOptionsView(store: store)
                        .padding(.top, Space.close)
                } label: {
                    HStack(spacing: Space.close) {
                        Text("Files")
                            .foregroundStyle(Palette.textSecondary)
                        Spacer(minLength: Space.close)
                        Text(store.outputFormatSummary)
                            .lineLimit(1)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { isShowingOptions.toggle() }
                }

                HStack(spacing: Space.close) {
                    Image(systemName: "folder")
                        .foregroundStyle(Palette.textSecondary)
                        .accessibilityHidden(true)

                    Text(store.outputPathForDisplay)
                        .font(Typography.caption)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(store.currentOutputDirectory.path)

                    Spacer(minLength: 0)
                }

                HStack(spacing: Space.group) {
                    Button("Show in Finder") { store.revealOutputDirectory() }
                    Button("Change…") { store.presentOutputDirectoryPicker() }
                        .disabled(isBusy)
                }
                .buttonStyle(.link)
                .font(Typography.caption)
            }
        }
    }

    // MARK: Start

    private var startArea: some View {
        VStack(alignment: .leading, spacing: Space.close) {
            if !isBusy, let reason = store.startBlockedReason {
                Label(reason, systemImage: "info.circle")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.warning)
                    .fixedSize(horizontal: false, vertical: true)
            } else if !isBusy, store.jobs.isEmpty {
                Text("Add files to begin.")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textSecondary)
            }

            Button {
                if isBusy {
                    store.cancelBatch()
                } else {
                    store.startBatch()
                }
            } label: {
                HStack(spacing: Space.close) {
                    if store.isPreparingModel {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: isBusy ? "stop.fill" : "play.fill")
                    }
                    Text(startTitle)
                }
                .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .tint(isBusy ? Palette.danger : Palette.accent)
            .disabled(!isBusy && !store.canStart)
            .keyboardShortcut(.return, modifiers: [.command])
            .help(isBusy ? "Stop the batch" : "Transcribe the queued files (⌘↩)")
        }
        .padding(Space.page)
    }

    private var startTitle: String {
        if store.isPreparingModel { return "Checking model… Cancel" }
        if store.isRunning { return "Stop" }
        let count = store.queuedJobCount
        guard count > 0 else { return "Transcribe" }
        return count == 1 ? "Transcribe 1 File" : "Transcribe \(count) Files"
    }
}

private struct PanelSection<Content: View>: View {
    let title: String
    let step: Int
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: Space.close) {
            HStack(spacing: Space.close) {
                Text("\(step)")
                    .font(.system(size: 10, weight: .bold).monospacedDigit())
                    .foregroundStyle(Color.white)
                    .frame(width: 16, height: 16)
                    .background(Circle().fill(Palette.textSecondary))
                    .accessibilityHidden(true)

                Text(title)
                    .font(Typography.sectionHeader)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)

            content()
        }
    }
}

/// One selectable model. A visible card with a radio mark reads as a choice at a
/// glance, where a closed pop-up menu hides the options it offers.
private struct ModelCard: View {
    let title: String
    let subtitle: String
    let footnote: String?
    let badge: String?
    let isSelected: Bool
    let isDisabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: Space.close) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(isSelected ? Palette.accent : Palette.textTertiary)
                    .font(.system(size: 14))
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: Space.optical) {
                    Text(title)
                        .font(Typography.rowTitleEmphasized)
                        .foregroundStyle(Palette.textPrimary)
                        .multilineTextAlignment(.leading)

                    Text(subtitle)
                        .font(Typography.caption)
                        .foregroundStyle(Palette.textSecondary)
                        .multilineTextAlignment(.leading)

                    if let footnote {
                        Text(footnote)
                            .font(Typography.caption)
                            .foregroundStyle(Palette.textTertiary)
                    }

                    if let badge {
                        Text(badge)
                            .font(Typography.caption.weight(.medium))
                            .foregroundStyle(Palette.warning)
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(Space.close + Space.optical)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Radius.card)
                    .fill(isSelected ? Palette.accentFill : Palette.pageBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Radius.card)
                    .strokeBorder(isSelected ? Palette.accent : Palette.hairline, lineWidth: isSelected ? 1.5 : 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: Radius.card))
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .accessibilityLabel(title)
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
        .accessibilityHint(subtitle)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

/// A problem with the setup, with a button that goes to the fix.
private struct IssueBanner: View {
    let issue: SetupIssue
    let fix: (SettingsTab) -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.close) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
                .accessibilityHidden(true)

            Text(issue.message)
                .font(Typography.keyValue)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: Space.close)

            if let label = issue.fixLabel, let tab = issue.fixTab {
                Button(label) { fix(tab) }
                    .controlSize(.small)
            }
        }
        .padding(Space.close)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(fill, in: RoundedRectangle(cornerRadius: Radius.control))
        .accessibilityElement(children: .combine)
    }

    private var symbol: String {
        switch issue.severity {
        case .error: return "xmark.octagon.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .info: return "info.circle.fill"
        }
    }

    private var tint: Color {
        switch issue.severity {
        case .error: return Palette.danger
        case .warning: return Palette.warning
        case .info: return Palette.textSecondary
        }
    }

    private var fill: Color {
        switch issue.severity {
        case .error: return Palette.dangerFill
        case .warning: return Palette.warningFill
        case .info: return Palette.accentFill
        }
    }
}

/// Which files get written, and the few output switches people actually change.
struct OutputOptionsView: View {
    @ObservedObject var store: TranscriptionStore

    var body: some View {
        VStack(alignment: .leading, spacing: Space.group) {
            VStack(alignment: .leading, spacing: Space.close) {
                ForEach(Self.commonFormats) { format in
                    formatToggle(format)
                }

                DisclosureGroup("More formats", isExpanded: $isShowingMoreFormats) {
                    VStack(alignment: .leading, spacing: Space.close) {
                        ForEach(Self.advancedFormats) { format in
                            formatToggle(format)
                        }
                    }
                    .padding(.top, Space.close)
                }
                .font(Typography.caption)
            }

            if !isUsableFormatSelection(store.selectedFormats) {
                Label("Choose at least one file to write.", systemImage: "exclamationmark.triangle.fill")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.warning)
            }

            if !modelProvidesWordTimestamps {
                Label(
                    "This model does not produce word-level timing, so Word Timings and Apple Music TTML are unavailable.",
                    systemImage: "info.circle"
                )
                .font(Typography.caption)
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            Toggle("Show a transcript preview when done", isOn: $store.showTranscriptPreview)
                .help("Off: just process everything, then show where it was saved.")
            Toggle("Put each batch in its own folder", isOn: $store.createBatchFolder)
            Toggle("Name transcripts after what is said", isOn: $store.smartTranscriptNamingEnabled)
                .help("Uses FreeLLMAPI when it is open. Set it up in Settings.")
            Toggle("Add subtitles to the video files", isOn: $store.attachCaptionedVideoToSource)
                .help("Replaces the video in place and keeps the original in a backup folder.")

            Button("More in Settings…") {
                store.page = .settings(.general)
            }
            .buttonStyle(.link)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private static let commonFormats: [ExportFormat] = [.text, .timestampedText, .srt, .vtt]
    private static let advancedFormats: [ExportFormat] =
        ExportFormat.visibleManualFormats.filter { !commonFormats.contains($0) }

    @State private var isShowingMoreFormats = false

    private func formatToggle(_ format: ExportFormat) -> some View {
        Toggle(format.displayName, isOn: formatBinding(format))
            .toggleStyle(.checkbox)
            .disabled(format.needsWordTimestamps && !modelProvidesWordTimestamps)
            .help(formatHelp(format))
    }

    private var modelProvidesWordTimestamps: Bool {
        WhisperModelPreset.preset(for: store.effectiveSelectedModelIdentifier)?
            .supportsWordTimestamps ?? true
    }

    private func formatBinding(_ format: ExportFormat) -> Binding<Bool> {
        Binding(
            get: { store.selectedFormats.contains(format) },
            set: { isEnabled in
                if isEnabled {
                    store.selectedFormats.insert(format)
                } else {
                    store.selectedFormats.remove(format)
                }
            }
        )
    }

    private func formatHelp(_ format: ExportFormat) -> String {
        if format.needsWordTimestamps && !modelProvidesWordTimestamps {
            return "The selected model does not produce word-level timings."
        }
        return "Writes a .\(format.fileExtension) file beside the transcript."
    }
}
