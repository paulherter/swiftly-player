import SwiftUI
import struct SwiftlyCore.PlayerChapters

// The iPhone player's top bar (design option C, design/pille-und-filme.html): the title with a quiet line under it, and on the
// right ONE glass capsule (Folgen, subtitles, settings, hand over) and the X alone as a circle.

// MARK: - Press style

/// The three states a bar part wears besides "normal": pressed (instant), open (a menu hangs from it) and off.
/// Press answers at once and lets go over 0.12 s; with reduced motion nothing scales.
private struct BarPress<S: Shape>: ButtonStyle {
    let shape: S
    let pressedScale: CGFloat
    let pressedFill: Color
    var open = false

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        configuration.label
            .background(shape.fill(pressed ? pressedFill : (open ? Theme.ringProgress : .clear)))
            .scaleEffect(pressed && !Theme.motionReduced ? pressedScale : 1)
            .animation(pressed ? nil : .easeOut(duration: 0.12), value: pressed)
            .animation(.easeOut(duration: 0.12), value: open)
    }
}

// MARK: - Glyph buttons

/// One symbol of the bar: a half of the capsule (44 x 40) or a circle (40 x 40). The symbol sits in a 19 pt frame
/// on Lucide's 24 grid, scaled optically per glyph; the stroke stays.
struct BarGlyphButton: View {
    enum Form { case half, circle }

    let symbol: String
    let label: LocalizedStringKey
    let form: Form
    let mass: PlayerMetric
    var open = false
    let action: () -> Void

    @Environment(\.isEnabled) private var enabled

    /// Optical size per symbol (design table "Optische Größe").
    private var optical: CGFloat {
        switch symbol {
        case "slider.horizontal.3": 1.04
        case "display": 0.92
        case "xmark": 1.16
        default: 1.0
        }
    }

    var body: some View {
        let size = CGSize(width: form == .half ? 44 : 40, height: 40)
        Button(action: action) {
            Image(icon: symbol, size: 19)
                .font(.app(size: 19, weight: Theme.overlayWeight))
                .foregroundStyle(Theme.font)
                .scaleEffect(optical)
                .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
                .frame(width: 19, height: 19)
                .frame(width: size.width, height: size.height)
                .contentShape(Rectangle().inset(by: -2))
        }
        .buttonStyle(BarPress(shape: RoundedRectangle(cornerRadius: 20, style: .continuous),
                              pressedScale: 0.92, pressedFill: Theme.selected, open: open))
        .opacity(enabled ? 1 : 0.35)
        .accessibilityLabel(Text(label))
    }
}

/// **The X of the player, once.** Glass circle (40 x 40) with the bar's X glyph. The bar, the layers' header and the
/// start veil all use this, so the X never changes look or place between loading, playing and an open layer.
struct PlayerCloseButton: View {
    let mass: PlayerMetric
    var label: LocalizedStringKey = "Player schließen"
    let action: () -> Void

    var body: some View {
        BarGlyphButton(symbol: "xmark", label: label, form: .circle, mass: mass, action: action)
            .playerGlass(Circle())
    }
}

// MARK: - Right side

/// **One capsule + the X** (design option C, pille-und-filme): Folgen (series, or a film with chapters), subtitles,
/// settings and hand over share one capsule; close stands alone as a circle. Without hand over (no TV, or in a group) or
/// without Folgen the capsule is simply shorter.
struct BarRail<Handover: View>: View {
    let mass: PlayerMetric
    let showFolgen: Bool
    let folgenOpen: Bool
    let tracksOpen: Bool
    let settingsOpen: Bool
    let folgen: () -> Void
    let tracks: () -> Void
    let settings: () -> Void
    let close: () -> Void
    @Binding var anchors: PlayerMenuAnchors
    @ViewBuilder let handover: Handover

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 0) {
                if showFolgen {
                    BarGlyphButton(symbol: "rectangle.stack", label: "Folgen", form: .half,
                                   mass: mass, open: folgenOpen, action: folgen)
                        .folgenAnchor(into: $anchors)
                }
                BarGlyphButton(symbol: "captions", label: "Audio & Untertitel", form: .half,
                               mass: mass, open: tracksOpen, action: tracks)
                    .menuAnchor(.tracks, into: $anchors)
                BarGlyphButton(symbol: "slider.horizontal.3", label: "Einstellungen", form: .half,
                               mass: mass, open: settingsOpen, action: settings)
                    .menuAnchor(.settings, into: $anchors)
                handover
            }
            .playerGlass(Capsule())
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { anchors.capsule = $0 }
            PlayerCloseButton(mass: mass, action: close)
        }
        // Centered on the title line: the glass is 40 high, the title 24, and starts 8 above it.
        .frame(height: 40)
    }
}
