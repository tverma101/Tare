import SwiftUI
import TranscriberCore

struct ModelsView: View {
    @ObservedObject var store: TranscriptionStore
    @State private var isShowingDownloadCatalog = false
    @State private var modelPendingRemoval: WhisperModelPreset?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let message = store.modelErrorMessage {
                        InlineNotice(kind: .error, title: "Model setup", message: message) {
                            Button("Dismiss") { store.modelErrorMessage = nil }
                        }
                    }

                    if let preset = modelPendingRemoval {
                        let size = store.modelStatus(for: preset)?.sizeDescription ?? "several GB"
                        InlineNotice(
                            kind: .warning,
                            title: "Delete \(preset.displayName)?",
                            message: "This deletes \(size) of cached files from your Hugging Face cache. It cannot be undone, and you will need to download the model again."
                        ) {
                            Button("Cancel") { modelPendingRemoval = nil }
                            Button("Delete", role: .destructive) {
                                modelPendingRemoval = nil
                                Task { await store.removeModel(preset) }
                            }
                        }
                    }

                    if let selectedPreset = WhisperModelPreset.preset(for: store.effectiveSelectedModelIdentifier),
                       selectedPreset.isLocal,
                       store.modelStatus(for: selectedPreset)?.isUsable != true,
                       !store.isRefreshingModels {
                        unavailableSelectionNotice(selectedPreset, status: store.modelStatus(for: selectedPreset))
                    }

