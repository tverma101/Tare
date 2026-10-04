import AppKit
import SwiftUI
import TranscriberCore
import UniformTypeIdentifiers

struct ContentView: View {
    @ObservedObject var store: TranscriptionStore
    @State private var detailJobID: TranscriptionJob.ID?

    var body: some View {
        VStack(spacing: 0) {
            NoticeStack(store: store)

            switch store.page {
            case .transcribe:
                HStack(spacing: 0) {
                    ConfigurationPanel(store: store)
                        .frame(width: Metric.configPanelWidth)

                    Divider()

                    WorkspaceView(store: store, detailJobID: $detailJobID)
                        .frame(minWidth: Metric.detailMin)
                }
            case let .settings(tab):
                SettingsView(store: store, tab: tab)
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
        .fileImporter(
            isPresented: $store.isFileImporterPresented,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true,
            onCompletion: store.handleFileImporterResult
        )
        .statusAnnouncements(store)
        .navigationTitle(windowTitle)
        .navigationSubtitle(windowSubtitle)
        .toolbar { toolbar }
    }

    private var openJob: TranscriptionJob? {
        detailJobID.flatMap { id in store.jobs.first { $0.id == id } }
    }

    private var windowTitle: String {
        switch store.page {
        case .settings: return "Settings"
        case .transcribe: return openJob?.displayName ?? "Tare"
        }
    }

    private var windowSubtitle: String {
        guard case .transcribe = store.page, openJob == nil else { return "" }
        let count = store.jobs.count
        guard count > 0 else { return "" }
        return "\(count) file\(count == 1 ? "" : "s")"
            + (store.completedCount > 0 ? " · \(store.completedCount) done" : "")
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if case .settings = store.page {
            ToolbarItem(placement: .navigation) {
                Button {
                    store.page = .transcribe
                } label: {
                    Label("Back to Files", systemImage: "chevron.left")
                }
                .keyboardShortcut(.cancelAction)
                .help("Back to your files (Esc)")
            }
        } else if let job = openJob {
            ToolbarItem(placement: .navigation) {
                Button {
                    detailJobID = nil
                } label: {
                    Label("Files", systemImage: "chevron.left")
                }
                .keyboardShortcut(.cancelAction)
                .help("Back to the file list (Esc)")
            }

            if let text = job.transcript?.fullText, !text.isEmpty {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                    } label: {
                        Label("Copy Transcript", systemImage: "doc.on.doc")
                    }
                    .help("Copy the whole transcript")
                }
            }
        } else {
            ToolbarItemGroup(placement: .primaryAction) {
                if store.jobs.count > 1 {
                    Menu {
                        Picker("Show", selection: $store.queueFilter) {
                            ForEach(TranscriptionStore.QueueFilter.allCases) { filter in
                                Text("\(filter.displayName) (\(store.count(for: filter)))")
                                    .tag(filter)
                            }
                        }
                        .pickerStyle(.inline)
                    } label: {
                        Label("Filter", systemImage: "line.3.horizontal.decrease.circle")
                    }
                    .help("Filter the file list")
                }

                Menu {
                    Button("Remove Selected") {
                        store.removeSelectedJob()
                    }
                    .disabled(store.selectedJobID == nil || store.isScanning || store.isOrganizing)

                    Button("Clear Finished") {
                        store.clearCompleted()
                    }
                    .disabled(store.isRunning || store.completedCount == 0)

                    Divider()

                    Button("Scan Folders for MKV") {
                        Task { await store.scanForMKVs() }
                    }
                    .disabled(!store.canScanForMKVs)

                    Button("Clean Names & Organize…") {
                        store.requestOrganizeConfirmation()
                    }
                    .disabled(!store.canCleanAndOrganizeMKVs)
                } label: {
                    Label("Queue", systemImage: "ellipsis.circle")
                }
                .help("Queue actions")

                Button {
                    store.presentFilePicker()
                } label: {
                    Label("Add Files", systemImage: "plus")
                }
                .help("Add audio or video files (⌘O)")
            }
        }
    }
}

/// Messages and confirmations that need an answer, shown at the top of the
/// window rather than as alerts.
private struct NoticeStack: View {
    @ObservedObject var store: TranscriptionStore

    var body: some View {
        VStack(spacing: Space.close) {
            if let message = store.cloudErrorMessage {
                InlineNotice(kind: .error, title: "Cloud transcription", message: message) {
                    Button("Dismiss") { store.cloudErrorMessage = nil }
                }
            }

            if store.isConfirmingOrganize {
                let names = store.mkvSourceURLs.prefix(6).map(\.lastPathComponent)
                let overflow = store.mkvSourceURLs.count - names.count
                let list = names.joined(separator: ", ") + (overflow > 0 ? " and \(overflow) more" : "")
                InlineNotice(
                    kind: .warning,
                    title: "Rename and move \(store.mkvSourceURLs.count) file\(store.mkvSourceURLs.count == 1 ? "" : "s")?",
                    message: "Tare will rename and move \(list) into \(store.libraryDirectory.lastPathComponent). This changes files on disk."
                ) {
                    Button("Cancel") { store.isConfirmingOrganize = false }
                    Button("Rename and Move") {
                        Task { await store.confirmOrganize() }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(.horizontal, store.cloudErrorMessage != nil || store.isConfirmingOrganize ? Space.page : 0)
        .padding(.top, store.cloudErrorMessage != nil || store.isConfirmingOrganize ? Space.close : 0)
    }
}
