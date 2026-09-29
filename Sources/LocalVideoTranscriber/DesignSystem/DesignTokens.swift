import AppKit
import SwiftUI

// MARK: - Spacing
//
// A 4pt base with two non-scale additions. Nothing outside this enum.
enum Space {
    /// Optical nudge inside a single line of text. Never between views.
    static let optical: CGFloat = 2
    /// Icon-to-label, chip internals, table cell internals.
    static let tight: CGFloat = 4
    /// Default gap between siblings inside one group.
    static let close: CGFloat = 8
    /// Gap between groups, and the padding inside a GroupBox.
    static let group: CGFloat = 12
    /// The page gutter. One value for the whole app.
    static let page: CGFloat = 16
}

// MARK: - Radii
enum Radius {
    /// Small bordered wells: text editors, inline code.
    static let inline: CGFloat = 4
    /// Matches AppKit's control corner radius.
    static let control: CGFloat = 5
    /// Only for containers that are not a GroupBox.
    static let card: CGFloat = 8
}

// MARK: - Metrics
enum Metric {
    static let hairline: CGFloat = 1

    // Controls
    static let controlHeight: CGFloat = 22
    static let controlHeightSmall: CGFloat = 16
    static let controlHeightLarge: CGFloat = 28

    // Rows
    static let rowHeight: CGFloat = 24
    static let rowHeightTwoLine: CGFloat = 32

    // Transcribe split view
    static let sidebarMin: CGFloat = 200
    static let sidebarIdeal: CGFloat = 240
    static let sidebarMax: CGFloat = 300
    static let detailMin: CGFloat = 520
    static let detailIdeal: CGFloat = 760

    // Page chrome
    static let contentMaxWidth: CGFloat = 860
    static let headerHeight: CGFloat = 44
    static let statusStripHeight: CGFloat = 28

    // Progress
    static let progressBarHeight: CGFloat = 4
    static let stateIconSize: CGFloat = 13
    static let percentTextWidth: CGFloat = 30
    static let chunkTextWidth: CGFloat = 56
    static let batchCounterWidth: CGFloat = 56

    // Table columns
    static let stateColumnWidth: CGFloat = 22
    static let nameColumnMin: CGFloat = 180
    static let nameColumnIdeal: CGFloat = 320
    static let typeColumnWidth: CGFloat = 46
    static let lengthColumnWidth: CGFloat = 58
    static let progressColumnMin: CGFloat = 132
    static let progressColumnIdeal: CGFloat = 168
    static let progressColumnMax: CGFloat = 220
    static let elapsedColumnWidth: CGFloat = 56
    static let outputsColumnWidth: CGFloat = 76
    static let noteColumnMin: CGFloat = 120
    static let noteColumnIdeal: CGFloat = 240

    // Queue workspace: the table keeps a usable floor, the job detail below it
    // keeps enough room to read.
    static let tableMinHeight: CGFloat = 170
    static let jobDetailMinHeight: CGFloat = 200
}

// MARK: - Palette
//
// Every colour is a resolved AppKit semantic colour, so light and dark appearance
// and Increase Contrast are handled by the system with no per-appearance code.
//
// The accent is deliberately NOT overridden. AppKit draws focus rings and native
// selection in the system accent colour, not Color.accentColor, so overriding it
// desynchronises SwiftUI selection from AppKit focus rings.
enum Palette {
    static let accent = Color.accentColor

    // Text
    static let textPrimary = Color(nsColor: .labelColor)
    static let textSecondary = Color(nsColor: .secondaryLabelColor)
    static let textTertiary = Color(nsColor: .tertiaryLabelColor)

    // Surfaces
    static let pageBackground = Color(nsColor: .windowBackgroundColor)
    static let contentBackground = Color(nsColor: .controlBackgroundColor)
    static let textWellBackground = Color(nsColor: .textBackgroundColor)
    static let hairline = Color(nsColor: .separatorColor)

    // State. Each is only ever used alongside a StatePresentation symbol and its
    // required text, so colour is never the sole carrier of meaning.
    static let success = Color(nsColor: .systemGreen)
    static let active = Color.accentColor
    static let danger = Color(nsColor: .systemRed)
    static let warning = Color(nsColor: .systemOrange)
    static let neutral = Color(nsColor: .secondaryLabelColor)
    static let idle = Color(nsColor: .tertiaryLabelColor)

    // Fills
    static let warningFill = Color(nsColor: .systemOrange).opacity(0.12)
    static let dangerFill = Color(nsColor: .systemRed).opacity(0.12)
    static let accentFill = Color.accentColor.opacity(0.12)
    static let progressTrack = Color(nsColor: .quaternaryLabelColor).opacity(0.35)
    static let progressTerminal = Color(nsColor: .quaternaryLabelColor).opacity(0.70)
}

// MARK: - Typography
//
// .caption and .footnote are both 10pt on macOS. They are still separate roles
// so a call site states its intent, with the difference carried by hierarchical
// style rather than point size.
enum Typography {
    static let pageTitle = Font.title2.weight(.semibold)
    static let paneTitle = Font.title3.weight(.medium)
    static let sectionHeader = Font.system(size: 13, weight: .semibold)
    static let rowTitle = Font.subheadline
    static let rowTitleEmphasized = Font.subheadline.weight(.semibold)
    static let keyValue = Font.callout
    static let body = Font.body
    static let metadata = Font.caption
    static let caption = Font.caption
    static let footnote = Font.caption

    /// Model IDs, file paths, key suffixes. Hugging Face IDs run long and the
    /// distinguishing part is the tail.
    static let mono = Font.system(size: 10, design: .monospaced)

    /// Anything whose width changes as its digits change. Must be paired with a
    /// fixed-width frame or the layout will jitter.
    static let monoDigit = Font.system(size: 10).monospacedDigit()
    static let monoDigitProminent = Font.system(size: 12, weight: .medium).monospacedDigit()
    static let monoInline = Font.caption.monospaced()
}

// MARK: - Motion
enum Motion {
    /// The only animation in the app.
    static let progressFill = Animation.linear(duration: 0.25)
    static let quick = Animation.easeOut(duration: 0.15)

    /// Single choke point for accessibilityReduceMotion.
    static func resolved(_ animation: Animation?, reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : animation
    }
}
