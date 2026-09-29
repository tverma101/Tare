import SwiftUI
import TranscriberCore

/// The current state of the app, in the largest type on the page, with the
/// primary action beside it. This is the first thing the eye should land on.
struct StatusHeaderView: View {
    @ObservedObject var store: TranscriptionStore

    var body: some View {
        let presentation = AppPhase.resolve(store).presentation

        HStack(alignment: .center, spacing: Space.group) {
            presentation.symbolView(size: 20)
                .frame(width: 26, alignment: .center)

            VStack(alignment: .leading, spacing: Space.optical) {
                Text(presentation.title)
                    .font(Typography.paneTitle)
                    .foregroundStyle(Palette.textPrimary)

                Text(presentation.detail ?? store.statusMessage)
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: Space.group)

            BatchMenu(store: store)
        }
        .frame(height: Metric.headerHeight)
        .padding(.horizontal, Space.page)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(presentation.title). \(store.statusMessage)")
    }}

/// A fixed-height progress strip.
///
/// The height never changes, so nothing below it shifts between idle and running,
/// and the phase text is truncated here rather than in a toolbar item where a long
/// string would reflow the window chrome.
struct StatusStripView: View {
    @ObservedObject var store: TranscriptionStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let phase = AppPhase.resolve(store)
        let presentation = phase.presentation
        let isRunning = store.isRunning || store.isPreparingModel

        VStack(spacing: 0) {
            HStack(spacing: Space.close) {
                if isRunning {
                    // Fixed-width counter so the bar is the only thing that moves.
                    Text(store.batchCounterText ?? "")
                        .font(Typography.monoDigit)
                        .foregroundStyle(Palette.textSecondary)
                        .frame(width: Metric.batchCounterWidth, alignment: .leading)

                    ProgressView()
                        .progressViewStyle(.linear)
                        .controlSize(.small)
                        .tint(presentation.tint)
                        .frame(maxWidth: .infinity)
                        .animation(
                            Motion.resolved(Motion.progressFill, reduceMotion: reduceMotion),
                            value: store.batchProgress
                        )
                } else {
                    // Idle has no progress to show, and restating the header's
                    // state would waste the row.
                    Color.clear.frame(height: Metric.progressBarHeight)
                        .accessibilityHidden(true)
                }

                Text(store.statusMessage)
                    .font(Typography.monoInline)
                    .foregroundStyle(isRunning ? Palette.textSecondary : Palette.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(1)
            }
            .padding(.horizontal, Space.page)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: Metric.statusStripHeight)
        .background(Palette.contentBackground)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Palette.hairline)
                .frame(height: Metric.hairline)
        }
    }
}

/// Secondary batch actions, kept off the primary button so the primary action is
/// unambiguous.
private struct BatchMenu: View {
    @ObservedObject var store: TranscriptionStore

    var body: some View {
        HStack(spacing: Space.close) {
            Menu {
                Button("Scan Folders for MKV") {
                    Task { await store.scanForMKVs() }
                }
                .disabled(!store.canScanForMKVs)

                Button("Clean Names & Organize") {
                    store.requestOrganizeConfirmation()
                }
                .disabled(!store.canCleanAndOrganizeMKVs)

                Divider()

                Button("Clear Completed") {
                    store.clearCompleted()
                }
                .disabled(store.isRunning || store.completedCount == 0)

                Button("Show Output in Finder") {
                    store.revealOutputDirectory()
                }
            } label: {
                Label("Batch Actions", systemImage: "ellipsis.circle")
                    .labelStyle(.iconOnly)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Batch actions")
            .accessibilityLabel("Batch actions")

            Button {
                if store.isRunning || store.isPreparingModel {
                    store.cancelBatch()
                } else {
                    store.startBatch()
                }
            } label: {
                if store.isPreparingModel {
                    ProgressView()
                        .controlSize(.small)
                }
                Label(
                    store.isRunning || store.isPreparingModel ? "Cancel" : "Start",
                    systemImage: store.isRunning || store.isPreparingModel ? "stop.fill" : "play.fill"
                )
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .disabled(!store.isRunning && !store.isPreparingModel && !store.canStart)
            .help(store.isPreparingModel
                ? "Cancel the model check"
                : store.isRunning ? "Stop the batch" : "Start the queued files")
        }
    }
}
