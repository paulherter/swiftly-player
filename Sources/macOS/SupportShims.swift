import SwiftUI

// **The few things the shared supporter views take from the iOS style, in Mac form.**
// `SupportGrowSheet` and `SupportProfileParts` are the same files as on iPhone; the Mac
// has its own `Style.swift`, so what they call and it lacks is defined here (no haptics,
// no Dynamic Type, buttons in the Mac look).

extension View {
    /// The Mac has no Dynamic Type: a fixed size.
    func growing(_ size: CGFloat, _ weight: Font.Weight = .regular) -> some View {
        font(.system(size: size, weight: weight))
    }
}

extension Theme {
    enum JerkKind { case lightweight, medium }

    /// No haptics on the Mac.
    @MainActor
    static func jerk(_ art: JerkKind) {}
}

struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var released
    var stretches = true
    var lockedArea: Color = Theme.area

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(released ? Theme.onAccent : Theme.fontVeryQuiet)
            .padding(.horizontal, stretches ? 0 : 28)
            .frame(maxWidth: stretches ? .infinity : nil, minHeight: 44)
            .background(released ? Color.white.opacity(configuration.isPressed ? 0.75 : 1) : lockedArea,
                        in: RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var released
    var stretches = true
    var accent = false
    var area: Color = Theme.area

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(released ? (accent ? Theme.accent : Theme.font) : Theme.fontVeryQuiet)
            .padding(.horizontal, stretches ? 0 : 22)
            .frame(maxWidth: stretches ? .infinity : nil, minHeight: 44)
            .background(configuration.isPressed ? Theme.font.opacity(0.14) : area,
                        in: RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
    }
}

extension View {
    /// The shared views ask for the app's flush bottom sheet; on the Mac that is a window
    /// sheet 480 pt wide (Escape closes it, as with every system sheet).
    func sheet<ContentBody: View>(opened: Binding<Bool>, dimmed: Bool = true, light: Color? = nil,
                                  lightTint: Color? = nil,
                                  @ViewBuilder content: @escaping () -> ContentBody) -> some View {
        sheet(isPresented: opened) {
            content()
                .frame(width: 480)
                .background(Theme.area)
                .presentationBackground(Theme.area)
        }
    }
}

extension Theme {
    /// Press via opacity only, as on iPhone.
    struct PressText: ButtonStyle {
        var active = true
        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .background(Theme.font.opacity(!active && configuration.isPressed ? 0.06 : 0))
                .opacity(active && configuration.isPressed ? 0.6 : 1)
        }
    }
}
