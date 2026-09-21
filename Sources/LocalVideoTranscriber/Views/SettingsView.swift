import SwiftUI
import TranscriberCore

struct SettingsView: View {
    @ObservedObject var store: TranscriptionStore
    @State private var freeLLMAPIKey = ""

    var body: some View {
        Form {
            Section("Recognition") {
                RecognitionSettingsView(store: store)
            }

            Section("Output") {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Output location", systemImage: "folder")
                        .font(.subheadline.weight(.semibold))

                    Text(store.outputDirectory.path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)

                    HStack {
                        Button {
                            store.revealOutputDirectory()
                        } label: {
                            Label("Show in Finder", systemImage: "folder")
                        }

                        Button("Choose...") {
                            store.presentOutputDirectoryPicker()
                        }
                    }
                }

                Toggle("Create Batch Folder", isOn: $store.createBatchFolder)

                Toggle("Save Plain Transcript", isOn: Binding(
                    get: { store.savesTextTranscript },
                    set: { store.setTextTranscriptEnabled($0) }
                ))

                Toggle("Save Timestamped Transcript", isOn: Binding(
                    get: { store.savesTimestampedTranscript },
                    set: { store.setTimestampedTranscriptEnabled($0) }
                ))
            }

            Section("Transcript names") {
                Toggle("Use smart transcript names", isOn: $store.smartTranscriptNamingEnabled)

                Text("Tare asks FreeLLMAPI for a compact subject and folder name using the transcript excerpt. It only makes a short request while an export is running, never starts a background server, and falls back to the source filename when unavailable.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                SecureField("FreeLLMAPI unified key", text: $freeLLMAPIKey)

                HStack {
                    Button("Save Key") {
                        store.saveFreeLLMAPIKey(freeLLMAPIKey)
                        freeLLMAPIKey = ""
                    }
                    .disabled(freeLLMAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    if store.freeLLMAPIKeyConfigured {
                        Button("Remove Key", role: .destructive) {
                            store.removeFreeLLMAPIKey()
                        }
                    }

                    Spacer()

                    Button("Open FreeLLMAPI") {
                        store.openFreeLLMAPI()
                    }
                }

                Text(store.freeLLMAPIStatusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

        }
        .padding()
    }
}
