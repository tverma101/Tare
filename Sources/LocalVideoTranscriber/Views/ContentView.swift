import SwiftUI
import TranscriberCore
import UniformTypeIdentifiers

struct ContentView: View {
    @ObservedObject var store: TranscriptionStore

    var body: some View {
        TabView {
            HSplitView {
                QueueSidebarView(store: store)
                    .frame(
                        minWidth: Metric.sidebarMin,
                        idealWidth: Metric.sidebarIdeal,
                        maxWidth: Metric.sidebarMax
                    )

                QueueWorkspaceView(store: store)
                    .frame(minWidth: Metric.detailMin)
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
        .confirmationDialog(
            "Rename and move files?",
            isPresented: $store.isConfirmingOrganize
        ) {
            Button(
                "Rename and Move \(store.mkvSourceURLs.count) File\(store.mkvSourceURLs.count == 1 ? "" : "s")",
                role: .destructive
            ) {
                Task { await store.confirmOrganize() }
            }
            Button("Cancel", role: .cancel) {
                store.isConfirmingOrganize = false
            }
        } message: {
            let names = store.mkvSourceURLs.prefix(8).map(\.lastPathComponent)
            let overflow = store.mkvSourceURLs.count - names.count
            let list = names.joined(separator: "\n") + (overflow > 0 ? "\n…and \(overflow) more" : "")
            return Text("Tare will rename and move these files into \(store.libraryDirectory.lastPathComponent):\n\n\(list)\n\nThis changes files on disk.")
        }
    }
}
