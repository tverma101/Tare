import SwiftUI
import TranscriberCore

struct RecognitionSettingsView: View {
    @ObservedObject var store: TranscriptionStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Picker("Model", selection: $store.modelIdentifier) {
                    if let selectedPreset = WhisperModelPreset.preset(for: store.modelIdentifier),
                       selectedPreset.isCloud {
                        Text("\(selectedPreset.displayName) · Configure in Cloud")
                            .tag(selectedPreset.id)
                    } else if let selectedPreset = WhisperModelPreset.preset(for: store.modelIdentifier),
                              !store.installedModelPresets.contains(selectedPreset) {
                        Text("\(selectedPreset.displayName) · Unavailable locally")
                            .tag(selectedPreset.id)
                    }

                    ForEach(store.installedModelPresets) { preset in
                        let availability = store.modelStatuses[preset.id].map {
                            $0.isAvailable ? " · Installed" : ""
                        } ?? ""
                        Text("\(preset.displayName) - \(preset.detail)\(availability)")
                            .tag(preset.id)
                    }
                }
                .frame(width: 330)

                TextField("Model ID", text: $store.modelIdentifier)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 260)
            }

            if let modelAvailabilityText {
                Label(
                    modelAvailabilityText,
                    systemImage: store.effectiveSelectedModelStatus?.isUsable == true
                        ? "checkmark.circle"
                        : "arrow.down.circle"
                )
                .font(.caption)
                .foregroundStyle(store.effectiveSelectedModelStatus?.isUsable == true ? .green : .orange)
            }

            if store.installedModelPresets.isEmpty && !store.isRefreshingModels && !store.isUsingGeminiTranscription {
                Label("No supported local models found. Open Models to refresh or download one.", systemImage: "arrow.down.circle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Picker("Language", selection: $store.localeIdentifier) {
                    ForEach(WhisperLanguagePreset.all) { preset in
                        Text(preset.displayName)
                            .tag(preset.id)
                    }
                }
                .frame(width: 220)

                TextField("Language Code", text: $store.localeIdentifier)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 150)
            }

            if let warningText {
                Label(warningText, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            if WhisperModelPreset.isMossDiarize(store.modelIdentifier) {
                Label(
                    "MOSS runs one long-form pass and adds anonymous speaker labels. Word-level timings are not available for this model.",
                    systemImage: "person.2.wave.2"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            if WhisperModelPreset.isParakeetV3(store.modelIdentifier) {
                Label(
                    "Parakeet v3 runs through MLX with automatic language detection and word-level timestamps.",
                    systemImage: "waveform"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            if WhisperModelPreset.isGeminiTranscribe(store.modelIdentifier) {
                Label(
                    "Cloud transcription sends audio to Google Gemini. Configure API keys and long-recording options in the Cloud tab.",
                    systemImage: "cloud"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    private var warningText: String? {
        guard let preset = WhisperModelPreset.preset(for: store.modelIdentifier),
              preset.isLocal,
              !preset.isMultilingual else {
            return nil
        }

        guard let languageCode = WhisperTranscriptionService.languageCode(from: store.localeIdentifier) else {
            return "English-only model limits Auto Detect to English speech"
        }

        return languageCode == "en" ? nil : "Selected model is English-only"
    }

    private var modelAvailabilityText: String? {
        guard let preset = WhisperModelPreset.preset(for: store.effectiveSelectedModelIdentifier) else {
            return nil
        }

        if preset.isCloud {
            let keyCount = store.geminiUsableAPIKeyCount
            guard keyCount > 0 else {
                return "Cloud model · configure a usable Gemini API key in Cloud"
            }
            let suffix = keyCount == 1 ? "key" : "keys"
            return "Cloud model · \(keyCount) usable API \(suffix)"
        }

        guard let status = store.effectiveSelectedModelStatus else {
            return "Checking model availability…"
        }

        if status.isUsable {
            return "Installed and ready · \(status.sizeDescription)"
        }

        if status.isAvailable {
            return status.issueMessage ?? "Cached but not usable — open Models to repair or choose another model"
        }

        return "Not available locally — open Models to choose an installed model or download this one"
    }
}
