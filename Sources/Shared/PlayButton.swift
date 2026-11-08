import SwiftUI

/// The mark's play shape on its own, cropped to its bounds (from the emblem's path).
struct PlayTriangle: View {
    var width: CGFloat = 10
    var height: CGFloat = 11

    var body: some View {
        SVGForm(data: Mark.emblemForm, box: CGRect(x: 322, y: 270, width: 433, height: 474))
            .frame(width: width, height: height)
            .accessibilityHidden(true)
    }
}

/// **The purchase and look screens' main button:** accent surface, label on the left, the
/// play triangle on the right. Height 50 (44 compact), corner 10.
struct PlayButtonStyle: ButtonStyle {
    var compact = false
    /// What the disabled button sits on.
    var lockedArea: Color = Theme.raised
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 12) {
            configuration.label
                .font(.app(size: compact ? 15 : 17, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: compact ? nil : .infinity, alignment: .leading)
            PlayTriangle(width: compact ? 9 : 10, height: compact ? 10 : 11)
                .opacity(enabled ? 1 : 0.4)
        }
        .foregroundStyle(enabled ? Theme.onAccent : Theme.fontVeryQuiet)
        .padding(.leading, compact ? 18 : 20)
        .padding(.trailing, compact ? 16 : 18)
        .frame(maxWidth: compact ? nil : .infinity, minHeight: compact ? 44 : 50)
        .background(enabled ? Theme.accent.opacity(configuration.isPressed ? 0.84 : 1) : lockedArea,
                    in: RoundedRectangle(cornerRadius: compact ? 22 : Theme.corner, style: .continuous))
        .scaleEffect(configuration.isPressed && !Theme.motionReduced ? 0.97 : 1)
        .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
        .contentShape(Rectangle())
    }
}
