import SwiftUI
import TranscriberCore

/// The file list: a state mark, the file with a line saying what is happening to it,
/// a progress bar, and the actions that get you the result.
///
/// Row height is identical in every state and no cell ever adds or removes a
/// line, so the table does not resize as jobs move through the batch. The bar is
/// the only flexible element; the percent slot is reserved even when empty.
struct QueueTableView: View {
    @ObservedObject var store: TranscriptionStore
    @Binding var detailJobID: TranscriptionJob.ID?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Table(store.visibleJobs, selection: $store.selectedJobID) {
            TableColumn("") { job in
                StateCell(job: job)
            }
            .width(Metric.stateColumnWidth)

            TableColumn("File") { job in
                FileCell(job: job)
            }
            .width(min: Metric.nameColumnMin, ideal: Metric.nameColumnIdeal)

            TableColumn("Progress") { job in
                JobProgressCell(job: job, reduceMotion: reduceMotion)
            }
            .width(min: Metric.progressColumnMin, ideal: Metric.progressColumnIdeal, max: Metric.progressColumnMax)

            TableColumn("") { job in
                ActionsCell(store: store, job: job) {
                    detailJobID = job.id
                }
            }
            .width(Metric.actionsColumnWidth)
        }
        .tableStyle(.inset)
        .accessibilityLabel("Job queue")
        .contextMenu(forSelectionType: TranscriptionJob.ID.self) { ids in
            if let id = ids.first, let job = store.jobs.first(where: { $0.id == id }) {
                if store.showTranscriptPreview || job.status == .failed {
                    Button(job.status == .failed ? "Show Error Details" : "Show Transcript and Files") {
                        store.selectedJobID = id
                        detailJobID = id
                    }
                }
                Button("Reveal Source in Finder") {
                    store.reveal(job.sourceURL)
                }
                if job.status == .failed || job.status == .cancelled {
                    Button(job.status == .cancelled ? "Requeue" : "Retry") {
                        store.requeue(job.id)
                    }
                }
                Divider()
                Button("Remove from Queue", role: .destructive) {
                    store.removeJob(id)
                }
            }
        } primaryAction: { ids in
            if let id = ids.first {
                store.selectedJobID = id
                if let status = store.jobs.first(where: { $0.id == id })?.status,
                   (store.showTranscriptPreview && status == .completed) || status == .failed {
                    detailJobID = id
                }
            }
        }
        .onDeleteCommand {
            store.removeSelectedJob()
        }
    }
}

/// The way to get the result, on the row that produced it.
private struct ActionsCell: View {
    @ObservedObject var store: TranscriptionStore
    let job: TranscriptionJob
    let showDetails: () -> Void

    var body: some View {
        HStack(spacing: Space.close) {
            switch job.status {
            case .completed:
                if let primary = job.outputURLs.first {
                    Button("Open") { store.open(primary) }
                        .help("Open \(primary.lastPathComponent)")
                }
                if store.showTranscriptPreview {
                    Button("View") { showDetails() }
                        .help("Read the transcript and see every file")
                } else if let primary = job.outputURLs.first {
                    Button("Show") { store.reveal(primary) }
                        .help("Show \(primary.lastPathComponent) in Finder")
                }
            case .failed, .cancelled:
                if job.status == .failed {
                    Button("Details") { showDetails() }
                        .help("Read the full error")
                }
                Button(job.status == .failed ? "Retry" : "Requeue") { store.requeue(job.id) }
                    .help("Return this file to the queue")
            default:
                EmptyView()
            }
        }
        .buttonStyle(.link)
        .font(Typography.metadata)
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

private struct StateCell: View {
    let job: TranscriptionJob

    var body: some View {
        let presentation = StatePresentation.forJob(job)
        presentation.symbolView()
            .frame(width: Metric.stateColumnWidth, height: Metric.rowHeightTwoLine)
            .help(presentation.title)
            .accessibilityLabel("\(presentation.title) for \(job.displayName)")
    }
}

/// The file name with one line beneath it saying what is happening to it, so
/// the table needs no separate status, type, output, or note columns.
private struct FileCell: View {
    let job: TranscriptionJob

    var body: some View {
        let presentation = StatePresentation.forJob(job)

        VStack(alignment: .leading, spacing: Space.optical) {
            Text(job.displayName)
                .font(Typography.rowTitle)
                .lineLimit(1)
                .truncationMode(.middle)

            Text(subtitle(presentation))
                .font(Typography.metadata)
                .foregroundStyle(job.status == .failed ? Palette.danger : Palette.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .frame(height: Metric.rowHeightTwoLine, alignment: .leading)
        .help(job.errorMessage ?? job.sourceURL.path)
    }

    private func subtitle(_ presentation: StatePresentation) -> String {
        var parts = [presentation.title]
        if let detail = presentation.detail { parts.append(detail) }
        return parts.joined(separator: " · ")
    }
}

private struct JobProgressCell: View {
    let job: TranscriptionJob
    let reduceMotion: Bool

    var body: some View {
        let presentation = StatePresentation.forJob(job)

        // Quantizing kills sub-pixel shimmer from floating-point noise.
        let quantized = Double(Int((job.progress * 200).rounded())) / 200

        HStack(spacing: Space.close) {
            ProgressView(value: quantized)
                .progressViewStyle(.linear)
                .controlSize(.small)
                .tint(presentation.isBusy ? Palette.active : Palette.progressTerminal)
                .frame(maxWidth: .infinity)
                .animation(
                    Motion.resolved(Motion.progressFill, reduceMotion: reduceMotion),
                    value: quantized
                )

            Text(job.status == .queued ? "—" : "\(Int((quantized * 100).rounded()))%")
                .font(Typography.monoDigit)
                .foregroundStyle(Palette.textSecondary)
                .frame(width: Metric.percentTextWidth, alignment: .trailing)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(job.displayName) progress")
        .accessibilityValue(accessibilityValue)
    }

    private var accessibilityValue: String {
        let presentation = StatePresentation.forJob(job)
        var parts = [presentation.title]
        if job.status != .queued {
            parts.append("\(Int((job.progress * 100).rounded())) percent")
        }
        if let chunks = job.chunkProgress, chunks.total > 1 {
            parts.append("chunk \(chunks.completed) of \(chunks.total)")
        }
        return parts.joined(separator: ", ")
    }
}
