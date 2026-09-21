import SwiftUI
import TranscriberCore

struct SidebarView: View {
    @ObservedObject var store: TranscriptionStore

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $store.selectedJobID) {
                Section("Queue") {
                    ForEach(store.jobs) { job in
                        SidebarRow(job: job)
                            .tag(job.id)
                            .contextMenu {
                                Button("Reveal Source") {
                                    store.reveal(job.sourceURL)
                                }

                                if job.status == .failed || job.status == .cancelled {
                                    Button("Retry") {
                                        store.selectedJobID = job.id
                                        store.retrySelectedJob()
                                    }
                                }
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

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: iconName)
                .foregroundStyle(iconStyle)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                Text(job.displayName)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    Text(job.status.displayName)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if !job.fileExtension.isEmpty {
                        Text(job.fileExtension)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
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
            return AnyShapeStyle(.blue)
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
                Spacer()
                Label("\(store.completedCount)", systemImage: "checkmark.circle")
                Label("\(store.failedCount)", systemImage: "exclamationmark.triangle")
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            HStack {
                Button {
                    store.clearCompleted()
                } label: {
                    Label("Clear", systemImage: "checkmark.circle")
                }
                .disabled(store.isRunning || store.isScanning || store.isOrganizing || store.completedCount == 0)

                Spacer()

                Button {
                    store.revealOutputDirectory()
                } label: {
                    Label("Show Outputs", systemImage: "folder")
                }
            }
            .controlSize(.small)
        }
        .padding(10)
    }
}
