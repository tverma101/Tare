import SwiftUI
import TranscriberCore

struct ModelsView: View {
    @ObservedObject var store: TranscriptionStore
    @State private var isShowingDownloadCatalog = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
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
                        .padding(20)
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
                        DisclosureGroup("Download another model", isExpanded: $isShowingDownloadCatalog) {
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
                        .padding(14)
                        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
                    }
                }
                .padding(24)
            }
        }
        .task {
            if store.modelStatuses.isEmpty {
                await store.refreshModelStatuses()
            }
        }
        .alert(
            "Model setup",
            isPresented: Binding(
                get: { store.modelErrorMessage != nil },
                set: { isPresented in
                    if !isPresented { store.modelErrorMessage = nil }
                }
            )
        ) {
            Button("OK") { store.modelErrorMessage = nil }
        } message: {
            Text(store.modelErrorMessage ?? "Tare could not inspect the local model cache.")
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
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
    }

    private var emptyLocalModels: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("No supported local models found", systemImage: "cube.transparent")
                .font(.headline)
            Text("Tare will use a model as soon as it appears in the local Hugging Face cache. Refresh after installing one, or expand “Download another model” below.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
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
        .foregroundStyle(.orange)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
    }

    private func localModelRow(for preset: WhisperModelPreset) -> some View {
        let status = store.modelStatus(for: preset)
        let isActive = store.isActiveModel(preset)
        let isBusy = store.modelOperationModelID == preset.id

        return HStack(spacing: 12) {
            Image(systemName: isActive ? "checkmark.circle.fill" : "checkmark.circle")
                .foregroundStyle(isActive ? Color.accentColor : Color.green)
                .font(.title3)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(preset.displayName)
                        .font(.headline)
                    if isActive {
                        Text("In use")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tint)
                    }
                }
                Text(preset.detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if let status {
                    Text("Installed · \(status.sizeDescription)")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            }

            Spacer()

            if isBusy {
                ProgressView()
                    .controlSize(.small)
            }

            Button("Remove") {
                Task { await store.removeModel(preset) }
            }
            .disabled(store.modelOperation != nil || isActive)
            .help(isActive ? "Choose another model before removing this one" : "Remove this model from the local Hugging Face cache")
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    private func downloadModelRow(for preset: WhisperModelPreset) -> some View {
        let status = store.modelStatus(for: preset)
        let needsRepair = status?.isAvailable == true && status?.isUsable != true
        let isActive = store.isActiveModel(preset)

        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(preset.displayName)
                    .font(.subheadline.weight(.semibold))
                Text(preset.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if needsRepair {
                    Text(status?.issueMessage ?? "Cached but not usable")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            Spacer()

            if needsRepair {
                Button("Remove") {
                    Task { await store.removeModel(preset) }
                }
                .disabled(store.modelOperation != nil || isActive)
            } else {
                Button("Download") {
                    Task { await store.downloadModel(preset) }
                }
                .disabled(store.modelOperation != nil)
            }
        }
        .padding(.vertical, 4)
    }
}
