import SwiftUI
import TranscriberCore

struct SettingsView: View {
    @ObservedObject var store: TranscriptionStore

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

        }
        .padding()
    }
}
