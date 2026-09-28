import SwiftUI
import TranscriberCore

/// The job queue as a dense data table.
///
/// Row height is identical in every state and no cell ever adds or removes a
/// line, so the table does not resize as jobs move through the batch. The bar is
/// the only flexible element; every other cell is a fixed width, and the percent
/// and chunk slots are reserved even when empty so a chunk count appearing cannot
/// resize the bar.
struct QueueTableView: View {
    @ObservedObject var store: TranscriptionStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            Picker("Filter", selection: $store.queueFilter) {
                ForEach(TranscriptionStore.QueueFilter.allCases) { filter in
                    Text("\(filter.displayName) \(store.count(for: filter))")
                        .tag(filter)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .padding(.horizontal, Space.close)
            .padding(.vertical, Space.tight)
            .accessibilityLabel("Filter the job queue")

            Table(store.visibleJobs, selection: $store.selectedJobID) {
            TableColumn("") { job in
                StateCell(job: job)
            }
            .width(Metric.stateColumnWidth)

            TableColumn("Name") { job in
                Text(job.displayName)
                    .font(Typography.rowTitle)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(job.sourceURL.path)
            }
            .width(min: Metric.nameColumnMin, ideal: Metric.nameColumnIdeal)

            TableColumn("Type") { job in
                Text(job.fileExtension)
                    .font(Typography.mono)
                    .foregroundStyle(Palette.textTertiary)
                    .lineLimit(1)
            }
            .width(Metric.typeColumnWidth)

            TableColumn("Progress") { job in
                JobProgressCell(job: job, reduceMotion: reduceMotion)
            }
            .width(min: Metric.progressColumnMin, ideal: Metric.progressColumnIdeal, max: Metric.progressColumnMax)

            TableColumn("Outputs") { job in
                Text(job.outputURLs.isEmpty ? "—" : "\(job.outputURLs.count) file\(job.outputURLs.count == 1 ? "" : "s")")
                    .font(Typography.metadata)
                    .foregroundStyle(Palette.textSecondary)
                    .lineLimit(1)
            }
            .width(Metric.outputsColumnWidth)

            TableColumn("Note") { job in
                let presentation = StatePresentation.forJob(job)
                if let detail = presentation.detail, presentation.detail != job.errorMessage {
                    Text(detail)
                        .font(Typography.metadata)
                        .foregroundStyle(Palette.textSecondary)
                        .lineLimit(1)
                } else if let error = job.errorMessage {
                    Text(error)
                        .font(Typography.metadata)
                        .foregroundStyle(presentation.tint)
                        .lineLimit(1)
                        .help(error)
                } else {
                    Text("")
                }
            }
            .width(min: Metric.noteColumnMin, ideal: Metric.noteColumnIdeal)
        }
        .tableStyle(.inset)
        .accessibilityLabel("Job queue")
        }
    }
}

private struct StateCell: View {
    let job: TranscriptionJob

    var body: some View {
        let presentation = StatePresentation.forJob(job)
        presentation.symbolView()
            .frame(width: Metric.stateColumnWidth, height: Metric.rowHeight)
            .help(presentation.title)
            .accessibilityLabel("\(presentation.title) for \(job.displayName)")
    }
}

private struct JobProgressCell: View {
    let job: TranscriptionJob
    let reduceMotion: Bool

    var body: some View {
        let presentation = StatePresentation.forJob(job)

        // Quantizing kills sub-pixel shimmer from floating-point noise.
        let quantized = Double(Int((job.progress * 200).rounded())) / 200

        HStack(spacing: Space.tight) {
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

            Text(chunkText)
                .font(Typography.monoDigit)
                .foregroundStyle(Palette.textTertiary)
                .frame(width: Metric.chunkTextWidth, alignment: .trailing)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(job.displayName) progress")
        .accessibilityValue(accessibilityValue)
    }

    /// Always present, even when empty, so the bar cannot resize when a chunk
    /// count appears.
    private var chunkText: String {
        guard let chunks = job.chunkProgress, chunks.total > 1 else { return "" }
        return "\(chunks.completed) of \(chunks.total)"
    }

    private var accessibilityValue: String {
        let presentation = StatePresentation.forJob(job)
        var parts = [presentation.title]
        if job.status != .queued {
            parts.append("\(Int((job.progress * 100).rounded())) percent")
        }
        if !chunkText.isEmpty { parts.append("chunk \(chunkText)") }
        return parts.joined(separator: ", ")
    }
}
