import SwiftUI
import TranscriberCore

/// The Transcribe tab's sidebar.
///
/// This is a `List` on purpose. A SwiftUI `Table` is a full-width data surface
/// and renders as an empty, unusable column when placed in a split-view
/// sidebar, so the queue table lives in the detail pane instead.
struct QueueSidebarView: View {
    @ObservedObject var store: TranscriptionStore

    var body: some View {
        List {
            Section {
                Picker("Filter", selection: $store.queueFilter) {
                    ForEach(TranscriptionStore.QueueFilter.allCases) { filter in
                        Text("\(filter.displayName) \(store.count(for: filter))")
                            .tag(filter)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
                .accessibilityLabel("Filter the job queue")
            } header: {
                Text("Queue")
            }

            Section("This batch") {
                LabeledContent("Files", value: "\(store.jobs.count)")
                LabeledContent("Completed", value: "\(store.count(for: .completed))")
                LabeledContent("Failed", value: "\(store.count(for: .failed))")

                Button {
                    store.clearCompleted()
                } label: {
                    Label("Clear Completed", systemImage: "checkmark.circle")
                }
                .disabled(store.isRunning || store.count(for: .completed) == 0)
            }

            Section("Output") {
                Button {
                    store.revealOutputDirectory()
                } label: {
                    Label("Show in Finder", systemImage: "folder")
                }

                Button {
                    store.presentOutputDirectoryPicker()
                } label: {
                    Label("Choose Folder…", systemImage: "folder.badge.gearshape")
                }
            }

            Section("Library") {
                Button {
                    Task { await store.scanForMKVs() }
                } label: {
                    Label("Scan for MKV", systemImage: "magnifyingglass")
                }
                .disabled(!store.canScanForMKVs)

                Button {
                    store.requestOrganizeConfirmation()
                } label: {
                    Label("Clean & Organize", systemImage: "folder.badge.gearshape")
                }
                .disabled(!store.canCleanAndOrganizeMKVs)
            }
        }
        .listStyle(.sidebar)
    }
}
