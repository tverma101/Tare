import SwiftUI
import TranscriberCore

struct DetailView: View {
    @ObservedObject var store: TranscriptionStore

    var body: some View {
        Group {
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
        VStack(spacing: 18) {
            Image(systemName: store.dropIsTargeted ? "arrow.down.doc.fill" : "film.stack")
                .font(.system(size: 56, weight: .regular))
                .foregroundStyle(store.dropIsTargeted ? .blue : .secondary)

            Text(store.dropIsTargeted ? "Drop to Add" : "No Files")
                .font(.title2)
                .fontWeight(.semibold)

            Button {
                store.presentFilePicker()
            } label: {
                Label("Add Files", systemImage: "plus")
            }
            .controlSize(.large)

        }
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
                .padding(20)
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
                        Label("Retry", systemImage: "arrow.clockwise")
                    }
                }
            }

            ProgressView(value: job.progress)

            JobTimingView(job: job)

            if let errorMessage = job.errorMessage {
                Label {
                    Text(errorMessage)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                } icon: {
                    Image(systemName: "exclamationmark.triangle")
                }
                .foregroundStyle(.red)
            }
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct JobTimingView: View {
    let job: TranscriptionJob

    var body: some View {
        if let startedAt = job.startedAt {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let referenceDate = job.completedAt ?? context.date
                let elapsed = max(0, referenceDate.timeIntervalSince(startedAt))

                HStack(spacing: 14) {
                    Label("Elapsed \(formatDuration(elapsed))", systemImage: "timer")

                    if let completedAt = job.completedAt {
                        Text("Finished \(completedAt.formatted(date: .omitted, time: .shortened))")
                    } else if let remaining = estimatedRemaining(elapsed: elapsed) {
                        Label("ETA \(formatDuration(remaining))", systemImage: "hourglass")
                    } else {
                        Label("ETA estimating", systemImage: "hourglass")
                    }

                    Spacer()
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }
        }
    }

    private func estimatedRemaining(elapsed: TimeInterval) -> TimeInterval? {
        guard !job.status.isTerminal else { return nil }
        guard job.progress > 0.03, job.progress < 1 else { return nil }
        return max(0, elapsed * (1 - job.progress) / job.progress)
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
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
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Export", systemImage: "square.and.arrow.down")
                    .font(.headline)

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

            Text(store.lastOutputDirectory == nil
                 ? "Each batch gets its own named folder inside the configured output location."
                 : "Current batch output folder. Choose a different root in Settings if needed.")
                .font(.caption)
                .foregroundStyle(.tertiary)

            RecognitionSettingsView(store: store)

            Toggle("Save Plain Transcript", isOn: Binding(
                get: { store.savesTextTranscript },
                set: { store.setTextTranscriptEnabled($0) }
            ))
            .toggleStyle(.checkbox)

            Toggle("Save Timestamped Transcript", isOn: Binding(
                get: { store.savesTimestampedTranscript },
                set: { store.setTimestampedTranscriptEnabled($0) }
            ))
            .toggleStyle(.checkbox)
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct TranscriptOutputView: View {
    let job: TranscriptionJob

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
                ScrollView(.vertical) {
                    Text(transcript.fullText)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.trailing, 4)
                }
                .frame(maxWidth: .infinity, minHeight: 140, maxHeight: 280, alignment: .topLeading)
                .scrollIndicators(.automatic)
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
        .padding(14)
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
        .padding(14)
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
