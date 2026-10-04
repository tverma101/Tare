import AppKit
import SwiftUI
import TranscriberCore

/// The right pane: the files, what is happening to each, and the result.
struct WorkspaceView: View {
    @ObservedObject var store: TranscriptionStore
    @Binding var detailJobID: TranscriptionJob.ID?

    var body: some View {
        if let id = detailJobID {
            TranscriptPage(store: store, jobID: id) {
                detailJobID = nil
            }
        } else {
            filesPage
        }
    }

    private var filesPage: some View {
        VStack(spacing: 0) {
            header

            Divider()

            if store.jobs.isEmpty {
                DropZoneView(store: store)
            } else {
                QueueTableView(store: store, detailJobID: $detailJobID)
            }

            if store.isRunning || store.isPreparingModel {
                Divider()
                RunningBar(store: store)
            } else if store.hasFinishedBatch {
                Divider()
                ResultBar(store: store)
            }
        }
    }

    private var header: some View {
        HStack(spacing: Space.group) {
            VStack(alignment: .leading, spacing: Space.optical) {
                Text("Files")
                    .font(Typography.pageTitle)

                Text(summary)
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textSecondary)
            }

            Spacer(minLength: Space.group)

            if store.jobs.count > 1 {
                Picker("Show", selection: $store.queueFilter) {
                    ForEach(TranscriptionStore.QueueFilter.allCases) { filter in
                        Text("\(filter.displayName) (\(store.count(for: filter)))")
                            .tag(filter)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
                .help("Filter the file list")
            }

            Menu("Queue") {
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
            }
            .menuStyle(.button)
            .fixedSize()

            Button {
                store.presentFilePicker()
            } label: {
                Label("Add Files…", systemImage: "plus")
            }
            .help("Add audio or video files (⌘O)")
        }
        .padding(.horizontal, Space.page)
        .padding(.vertical, Space.group)
    }

    private var summary: String {
        let count = store.jobs.count
        guard count > 0 else { return "Nothing added yet" }
        return "\(count) file\(count == 1 ? "" : "s")"
            + (store.completedCount > 0 ? " · \(store.completedCount) done" : "")
    }
}

/// Overall progress while a batch runs: which file, how far, and a way to stop.
private struct RunningBar: View {
    @ObservedObject var store: TranscriptionStore

    var body: some View {
        VStack(alignment: .leading, spacing: Space.close) {
            HStack {
                if store.isPreparingModel {
                    ProgressView().controlSize(.small)
                    Text("Checking the model…")
                        .font(Typography.rowTitleEmphasized)
                } else {
                    Text("Transcribing \(store.batchCounterText ?? "")")
                        .font(Typography.rowTitleEmphasized)
                        .monospacedDigit()
                }

                Spacer()

                Text(store.statusMessage)
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            if store.isPreparingModel {
                ProgressView().progressViewStyle(.linear)
            } else {
                ProgressView(value: store.batchProgress)
                    .progressViewStyle(.linear)
            }
        }
        .padding(Space.page)
        .background(Palette.contentBackground)
        .accessibilityElement(children: .combine)
    }
}

/// The "done" state: what happened, and the one-click ways to get the output.
private struct ResultBar: View {
    @ObservedObject var store: TranscriptionStore

    var body: some View {
        let failed = store.failedJobCount
        let completed = store.completedCount
        let allGood = failed == 0 && completed > 0

        HStack(spacing: Space.group) {
            Image(systemName: allGood ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 22))
                .foregroundStyle(allGood ? Palette.success : Palette.warning)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: Space.optical) {
                Text(title(completed: completed, failed: failed))
                    .font(Typography.paneTitle)

                Text("Saved to \(store.lastBatchPathForDisplay)")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(store.currentOutputDirectory.path)
                    .textSelection(.enabled)
            }

            Spacer(minLength: Space.group)

            if failed > 0 {
                Button("Retry Failed") {
                    store.retryFailedJobs()
                }
            }

            Button("Clear Finished") {
                store.clearCompleted()
            }
            .disabled(completed == 0)

            Button {
                store.revealOutputDirectory()
            } label: {
                Label("Show in Finder", systemImage: "folder")
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(Space.page)
        .background(allGood ? Palette.successFill : Palette.warningFill)
        .accessibilityElement(children: .contain)
    }

    private func title(completed: Int, failed: Int) -> String {
        if failed == 0 {
            return completed == 1 ? "Done — 1 file transcribed" : "Done — \(completed) files transcribed"
        }
        if completed == 0 {
            return failed == 1 ? "1 file failed" : "\(failed) files failed"
        }
        return "\(completed) transcribed, \(failed) failed"
    }
}

/// One file's transcript, as a page of the window with a way back. Not a sheet
/// or a popup.
struct TranscriptPage: View {
    @ObservedObject var store: TranscriptionStore
    let jobID: TranscriptionJob.ID
    let close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Space.group) {
                Button {
                    close()
                } label: {
                    Label("Files", systemImage: "chevron.left")
                }
                .keyboardShortcut(.cancelAction)
                .help("Back to the file list (Esc)")

                Spacer()

                if let text = job?.transcript?.fullText, !text.isEmpty {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                    } label: {
                        Label("Copy Transcript", systemImage: "doc.on.doc")
                    }
                }
            }
            .padding(.horizontal, Space.page)
            .padding(.vertical, Space.group)

            Divider()

            if let job {
                JobDetailView(store: store, job: job)
            } else {
                DetailPlaceholderView()
            }
        }
    }

    private var job: TranscriptionJob? {
        store.jobs.first { $0.id == jobID }
    }
}
