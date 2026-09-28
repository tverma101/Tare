import SwiftUI
import TranscriberCore

struct SidebarView: View {
    @ObservedObject var store: TranscriptionStore

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $store.selectedJobID) {
                Section("Queue") {
                    ForEach(store.jobs) { job in
                        SidebarRow(job: job, isActive: store.activeJobID == job.id)
                            .tag(job.id)
                            .contextMenu {
                                Button("Reveal Source") {
                                    store.reveal(job.sourceURL)
                                }

                                if job.status == .failed || job.status == .cancelled {
                                    Button(job.status == .cancelled ? "Requeue" : "Retry") {
                                        store.requeue(job.id)
                                    }
                                }
                            }
                            .accessibilityAction(named: "Reveal Source") {
                                store.reveal(job.sourceURL)
                            }
                    }
                }
            }
            .listStyle(.sidebar)

            Divider()

            SidebarFooter(store: store)
        }
    }
}

private struct SidebarRow: View {
    let job: TranscriptionJob
    let isActive: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: iconName)
                .foregroundStyle(iconStyle)
                .frame(width: 16)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(job.displayName)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    Text(statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if !job.fileExtension.isEmpty {
                        Text(job.fileExtension)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                .lineLimit(1)

                if isActive {
                    ProgressView(value: job.progress)
                        .progressViewStyle(.linear)
                        .controlSize(.small)
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(job.displayName), \(statusText)\(job.fileExtension.isEmpty ? "" : ", \(job.fileExtension)")")
    }

    /// Says which job the batch is working on, so the row is distinguishable
    /// from the user's own selection.
    private var statusText: String {
        guard isActive else { return job.status.displayName }
        if let chunks = job.chunkProgress, chunks.total > 1 {
            return "\(job.status.displayName) · chunk \(chunks.completed) of \(chunks.total)"
        }
        return "\(job.status.displayName) · running"
    }

    private var iconName: String {
        switch job.status {
        case .completed:
            return "checkmark.circle.fill"
        case .failed:
            return "xmark.octagon.fill"
        case .cancelled:
            return "stop.circle.fill"
        case .extractingAudio, .transcribing, .exporting:
            return "waveform"
        case .queued:
            return "film"
        }
    }

    private var iconStyle: some ShapeStyle {
        switch job.status {
        case .completed:
            return AnyShapeStyle(.green)
        case .failed:
            return AnyShapeStyle(.red)
        case .cancelled:
            return AnyShapeStyle(.secondary)
        case .extractingAudio, .transcribing, .exporting:
            return AnyShapeStyle(isActive ? AnyShapeStyle(.tint) : AnyShapeStyle(.blue))
        case .queued:
            return AnyShapeStyle(.secondary)
        }
    }
}

private struct SidebarFooter: View {
    @ObservedObject var store: TranscriptionStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("\(store.jobs.count)", systemImage: "tray.full")
                    .help("\(store.jobs.count) file\(store.jobs.count == 1 ? "" : "s") in the queue")
                Spacer()
                Label("\(store.completedCount)", systemImage: "checkmark.circle")
                    .help("\(store.completedCount) completed")
                Label("\(store.failedCount)", systemImage: "exclamationmark.triangle")
                    .help("\(store.failedCount) failed")
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            HStack {
                Button {
                    store.clearCompleted()
                } label: {
                    Label("Clear Completed", systemImage: "checkmark.circle")
                }
                .disabled(store.isRunning || store.isScanning || store.isOrganizing || store.completedCount == 0)
                .help(store.completedCount == 0
                    ? "No completed jobs to clear"
                    : "Removes \(store.completedCount) finished job\(store.completedCount == 1 ? "" : "s") from the queue. Output files are kept.")

                Spacer()

                Button {
                    store.revealOutputDirectory()
                } label: {
                    Label("Show in Finder", systemImage: "folder")
                }
                .help("Reveal the current output folder")
            }
            .controlSize(.small)
        }
        .padding(10)
    }
}
