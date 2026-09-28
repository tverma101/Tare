import SwiftUI
import TranscriberCore

/// How one job's state is presented, in one place.
///
/// Every call site reads from here, so a state cannot drift between the sidebar,
/// the table, and the inspector. `title` is a non-optional `String`, which makes
/// rendering a state without its label unrepresentable, and each state pairs a
/// distinct symbol shape with text so the meaning survives greyscale,
/// colour-blindness, and Increase Contrast.
struct StatePresentation {
    let symbol: String
    let title: String
    let detail: String?
    let tint: Color
    let isBusy: Bool
    let isBlocked: Bool

    init(
        symbol: String,
        title: String,
        detail: String? = nil,
        tint: Color,
        isBusy: Bool = false,
        isBlocked: Bool = false
    ) {
        self.symbol = symbol
        self.title = title
        self.detail = detail
        self.tint = tint
        self.isBusy = isBusy
        self.isBlocked = isBlocked
    }

    static func forJob(_ job: TranscriptionJob) -> StatePresentation {
        let foundNoSpeech = job.status == .completed && (job.transcript?.segments.isEmpty ?? false)

        switch job.status {
        case .queued:
            return StatePresentation(
                symbol: "film",
                title: "Queued",
                tint: Palette.idle
            )
        case .extractingAudio:
            return StatePresentation(
                symbol: "waveform",
                title: "Extracting audio",
                tint: Palette.active,
                isBusy: true
            )
        case .transcribing:
            return StatePresentation(
                symbol: "waveform",
                title: "Transcribing",
                detail: chunkDetail(job),
                tint: Palette.active,
                isBusy: true
            )
        case .exporting:
            return StatePresentation(
                symbol: "square.and.arrow.down",
                title: "Exporting",
                tint: Palette.active,
                isBusy: true
            )
        case .completed where foundNoSpeech:
            return StatePresentation(
                symbol: "waveform.slash",
                title: "No speech found",
                detail: "Silent source; nothing to transcribe",
                tint: Palette.warning
            )
        case .completed:
            return StatePresentation(
                symbol: "checkmark.circle.fill",
                title: "Completed",
                tint: Palette.success
            )
        case .cancelled:
            return StatePresentation(
                symbol: "stop.circle.fill",
                title: "Cancelled",
                detail: "Stopped before finishing",
                tint: Palette.neutral
            )
        case .failed:
            return StatePresentation(
                symbol: "xmark.octagon.fill",
                title: "Failed",
                detail: job.errorMessage,
                tint: Palette.danger
            )
        }
    }

    private static func chunkDetail(_ job: TranscriptionJob) -> String? {
        guard let chunks = job.chunkProgress, chunks.total > 1 else { return nil }
        return "Chunk \(chunks.completed) of \(chunks.total)"
    }

    /// The symbol, rendered once so every surface draws it identically.
    func symbolView(size: CGFloat = Metric.stateIconSize) -> some View {
        Image(systemName: symbol)
            .font(.system(size: size))
            .symbolVariant(.fill)
            .foregroundStyle(tint)
            .accessibilityHidden(true)
    }
}

/// The app-level phase, used by the status header and strip.
enum AppPhase {
    case idle
    case preflighting
    case running
    case working

    @MainActor
    static func resolve(_ store: TranscriptionStore) -> AppPhase {
        if store.isPreparingModel { return .preflighting }
        if store.isRunning { return .running }
        if store.isScanning || store.isOrganizing { return .working }
        return .idle
    }

    var presentation: StatePresentation {
        switch self {
        case .idle:
            return StatePresentation(symbol: "circle.dotted", title: "Idle", tint: Palette.neutral)
        case .preflighting:
            return StatePresentation(
                symbol: "checklist",
                title: "Checking the model",
                tint: Palette.active,
                isBusy: true
            )
        case .running:
            return StatePresentation(symbol: "waveform", title: "Running", tint: Palette.active, isBusy: true)
        case .working:
            return StatePresentation(
                symbol: "folder.badge.gearshape",
                title: "Working",
                tint: Palette.active,
                isBusy: true
            )
        }
    }
}
