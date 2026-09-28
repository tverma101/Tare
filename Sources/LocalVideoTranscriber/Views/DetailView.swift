import SwiftUI
import TranscriberCore

struct DetailView: View {
    @ObservedObject var store: TranscriptionStore

    var body: some View {
        VStack(spacing: 0) {
            StatusHeaderView(store: store)

            StatusStripView(store: store)

            if let job = store.selectedJob {
                JobDetailView(store: store, job: job)
            } else {
                EmptyQueueView(store: store)
            }
        }
    }
}

private struct EmptyQueueView: View {
    @ObservedObject var store: TranscriptionStore

    var body: some View {
        let isEmptyQueue = store.jobs.isEmpty

        VStack(spacing: Space.group) {
            Image(systemName: store.dropIsTargeted ? "arrow.down.doc.fill" : "film.stack")
                .imageScale(.large)
                .foregroundStyle(store.dropIsTargeted ? Palette.active : Palette.textSecondary)
                .accessibilityHidden(true)

            Text(store.dropIsTargeted ? "Drop to Add" : (isEmptyQueue ? "No Files" : "Nothing Selected"))
                .font(Typography.pageTitle)

            Text(store.dropIsTargeted
                ? "Release to add these files to the queue."
                : (isEmptyQueue
                    ? "Add audio or video to start a batch. You can also drag files onto this window."
                    : "Choose a file in the queue to see its status, transcript, and output files."))
                .font(Typography.body)
                .foregroundStyle(Palette.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
                .fixedSize(horizontal: false, vertical: true)

            if isEmptyQueue {
                Button {
                    store.presentFilePicker()
                } label: {
                    Label("Add Files", systemImage: "plus")
                }
                .controlSize(.large)
            }
        }
        .padding(Space.page)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct JobDetailView: View {
    @ObservedObject var store: TranscriptionStore
    let job: TranscriptionJob

    var body: some View {
        VStack(spacing: 0) {
            DetailHeader(store: store, job: job)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    JobStatusCard(store: store, job: job)

                    TranscriptOutputView(job: job)

                    ExportOptionsView(store: store)

                    OutputFilesView(store: store, job: job)
                }
                .padding(Space.page)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

private struct DetailHeader: View {
    @ObservedObject var store: TranscriptionStore
    let job: TranscriptionJob

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "film")
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
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }
}

private struct JobStatusCard: View {
    @ObservedObject var store: TranscriptionStore
    let job: TranscriptionJob

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(job.status.displayName)
                    .font(.headline)

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

            ProgressView(value: job.progress)
                .accessibilityLabel("\(job.displayName) progress")
                .accessibilityValue(progressDescription)

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

private struct ExportOptionsView: View {
    @ObservedObject var store: TranscriptionStore

    var body: some View {
        VStack(alignment: .leading, spacing: Space.group) {
            HStack {
                Label("Export", systemImage: "square.and.arrow.down")
                    .font(Typography.sectionHeader)

                Spacer()

                Toggle("Batch Folder", isOn: $store.createBatchFolder)
                    .toggleStyle(.checkbox)

                Button {
                    store.revealOutputDirectory()
                } label: {
                    Label("Show in Finder", systemImage: "folder")
                }

                Button {
                    store.presentOutputDirectoryPicker()
                } label: {
                    Label("Choose", systemImage: "folder.badge.gearshape")
                }
            }

            Text(store.currentOutputDirectory.path)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(store.currentOutputDirectory.path)
                .textSelection(.enabled)

            Text(store.lastOutputDirectory == nil
                 ? "Each batch gets its own named folder inside the configured output location."
                 : "Current batch output folder. Choose a different root in Settings if needed.")
                .font(.caption)
                .foregroundStyle(.tertiary)

            RecognitionSettingsView(store: store)

            VStack(alignment: .leading, spacing: Space.tight) {
                Text("Transcript files")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textSecondary)

                ForEach(ExportFormat.visibleManualFormats) { format in
                    Toggle(isOn: formatBinding(format)) {
                        Text(format.displayName)
                            .font(Typography.rowTitle)
                    }
                    .toggleStyle(.checkbox)
                    .disabled(format.needsWordTimestamps && !modelProvidesWordTimestamps)
                    .help(formatHelp(format))
                }

                if !modelProvidesWordTimestamps {
                    Label(
                        "\(store.effectiveSelectedModelIdentifier) does not produce word-level timings, so Word Timings and Apple Music TTML are unavailable.",
                        systemImage: "info.circle"
                    )
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(Space.group)
        .background(Palette.contentBackground, in: RoundedRectangle(cornerRadius: Radius.card))
    }

    private var modelProvidesWordTimestamps: Bool {
        WhisperModelPreset.preset(for: store.effectiveSelectedModelIdentifier)?
            .supportsWordTimestamps ?? true
    }

    private func formatBinding(_ format: ExportFormat) -> Binding<Bool> {
        Binding(
            get: { store.selectedFormats.contains(format) },
            set: { isEnabled in
                if isEnabled {
                    store.selectedFormats.insert(format)
                } else {
                    store.selectedFormats.remove(format)
                }
            }
        )
    }

    private func formatHelp(_ format: ExportFormat) -> String {
        if format.needsWordTimestamps && !modelProvidesWordTimestamps {
            return "The selected model does not produce word-level timings."
        }
        return "Writes a .\(format.fileExtension) file beside the transcript."
    }
}

private struct TranscriptOutputView: View {
    let job: TranscriptionJob
    @State private var isShowingFullTranscript = false
    private static let previewCharacterLimit = 4_000

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Transcript output", systemImage: "text.alignleft")
                        .font(.headline)
                    Text("Your transcribed text appears here.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Text(transcriptState)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let transcript = job.transcript, !transcript.fullText.isEmpty {
                // No nested scroller: the inner one competed with the page for
                // scroll events, which made the panels below unreachable while
                // the pointer was over the text. A long transcript is capped and
                // opened in full from the exported file or a sheet.
                VStack(alignment: .leading, spacing: 8) {
                    Text(String(transcript.fullText.prefix(Self.previewCharacterLimit)))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)

                    if transcript.fullText.count > Self.previewCharacterLimit {
                        HStack(spacing: 10) {
                            Text("Preview limited to \(Self.previewCharacterLimit) characters.")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            Spacer()

                            Button("Show Full Transcript") {
                                isShowingFullTranscript = true
                            }
                            .buttonStyle(.link)
                        }
                    }
                }
                .padding(Space.close)
                .frame(maxWidth: .infinity, minHeight: 140, alignment: .topLeading)
                .background(Palette.textWellBackground, in: RoundedRectangle(cornerRadius: Radius.inline))
                .sheet(isPresented: $isShowingFullTranscript) {
                    ScrollView {
                        Text(transcript.fullText)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(Space.page)
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Label(emptyStateTitle, systemImage: emptyStateIcon)
                        .font(.body.weight(.medium))
                    Text(emptyStateDetail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 112, alignment: .topLeading)
            }
        }
        .padding(Space.group)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    private var transcriptState: String {
        if let transcript = job.transcript, !transcript.fullText.isEmpty {
            return "Ready"
        }

        switch job.status {
        case .queued:
            return "Not started"
        case .extractingAudio, .transcribing, .exporting:
            return "In progress"
        case .failed:
            return "Needs attention"
        case .cancelled:
            return "Cancelled"
        case .completed:
            return "No text"
        }
    }

    private var emptyStateTitle: String {
        switch job.status {
        case .queued:
            return "Ready to transcribe"
        case .extractingAudio, .transcribing, .exporting:
            return "Transcript will appear here"
        case .failed:
            return "No transcript was produced"
        case .cancelled:
            return "Transcription was cancelled"
        case .completed:
            return "No transcript text available"
        }
    }

    private var emptyStateDetail: String {
        switch job.status {
        case .queued:
            return "Choose Start above to create the transcript for this file."
        case .extractingAudio, .transcribing, .exporting:
            return "Tare updates this panel when transcription finishes."
        case .failed:
            return "Resolve the issue in the status card above, then choose Retry."
        case .cancelled:
            return "Choose Retry or Start to run this file again."
        case .completed:
            return "The local model returned no transcript text for this file."
        }
    }

    private var emptyStateIcon: String {
        switch job.status {
        case .failed:
            return "exclamationmark.triangle"
        case .cancelled:
            return "stop.circle"
        case .queued:
            return "text.badge.plus"
        case .extractingAudio, .transcribing, .exporting:
            return "waveform"
        case .completed:
            return "text.magnifyingglass"
        }
    }
}

private struct OutputFilesView: View {
    @ObservedObject var store: TranscriptionStore
    let job: TranscriptionJob

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Files", systemImage: "doc.on.doc")
                .font(.headline)

            if job.outputURLs.isEmpty {
                Text("No output yet")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(job.outputURLs, id: \.self) { url in
                    HStack {
                        Image(systemName: iconName(for: url))
                            .foregroundStyle(.secondary)

                        Text(url.lastPathComponent)
                            .lineLimit(1)

                        Spacer()

                        Button {
                            store.reveal(url)
                        } label: {
                            Label("Reveal", systemImage: "magnifyingglass")
                        }
                    }
                }
            }
        }
        .padding(Space.group)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    private func iconName(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "mp4", "m4v", "mkv", "mov":
            return "film"
        default:
            return "doc.text"
        }
    }
}
