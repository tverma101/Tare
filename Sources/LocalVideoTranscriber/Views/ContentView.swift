import SwiftUI
import TranscriberCore
import UniformTypeIdentifiers

struct ContentView: View {
    @ObservedObject var store: TranscriptionStore

    var body: some View {
        TabView {
            NavigationSplitView {
                QueueTableView(store: store)
                    .navigationSplitViewColumnWidth(
                        min: Metric.sidebarMin,
                        ideal: Metric.sidebarIdeal,
                        max: Metric.sidebarMax
                    )
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
                    .help("Add audio or video to the queue")

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
        .statusAnnouncements(store)
    }
}
