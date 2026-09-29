import SwiftUI
import TranscriberCore

struct SettingsView: View {
    @ObservedObject var store: TranscriptionStore
    @State private var freeLLMAPIKey = ""
    @State private var pendingLibraryAction: LibraryAction?

    private enum LibraryAction: String, Identifiable {
        case scan

        var id: String { rawValue }
    }

    var body: some View {
        Form {
            Section("Recognition") {
                RecognitionSettingsView(store: store)
            }

            Section("Output") {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Output location", systemImage: "folder")
                        .font(.subheadline.weight(.semibold))

                    Text(store.currentOutputDirectory.path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(store.currentOutputDirectory.path)

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

                if let outputError = store.outputDirectoryError {
                    Label {
                        Text(outputError)
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle")
                    }
                    .foregroundStyle(Palette.danger)
                }

                Toggle("Create Batch Folder", isOn: $store.createBatchFolder)

                Text("Transcript file formats are chosen in the Transcribe tab's Export panel.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Embed subtitles into video sources", isOn: $store.attachCaptionedVideoToSource)

                Text("Replaces the source video in place and keeps the original in an Original Video Backups folder beside it. MP4, MOV and M4V inputs produce a .captioned.mkv instead of editing the original.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Media library") {
                LabeledContent("Search folders") {
                    Text(store.scanRoots.isEmpty
                        ? "None"
                        : "\(store.scanRoots.count) folder\(store.scanRoots.count == 1 ? "" : "s")")
                        .foregroundStyle(.secondary)
                }

                ForEach(store.scanRoots, id: \.standardizedFileURL) { root in
                    HStack(spacing: 8) {
                        Text(root.path)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(root.path)
                            .font(.caption)

                        Spacer()

                        Button("Remove", role: .destructive) {
                            store.removeScanRoot(root)
                        }
                        .controlSize(.small)
                    }
                }

                HStack {
                    Button {
                        store.presentScanRootPicker()
                    } label: {
                        Label("Add Folder...", systemImage: "plus")
                    }

                    Spacer()
                }

                LabeledContent("Library folder") {
                    Text(store.libraryDirectory.path)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(store.libraryDirectory.path)
                        .font(.caption)
                }

                HStack {
                    Button {
                        store.presentLibraryDirectoryPicker()
                    } label: {
                        Label("Choose Library Folder...", systemImage: "folder")
                    }

                    Button("Scan for MKV") {
                        pendingLibraryAction = .scan
                    }
                    .disabled(!store.canScanForMKVs)

                    Button("Clean Names & Organize") {
                        store.requestOrganizeConfirmation()
                    }
                    .disabled(!store.canCleanAndOrganizeMKVs)

                    Spacer()
                }

                Text("Clean Names & Organize renames and moves files on disk. Tare lists every file first and asks before changing anything.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
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
        .task { await store.refreshFreeLLMAPIStatus() }
        .confirmationDialog(
            "Rename and move files?",
            isPresented: Binding(
                get: { pendingLibraryAction != nil },
                set: { if !$0 { pendingLibraryAction = nil } }
            ),
            presenting: pendingLibraryAction
        ) { action in
            switch action {
            case .scan:
                Button("Scan Folders") {
                    pendingLibraryAction = nil
                    Task { await store.scanForMKVs() }
                }
            }
            Button("Cancel", role: .cancel) { pendingLibraryAction = nil }
        } message: { _ in
            Text("Tare looks for MKV files in your \(store.scanRoots.count) search folder\(store.scanRoots.count == 1 ? "" : "s") and adds what it finds to the queue. Nothing is renamed or moved.")
        }
    }
}
