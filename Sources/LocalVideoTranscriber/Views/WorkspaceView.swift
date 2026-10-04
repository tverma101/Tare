import AppKit
import SwiftUI
import TranscriberCore

/// The right pane: the files, what is happening to each, and the result.
struct WorkspaceView: View {
    @ObservedObject var store: TranscriptionStore
    @Binding var detailJobID: TranscriptionJob.ID?

    var body: some View {
        switch store.workspaceMode {
        case .library:
            LibraryView(store: store)
        case .files:
            if let id = detailJobID {
                TranscriptPage(store: store, jobID: id)
            } else {
                filesPage
            }
        }
    }

    private var filesPage: some View {
        VStack(spacing: 0) {
            if store.jobs.isEmpty {
                DropZoneView(store: store)
            } else {
                QueueTableView(store: store, detailJobID: $detailJobID)
                    .overlay { DropHighlight(isTargeted: store.dropIsTargeted) }
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
}

/// The system-style drop target outline over the file list while files are
/// dragged in.
private struct DropHighlight: View {
    let isTargeted: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: Radius.card)
            .strokeBorder(Palette.active, lineWidth: 3)
            .background(Palette.accentFill, in: RoundedRectangle(cornerRadius: Radius.card))
            .padding(Space.close)
            .opacity(isTargeted ? 1 : 0)
            .allowsHitTesting(false)
            .animation(.easeOut(duration: 0.12), value: isTargeted)
            .overlay {
                if isTargeted {
                    Label("Drop to add", systemImage: "plus.circle.fill")
                        .font(Typography.pageTitle)
                        .foregroundStyle(Palette.active)
                }
            }
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

                Text("Saved in \(store.lastBatchFolderName)")
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

/// One file's transcript, as a page of the window. The way back and Copy live
/// in the window toolbar.
struct TranscriptPage: View {
    @ObservedObject var store: TranscriptionStore
    let jobID: TranscriptionJob.ID

    var body: some View {
        if let job {
            JobDetailView(store: store, job: job)
        } else {
            DetailPlaceholderView()
        }
    }

    private var job: TranscriptionJob? {
        store.jobs.first { $0.id == jobID }
    }
}
