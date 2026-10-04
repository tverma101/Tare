import SwiftUI
import TranscriberCore

/// Settings, as a page of the one window: a list of sections on the left, the
/// selected section on the right, and a way back to the files.
struct SettingsView: View {
    @ObservedObject var store: TranscriptionStore
    let tab: SettingsTab

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Space.group) {
                Button {
                    store.page = .transcribe
                } label: {
                    Label("Back to Files", systemImage: "chevron.left")
                }
                .keyboardShortcut(.cancelAction)
                .help("Return to your files (Esc)")

                Spacer()

                Text("Settings")
                    .font(Typography.pageTitle)

                Spacer()

                // Balances the Back button so the title stays centred.
                Color.clear.frame(width: 110, height: 1)
            }
            .padding(.horizontal, Space.page)
            .padding(.vertical, Space.group)

            Divider()

            HStack(spacing: 0) {
                List(
                    SettingsTab.allCases,
                    selection: Binding(
                        get: { Optional(tab) },
                        set: { if let new = $0 { store.page = .settings(new) } }
                    )
                ) { item in
                    Label(item.title, systemImage: item.symbol)
                        .tag(item)
                }
                .listStyle(.sidebar)
                .frame(width: 180)

                Divider()

                Group {
                    switch tab {
                    case .general: GeneralSettingsPane(store: store)
                    case .models: ModelsView(store: store)
                    case .cloud: CloudTranscriptionView(store: store)
                    case .library: LibrarySettingsPane(store: store)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

private struct GeneralSettingsPane: View {
    @ObservedObject var store: TranscriptionStore
    @State private var freeLLMAPIKey = ""

    var body: some View {
        Form {
            Section("After a batch") {
                Toggle("Show a transcript preview for each finished file", isOn: $store.showTranscriptPreview)

                Text("On: finished files get a View button that opens the transcript inside Tare. Off: Tare just processes everything and then tells you which folder it saved to.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Default model and language") {
                RecognitionSettingsView(store: store)

                Text("These are the same choices as Model and Language in the main window. This is also where a custom Hugging Face model ID can be entered.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
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

                Text("Choose which transcript files to write under Output files in the main window.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Embed subtitles into video sources", isOn: $store.attachCaptionedVideoToSource)

                Text("Replaces the source video in place and keeps the original in an Original Video Backups folder beside it. MP4, MOV and M4V inputs produce a .captioned.mkv instead of editing the original.")
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
        .formStyle(.grouped)
        .task { await store.refreshFreeLLMAPIStatus() }
    }
}

private struct LibrarySettingsPane: View {
    @ObservedObject var store: TranscriptionStore

    var body: some View {
        Form {
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
                        Task { await store.scanForMKVs() }
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

        }
        .formStyle(.grouped)
    }
}
