import SwiftUI

/// A message that lives in the window instead of in an alert, so nothing steals
/// focus or covers the work. Shown where the problem is.
struct InlineNotice<Actions: View>: View {
    enum Kind { case error, warning, info }

    let kind: Kind
    let title: String
    let message: String?
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        HStack(alignment: .top, spacing: Space.group) {
            Image(systemName: symbol)
                .font(.system(size: 16))
                .foregroundStyle(tint)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: Space.tight) {
                Text(title)
                    .font(Typography.rowTitleEmphasized)

                if let message {
                    Text(message)
                        .font(Typography.caption)
                        .foregroundStyle(Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }

            Spacer(minLength: Space.group)

            HStack(spacing: Space.close) {
                actions()
            }
        }
        .padding(Space.group)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(fill, in: RoundedRectangle(cornerRadius: Radius.card))
        .accessibilityElement(children: .contain)
    }

    private var symbol: String {
        switch kind {
        case .error: return "xmark.octagon.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .info: return "info.circle.fill"
        }
    }

    private var tint: Color {
        switch kind {
        case .error: return Palette.danger
        case .warning: return Palette.warning
        case .info: return Palette.active
        }
    }

    private var fill: Color {
        switch kind {
        case .error: return Palette.dangerFill
        case .warning: return Palette.warningFill
        case .info: return Palette.accentFill
        }
    }
}
