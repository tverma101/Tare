import SwiftUI
import TranscriberCore

/// Shown in the details panel when nothing is selected.
struct DetailPlaceholderView: View {
    var body: some View {
        VStack(spacing: Space.close) {
            Image(systemName: "text.alignleft")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(Palette.textTertiary)
                .accessibilityHidden(true)

            Text("No file selected")
                .font(Typography.sectionHeader)

            Text("Choose a file in the queue to read its transcript and open its files.")
                .font(Typography.caption)
                .foregroundStyle(Palette.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Space.page)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct JobDetailView: View {
    @ObservedObject var store: TranscriptionStore
    let job: TranscriptionJob

    var body: some View {
        VStack(spacing: 0) {
            DetailHeader(store: store, job: job)

            Divider()

            if let text = readableText {
                // A lecture is thousands of words. It gets the whole pane in a
                // real scrolling, searchable text view instead of a capped
                // preview inside another scroller.
                TranscriptReader(text: text)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: Space.page) {
                        JobStatusCard(store: store, job: job)

                        Text(emptyStateDetail)
                            .font(Typography.body)
                            .foregroundStyle(Palette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(Space.page)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            if !job.outputURLs.isEmpty {
                Divider()
                OutputFilesBar(store: store, job: job)
            }
        }
    }

    /// Text is only shown for work that is finished or still current, so a failed
    /// or cancelled run does not present a previous attempt's output as this
    /// one's result.
    private var readableText: String? {
        guard job.status == .completed || job.status == .exporting,
              let text = job.transcript?.fullText, !text.isEmpty else { return nil }
        return text
    }

    private var emptyStateDetail: String {
        switch job.status {
        case .queued:
            return "Press Transcribe to create the transcript for this file."
        case .extractingAudio, .transcribing, .exporting:
            return "The transcript appears here when the file finishes."
        case .failed:
            return "No transcript was produced. Fix the problem above, then choose Retry."
        case .cancelled:
            return "This file was stopped before it finished. Choose Requeue, then press Transcribe."
        case .completed:
            return "The model returned no text for this file. It may be silent."
        }
    }
}

private struct DetailHeader: View {
    @ObservedObject var store: TranscriptionStore
    let job: TranscriptionJob

    private static func isVideo(_ url: URL) -> Bool {
        ["mp4", "m4v", "mov", "mkv", "avi", "webm"].contains(url.pathExtension.lowercased())
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: Self.isVideo(job.sourceURL) ? "film" : "waveform")
                .font(.title3)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text(job.sourceURL.lastPathComponent)
                    .font(.headline)
                    .lineLimit(1)

                Text(job.sourceURL.deletingLastPathComponent().path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(job.sourceURL.deletingLastPathComponent().path)
                    .textSelection(.enabled)

                if let linkedTranscriptURL = job.linkedTranscriptURL {
                    Button {
                        store.reveal(linkedTranscriptURL)
                    } label: {
                        Label(
                            "Linked transcript: \(linkedTranscriptURL.lastPathComponent)",
                            systemImage: "link"
                        )
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                    .lineLimit(1)
                }
            }

            Spacer()

            Button {
                store.reveal(job.sourceURL)
            } label: {
                Label("Reveal", systemImage: "magnifyingglass")
                    .labelStyle(.iconOnly)
            }
            .help("Reveal the source file in Finder")
        }
        .padding(.horizontal, Space.page)
        .padding(.vertical, Space.group)
    }
}

private struct JobStatusCard: View {
    @ObservedObject var store: TranscriptionStore
    let job: TranscriptionJob

    var body: some View {
        let presentation = StatePresentation.forJob(job)

        VStack(alignment: .leading, spacing: Space.close) {
            HStack {
                presentation.symbolView(size: 15)
                    .frame(width: 20, alignment: .center)

                Text(presentation.title)
                    .font(Typography.sectionHeader)
                    .foregroundStyle(Palette.textPrimary)

                Spacer()

                if job.status == .failed || job.status == .cancelled {
                    Button {
                        store.retrySelectedJob()
                    } label: {
                        Label(job.status == .cancelled ? "Requeue" : "Retry", systemImage: "arrow.clockwise")
                    }
                    .help(store.isRunning
                        ? "Return this job to the queue. It will run when you press Start again."
                        : "Return this job to the queue, then press Start.")
                }
            }

            if job.status != .completed {
                ProgressView(value: job.progress)
                    .accessibilityLabel("\(job.displayName) progress")
                    .accessibilityValue(progressDescription)
            }

            if let chunks = job.chunkProgress, chunks.total > 1 {
                Text("Chunk \(chunks.completed) of \(chunks.total)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            JobTimingView(job: job)

            if let errorMessage = job.errorMessage {
                Label {
                    Text(errorMessage)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                } icon: {
                    Image(systemName: "exclamationmark.triangle")
                }
                .foregroundStyle(Palette.danger)
            }
        }
        .padding(Space.group)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    private var progressDescription: String {
        var parts = [job.status.displayName, "\(Int((job.progress * 100).rounded())) percent"]
        if let chunks = job.chunkProgress, chunks.total > 1 {
            parts.append("chunk \(chunks.completed) of \(chunks.total)")
        }
        return parts.joined(separator: ", ")
    }
}

private struct JobTimingView: View {
    let job: TranscriptionJob

    var body: some View {
        if let startedAt = job.startedAt {
            if job.status.isTerminal, let completedAt = job.completedAt {
                // A finished job must not keep a 1 Hz redraw loop alive.
                timingRow(
                    elapsed: max(0, completedAt.timeIntervalSince(startedAt)),
                    finished: completedAt
                )
            } else {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    timingRow(elapsed: max(0, context.date.timeIntervalSince(startedAt)))
                }
            }
        }
    }

    private func timingRow(elapsed: TimeInterval, finished: Date? = nil) -> some View {
        HStack(spacing: 14) {
            Label("Elapsed \(Self.formatDuration(elapsed))", systemImage: "timer")

            if let finished {
                Text("Finished \(finished.formatted(date: .omitted, time: .shortened))")
                    .frame(width: Self.etaWidth, alignment: .leading)
            } else if let remaining = estimatedRemaining(elapsed: elapsed) {
                Label("ETA \(Self.formatDuration(remaining))", systemImage: "hourglass")
                    .frame(width: Self.etaWidth, alignment: .leading)
            } else {
                // A fixed-width slot keeps the row from jumping when the estimate
                // resolves, since the text itself changes width.
                Text("ETA —")
                    .foregroundStyle(.tertiary)
                    .frame(width: Self.etaWidth, alignment: .leading)
            }

            Spacer()
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
    }

    private static let etaWidth: CGFloat = 96

    /// Extrapolates from measured progress.
    ///
    /// Progress used to sit at a fixed 20% for the whole local transcription, so
    /// this returned a constant multiple of elapsed time — an estimate that could
    /// never converge. It is only meaningful once real per-chunk progress exists.
    private func estimatedRemaining(elapsed: TimeInterval) -> TimeInterval? {
        guard !job.status.isTerminal else { return nil }
        guard job.progress > 0.03, job.progress < 1 else { return nil }
        guard job.chunkProgress != nil || job.status == .exporting else { return nil }
        return max(0, elapsed * (1 - job.progress) / job.progress)
    }

    private static func formatDuration(_ seconds: TimeInterval) -> String {
        let rounded = max(0, Int(seconds.rounded()))
        let hours = rounded / 3600
        let minutes = (rounded % 3600) / 60
        let seconds = rounded % 60

        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }
        if minutes > 0 {
            return "\(minutes)m \(seconds)s"
        }
        return "\(seconds)s"
    }
}

/// The finished transcript, in a native text view.
///
/// SwiftUI `Text` lays out its whole string eagerly, which is slow and heavy for
/// a lecture-length transcript. `NSTextView` lays out lazily, scrolls smoothly,
/// supports selection, and gives ⌘F find for free.
private struct TranscriptReader: View {
    let text: String

    private var wordCount: Int {
        text.split(whereSeparator: \.isWhitespace).count
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Transcript")
                    .font(Typography.sectionHeader)
                Spacer()
                Text("\(wordCount.formatted()) words · ⌘F to search")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textSecondary)
            }
            .padding(.horizontal, Space.page)
            .padding(.vertical, Space.close)

            Divider()

            LargeTextView(text: text)
        }
    }
}

private struct OutputFilesBar: View {
    @ObservedObject var store: TranscriptionStore
    let job: TranscriptionJob

    var body: some View {
        HStack(spacing: Space.group) {
            Label(
                "\(job.outputURLs.count) file\(job.outputURLs.count == 1 ? "" : "s") written",
                systemImage: "doc.on.doc"
            )
            .font(Typography.caption)
            .foregroundStyle(Palette.textSecondary)

            Spacer()

            Menu("Show in Finder") {
                ForEach(job.outputURLs, id: \.self) { url in
                    Button(url.lastPathComponent) { store.reveal(url) }
                }
            }
            .menuStyle(.button)
            .fixedSize()

            Menu("Open") {
                ForEach(job.outputURLs, id: \.self) { url in
                    Button(url.lastPathComponent) { store.open(url) }
                }
            }
            .menuStyle(.button)
            .fixedSize()
        }
        .padding(.horizontal, Space.page)
        .padding(.vertical, Space.close)
    }
}
