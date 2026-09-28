import SwiftUI
import TranscriberCore
import UniformTypeIdentifiers

struct ContentView: View {
    @ObservedObject var store: TranscriptionStore

    var body: some View {
        TabView {
            NavigationSplitView {
                SidebarView(store: store)
                    .navigationSplitViewColumnWidth(min: 260, ideal: 320, max: 420)
            } detail: {
                DetailView(store: store)
            }
            .toolbar {
                ToolbarItemGroup {
                    Button {
                        store.presentFilePicker()
                    } label: {
                        Label("Add", systemImage: "plus")
                    }

                    Button {
                        store.removeSelectedJob()
                    } label: {
                        Label("Remove", systemImage: "minus")
                    }
                    .disabled(store.selectedJobID == nil || store.isScanning || store.isOrganizing)
                    .help(store.selectedJobID == nil
                        ? "Select a file in the queue first"
                        : "Remove from the queue. Output files already written are kept.")
                    .keyboardShortcut(.delete, modifiers: [.command])
                }

                ToolbarItemGroup {
                    Button {
                        if store.isRunning || store.isPreparingModel {
                            store.cancelBatch()
                        } else {
                            store.startBatch()
                        }
                    } label: {
                        if store.isPreparingModel {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Label(
                            store.isRunning || store.isPreparingModel ? "Cancel" : "Start",
                            systemImage: store.isRunning || store.isPreparingModel ? "stop.fill" : "play.fill"
                        )
                    }
                    .disabled(!store.isRunning && !store.isPreparingModel && !store.canStart)
                    .help(store.isPreparingModel
                        ? "Cancel the model check"
                        : store.isRunning ? "Stop the batch" : "Start the queued files")
                }

                ToolbarItem(placement: .status) {
                    Text(store.statusMessage)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .onDrop(
                of: [UTType.fileURL.identifier],
                isTargeted: $store.dropIsTargeted,
                perform: store.addDroppedProviders
            )
            .onAppear {
                store.startLaunchWorkIfNeeded()
            }
            .tabItem {
                Label("Transcribe", systemImage: "waveform")
            }

            ModelsView(store: store)
                .tabItem {
                    Label("Models", systemImage: "arrow.down.circle")
                }

            CloudTranscriptionView(store: store)
            .tabItem {
                Label("Cloud", systemImage: "cloud")
            }
        }
        .fileImporter(
            isPresented: $store.isFileImporterPresented,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true,
            onCompletion: store.handleFileImporterResult
        )
        .alert(
            "Cloud transcription",
            isPresented: Binding(
                get: { store.cloudErrorMessage != nil },
                set: { isPresented in
                    if !isPresented { store.cloudErrorMessage = nil }
                }
            )
        ) {
            Button("OK") { store.cloudErrorMessage = nil }
        } message: {
            Text(store.cloudErrorMessage ?? "Tare could not update the Gemini configuration.")
        }
    }
}
