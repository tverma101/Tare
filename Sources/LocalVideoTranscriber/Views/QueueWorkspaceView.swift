import SwiftUI
import TranscriberCore

/// The Transcribe tab's detail pane.
///
/// The queue table is the primary surface, so it gets the full pane width and
/// the flexible height; the selected job's detail sits beneath it so both are
/// visible without a hidden panel or a toggle.
struct QueueWorkspaceView: View {
    @ObservedObject var store: TranscriptionStore

    var body: some View {
        VStack(spacing: 0) {
            StatusHeaderView(store: store)

            StatusStripView(store: store)

            if store.jobs.isEmpty {
                EmptyQueueView(store: store)
            } else {
                QueueTableView(store: store)
                    .frame(minHeight: Metric.tableMinHeight)

                if let job = store.selectedJob {
                    Divider()
                    ScrollView {
                        JobDetailView(store: store, job: job)
                    }
                    .frame(minHeight: Metric.jobDetailMinHeight)
                }
            }
        }
    }
}