                    if store.isRefreshingModels && store.modelStatuses.isEmpty {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("Looking for supported models already on this Mac…")
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(Space.page)
                    } else if store.installedModelPresets.isEmpty {
                        emptyLocalModels
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Available on this Mac")
                                .font(.headline)

                            ForEach(store.installedModelPresets) { preset in
                                localModelRow(for: preset)
                            }
                        }
                    }

                    if !store.downloadableModelPresets.isEmpty {
                        DisclosureGroup("Download another model (\(store.downloadableModelPresets.count) available)", isExpanded: $isShowingDownloadCatalog) {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Downloads go to your existing Hugging Face cache. Tare never puts model files in the app or DMG.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)

                                ForEach(store.downloadableModelPresets) { preset in
                                    downloadModelRow(for: preset)
                                }
                            }
                            .padding(.top, 8)
                        }
                        .padding(Space.group)
                        .background(Palette.contentBackground, in: RoundedRectangle(cornerRadius: Radius.card))
                    }
                }
                .padding(Space.page)
                .frame(maxWidth: Metric.contentMaxWidth, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .task {
            if store.modelStatuses.isEmpty {
                await store.refreshModelStatuses()
            }
            // With nothing installed the download list is the whole point of
            // this pane, so it should not start collapsed.
            if store.installedModelPresets.isEmpty {
                isShowingDownloadCatalog = true
            }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Local models")
                    .font(.title2.weight(.semibold))
                Text("Tare uses supported models already in your local Hugging Face cache.")
                    .foregroundStyle(.secondary)
                Text("Model files are never bundled with the app or DMG.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            if let operation = store.modelOperation {
                ProgressView()
                    .controlSize(.small)
                Text(operation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button {
                Task { await store.refreshModelStatuses() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .disabled(store.modelOperation != nil || store.isRefreshingModels)
        }
        .padding(.horizontal, Space.page)
        .padding(.vertical, Space.group)
        .frame(maxWidth: Metric.contentMaxWidth, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var emptyLocalModels: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("No supported local models found", systemImage: "cube.transparent")
                .font(.headline)
            Text("Tare will use a model as soon as it appears in the local Hugging Face cache. Refresh after installing one, or expand “Download another model” below.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Space.group)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.contentBackground, in: RoundedRectangle(cornerRadius: Radius.card))
    }

    private func unavailableSelectionNotice(_ preset: WhisperModelPreset, status: ModelStatus?) -> some View {
        let detail = status?.isAvailable == true
            ? (status?.issueMessage ?? "The cached snapshot is not usable by Tare.")
            : "This model is not present in the local cache."
        return Label {
            Text("\(preset.displayName) is selected but cannot run. \(detail) Choose an available model below or use the collapsed section.")
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "exclamationmark.triangle")
        }
        .foregroundStyle(Palette.warning)
        .padding(Space.group)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.warningFill, in: RoundedRectangle(cornerRadius: Radius.inline))
    }

    private func localModelRow(for preset: WhisperModelPreset) -> some View {
        let status = store.modelStatus(for: preset)
        let isActive = store.isActiveModel(preset)
        let isRequired = store.isRequiredModel(preset)
        let isBusy = store.modelOperationModelID == preset.id

        return HStack(spacing: 12) {
            Image(systemName: isActive ? "checkmark.circle.fill" : "checkmark.circle")
                .foregroundStyle(isActive ? Palette.accent : Palette.success)
                .font(.title3)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(preset.displayName)
                        .font(.headline)
                    if isActive {
                        Text("In use")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tint)
                    } else if isRequired {
                        Text("Needed for this language")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Text(preset.detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(factSummary(for: preset, includesDownloadSize: status == nil))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                if let note = preset.memoryRequirementNote {
                    Label(note, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(Palette.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let status {
                    Text("Installed · \(status.sizeDescription)")
                        .font(.caption)
                        .foregroundStyle(Palette.success)
                }
            }

            Spacer()

            if isBusy {
                ProgressView()
                    .controlSize(.small)
            }

            Button("Use") {
                store.selectModel(preset)
            }
            .disabled(store.modelOperation != nil || isActive)
            .help(isActive ? "\(preset.displayName) is the selected model" : "Select \(preset.displayName) for the next batch")

            Button("Remove", role: .destructive) {
                modelPendingRemoval = preset
            }
            .disabled(store.modelOperation != nil || store.isRefreshingModels || isRequired)
            .help(removalHelp(for: preset, isRequired: isRequired))
        }
        .padding(Space.group)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    private func removalHelp(for preset: WhisperModelPreset, isRequired: Bool) -> String {
        if isRequired {
            return preset.id == store.modelIdentifier
                ? "Choose another model before removing this one"
                : "The current language setting needs this model. Change the model or language before removing it."
        }
        return "Delete the cached files for \(preset.displayName). You will need to download it again."
    }

    /// The decision facts a row does not otherwise show: coverage, word
    /// timestamps, and the download size when the cache size is not already on
    /// the row.
    private func factSummary(for preset: WhisperModelPreset, includesDownloadSize: Bool) -> String {
        var facts = [
            preset.isMultilingual ? "Multilingual" : "English only",
            preset.supportsWordTimestamps ? "Word timestamps" : "No word timestamps"
        ]
        if includesDownloadSize, let size = preset.downloadSizeDescription {
            facts.append(size)
        }
        return facts.joined(separator: " · ")
    }

    private func downloadModelRow(for preset: WhisperModelPreset) -> some View {
        let status = store.modelStatus(for: preset)
        let needsRepair = status?.isAvailable == true && status?.isUsable != true
        let isActive = store.isActiveModel(preset)
        let isRequired = store.isRequiredModel(preset)

        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(preset.displayName)
                        .font(.subheadline.weight(.semibold))
                    if isActive {
                        Text("In use")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tint)
                    }
                }
                Text(preset.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(factSummary(for: preset, includesDownloadSize: true))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                if let note = preset.memoryRequirementNote {
                    Label(note, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(Palette.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if needsRepair {
                    Text(status?.issueMessage ?? "Cached but not usable")
                        .font(.caption)
                        .foregroundStyle(Palette.warning)
                }
            }

            Spacer()

            if needsRepair {
                Button("Re-download") {
                    Task { await store.downloadModel(preset) }
                }
                .disabled(store.modelOperation != nil || store.isRefreshingModels)
                .help("Download the missing files again")

                Button("Remove", role: .destructive) {
                    modelPendingRemoval = preset
                }
                .disabled(store.modelOperation != nil || store.isRefreshingModels || isRequired)
                .help("Delete the incomplete cache entry so Tare can download it again")
            } else {
                Button("Download") {
                    Task { await store.downloadModel(preset) }
                }
                .disabled(store.modelOperation != nil || store.isRefreshingModels)
            }
        }
        .padding(.vertical, 4)
    }
}
