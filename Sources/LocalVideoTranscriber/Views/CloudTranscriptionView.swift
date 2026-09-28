import SwiftUI
import TranscriberCore

struct CloudTranscriptionView: View {
    @ObservedObject var store: TranscriptionStore
    @State private var keyLabel = "Google Gemini key"
    @State private var keyInput = ""
    /// The saved-key count when the last add was requested. `addGeminiAPIKey`
    /// only enqueues work, so the field is cleared from the count observer and
    /// only when the add actually landed.
    @State private var keyCountAtPendingAdd: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    modelCard
                    apiKeysCard
                    optionsCard
                    longRecordingCard
                    freeTierCard
                    privacyCard
                }
                .padding(24)
            }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Transcribe via Cloud")
                    .font(.title2.weight(.semibold))
                Text("Use Google Gemini 3.5 Transcribe when you want cloud transcription for a recording.")
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if store.isUsingGeminiTranscription {
                Label("Selected", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
    }

    private var modelCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Label("Google Gemini", systemImage: "cloud")
                    .font(.headline)
                Spacer()
                Text(WhisperModelPreset.gemini35Transcribe.id)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            Text("Gemini 3.5 Transcribe provides automatic language detection and cloud transcription. It is separate from the local model cache and never appears as a downloadable local model.")
                .fixedSize(horizontal: false, vertical: true)
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                Label("Up to 60 minutes per plain request", systemImage: "clock")
                Label("Up to 30 minutes with annotations", systemImage: "text.word.spacing")
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            Button {
                store.useGeminiTranscription()
            } label: {
                Label(
                    store.isUsingGeminiTranscription ? "Gemini selected" : "Use Gemini for transcription",
                    systemImage: store.isUsingGeminiTranscription ? "checkmark" : "cloud"
                )
            }
            .disabled(store.isUsingGeminiTranscription)
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
    }

    private var apiKeysCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Gemini API keys", systemImage: "key")
                    .font(.headline)
                Spacer()
                Text("\(store.geminiAPIKeyCount) saved · \(store.geminiUsableAPIKeyCount) enabled")
                    .font(.caption)
                    .foregroundStyle(store.geminiUsableAPIKeyCount == 0 ? .orange : .secondary)
            }

            Text("Keys are stored in the macOS Keychain. Tare keeps only a label and the last four characters in its settings. Cloud options save automatically. Multiple keys provide ordered failover when a request is rejected or temporarily limited; they do not multiply Google’s project quota.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ViewThatFits(in: .horizontal) {
                addKeyRow(compact: false)
                addKeyRow(compact: true)
            }

            HStack(spacing: 10) {
                Button {
                    store.verifyGeminiAPIKeys()
                } label: {
                    if store.isVerifyingGeminiKeys {
                        Label("Verifying…", systemImage: "arrow.triangle.2.circlepath")
                    } else {
                        Label("Verify model access", systemImage: "checkmark.shield")
                    }
                }
                .disabled(store.geminiUsableAPIKeyCount == 0 || store.isVerifyingGeminiKeys)

                if !store.geminiVerifiedCredentialIDs.isEmpty {
                    Label(
                        "\(store.geminiVerifiedCredentialIDs.count) key(s) verified for \(WhisperModelPreset.gemini35Transcribe.id)",
                        systemImage: "checkmark.circle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.green)
                }
            }

            if let verification = store.geminiVerificationMessage {
                Label(verification, systemImage: store.cloudErrorMessage == nil ? "checkmark.seal" : "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(store.cloudErrorMessage == nil ? Color.secondary : Color.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let cloudError = store.cloudErrorMessage, store.geminiVerificationMessage != cloudError {
                Label(cloudError, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if store.geminiAPIKeyRecords.isEmpty {
                Label("Add an enabled key to make cloud transcription ready.", systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(store.geminiAPIKeyRecords.enumerated()), id: \.element.id) { index, record in
                        keyRow(record, index: index)
                    }
                }
            }
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .onChange(of: store.geminiAPIKeyRecords.count) { _, newCount in
            guard let pendingCount = keyCountAtPendingAdd, newCount > pendingCount else { return }
            keyCountAtPendingAdd = nil
            keyInput = ""
        }
    }

    /// Both branches bind the same `@State`, so a narrow window only changes the
    /// layout and never discards what was typed.
    @ViewBuilder
    private func addKeyRow(compact: Bool) -> some View {
        if compact {
            VStack(alignment: .leading, spacing: 8) {
                TextField("Label", text: $keyLabel)
                SecureField("Paste Gemini API key", text: $keyInput)
                Button("Add key") {
                    addKey()
                }
                .disabled(trimmedKeyInput.isEmpty)
            }
        } else {
            HStack(spacing: 8) {
                TextField("Label", text: $keyLabel)
                    .frame(width: 180)
                SecureField("Paste Gemini API key", text: $keyInput)
                    .frame(minWidth: 160)
                Button("Add key") {
                    addKey()
                }
                .disabled(trimmedKeyInput.isEmpty)
            }
        }
    }

    private var trimmedKeyInput: String {
        keyInput.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func keyRow(_ record: GeminiAPIKeyRecord, index: Int) -> some View {
        HStack(spacing: 10) {
            Toggle(
                "",
                isOn: Binding(
                    get: { record.isEnabled },
                    set: { store.setGeminiAPIKeyEnabled($0, record: record) }
                )
            )
            .labelsHidden()
            .help(record.isEnabled ? "Disable this key" : "Enable this key")

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(record.label)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if store.geminiVerifiedCredentialIDs.contains(record.id) {
                        Image(systemName: "checkmark.seal.fill")
                            .foregroundStyle(.green)
                            .help("Verified for gemini-3.5-transcribe")
                    }
                }
                Text("••••\(record.lastFour)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                if let lastUsedAt = record.lastUsedAt {
                    HStack(spacing: 3) {
                        Text("Last used")
                        Text(lastUsedAt, style: .relative)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help("Last used \(lastUsedAt.formatted(date: .abbreviated, time: .shortened))")
                }
            }

            Spacer()

            Button {
                Task {
                    await store.verifyGeminiAPIKey(record)
                }
            } label: {
                Image(systemName: "checkmark.shield")
            }
            .buttonStyle(.borderless)
            .disabled(!record.isEnabled || store.isVerifyingGeminiKeys)
            .help("Verify this key can use gemini-3.5-transcribe")

            Button {
                store.moveGeminiAPIKeys(fromOffsets: IndexSet(integer: index), toOffset: index - 1)
            } label: {
                Image(systemName: "chevron.up")
            }
            .buttonStyle(.borderless)
            .disabled(index == 0)
            .help("Try this key earlier")

            Button {
                store.moveGeminiAPIKeys(fromOffsets: IndexSet(integer: index), toOffset: index + 2)
            } label: {
                Image(systemName: "chevron.down")
            }
            .buttonStyle(.borderless)
            .disabled(index == store.geminiAPIKeyRecords.count - 1)
            .help("Try this key later")

            Button {
                store.removeGeminiAPIKey(record)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.red)
            .help("Remove this key from Tare")
        }
        .padding(.vertical, 4)
    }

    private var optionsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Transcription options", systemImage: "slider.horizontal.3")
                .font(.headline)

            Picker("Mode", selection: Binding(
                get: { store.geminiMode },
                set: { store.setGeminiMode($0) }
            )) {
                ForEach(GeminiTranscriptionMode.allCases, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .frame(width: 300)

            Text(store.geminiMode == .smart
                 ? "Smart mode is optional and optimizes the transcript for reading. It does not request word timestamps or speaker labels."
                 : "Verbatim is Google’s documented default. It preserves the spoken content and enables optional word timestamps or speaker labels.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Toggle("Word timestamps", isOn: $store.geminiWordTimestamps)
                .disabled(store.geminiMode == .smart)
            Toggle("Speaker labels (diarization)", isOn: $store.geminiSpeakerDiarization)
                .disabled(store.geminiMode == .smart)

            Text("Google notes that word timestamps can reduce overall transcription accuracy. Speaker attribution for more than two speakers is experimental. Verbatim is Google’s documented default; choose Smart when readability is more important than preserving every spoken detail.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 6) {
                Text("Custom vocabulary")
                    .font(.subheadline.weight(.semibold))
                Text("Optional terms separated by commas, semicolons, or new lines. Maximum 1,000 unique terms (Google recommends keeping the list to about 100). Google does not allow this with timestamps or speaker labels.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextEditor(text: $store.geminiCustomVocabularyText)
                    .font(.body)
                    .frame(minHeight: 72, maxHeight: 110)
                    .overlay {
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(.quaternary)
                    }
            }

            if let validationMessage = store.geminiOptionsValidationMessage {
                Label(validationMessage, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
    }

    private var longRecordingCard: some View {
        let options = store.geminiTranscriptionOptions
        let minutes = options.safeChunkSeconds / 60
        let examplePlan = GeminiAudioChunkPlanner.plan(
            duration: 2.5 * 60 * 60,
            options: options
        )

        return VStack(alignment: .leading, spacing: 8) {
            Label("Long recordings", systemImage: "scissors")
                .font(.headline)

            Text("Tare measures every recording before upload. Files longer than the safe request size are split automatically into roughly equal chunks, preferring detected silence boundaries. It transcribes every chunk sequentially, removes only accidental boundary overlap, restores timestamps, and joins the final transcript in order.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Label(
                options.usesAnnotatedOutput
                    ? "Current safe chunk size: \(minutes) minutes because timestamps or speaker labels are enabled."
                    : "Current safe chunk size: \(minutes) minutes for an unannotated request.",
                systemImage: "checkmark.shield"
            )
            .font(.caption)
            .foregroundStyle(.green)

            Label(
                "Example 2h 30m lecture with current options: \(examplePlan.summaryDescription).",
                systemImage: "chart.bar.doc.horizontal"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            Text("No quality downgrade or partial export is used for multi-hour lectures. If duration cannot be measured, Tare stops before uploading rather than guessing a request size; if one chunk fails, it stops without exporting an incomplete transcript so Retry is safe.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
    }

    private var freeTierCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Free-tier / quota realities", systemImage: "exclamationmark.bubble")
                .font(.headline)

            Text("Google free-tier requests-per-day and tokens-per-minute are enforced on the Google Cloud project that owns the API key. Saving multiple keys from the same project does not multiply quota. A 2.5-hour lecture uses multiple sequential requests and a large estimated audio-token budget, so free-tier jobs can still fail with HTTP 429 after planning succeeds.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text("Before Start, Tare verifies that an enabled key can see \(WhisperModelPreset.gemini35Transcribe.id), measures duration, and shows the chunk/token plan in progress. Token estimates use Google’s Gemini 3.5 Transcribe pricing footnote (\(GeminiTranscriptionLimits.audioTokensPerSecond) audio tokens/sec).")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
    }

    private var privacyCard: some View {
        Label {
            Text("Cloud mode uploads audio to Google. Local models keep processing on this Mac. Choose the Transcribe tab to return to local transcription.")
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "lock.shield")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 4)
    }

    private func addKey() {
        let pendingCount = store.geminiAPIKeyRecords.count
        guard !trimmedKeyInput.isEmpty else { return }
        // Saving is asynchronous, so the field is cleared by the count observer
        // once the key is really stored. A rejected key leaves it in place with
        // the store's error so the paste is not silently lost.
        keyCountAtPendingAdd = pendingCount
        store.addGeminiAPIKey(label: keyLabel, apiKey: keyInput)
    }
}
