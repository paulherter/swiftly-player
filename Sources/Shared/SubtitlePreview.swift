import JellyfinKit
import SwiftUI

// **The subtitle look page: what all three Apple versions share.** The page itself (rows,
// segments, focus) is per platform; the preview and the words are here, so the same look
// reads the same everywhere. The numbers follow the spec (`Notizen/Mehrserver/
// UNTERTITEL-ENTWURF.md`, section 5) and how VLC calculates them; they have **not** been
// compared with VLC's own drawing yet (spec section 11, point 1).

// MARK: - Words

extension SubtitleLook.Size {
    var name: String {
        switch self {
        case .small: String(localized: "Klein")
        case .normal: String(localized: "Normal")
        case .large: String(localized: "Groß")
        case .huge: String(localized: "Sehr groß")
        }
    }

    /// The "A" of the segment, growing with the step (spec section 3, row 1).
    var glyphSize: CGFloat {
        switch self { case .small: 12; case .normal: 15; case .large: 17; case .huge: 20 }
    }
}

extension SubtitleLook.Colour {
    var name: String {
        switch self {
        case .white: String(localized: "Weiß")
        case .yellow: String(localized: "Gelb")
        case .grey: String(localized: "Grau")
        }
    }

    var color: Color {
        Color(red: Double((rgb >> 16) & 255) / 255, green: Double((rgb >> 8) & 255) / 255,
              blue: Double(rgb & 255) / 255)
    }
}

extension SubtitleLook.Outline {
    var name: String {
        switch self {
        case .off: String(localized: "Aus")
        case .thin: String(localized: "Dünn")
        case .normal: String(localized: "Normal")
        }
    }
}

extension SubtitleLook.Position {
    var name: String {
        switch self {
        case .bottom: String(localized: "Unten")
        case .raised: String(localized: "Höher")
        }
    }
}

extension SubtitleLook {
    /// The value of the entry row ("Aussehen der Untertitel").
    var entryValue: String {
        isStandard ? String(localized: "Standard") : String(localized: "Eigenes")
    }

    /// The whole setting as one sentence, for VoiceOver on the preview (spec section 8).
    var sentence: String {
        [
            size.name,
            colour.name,
            outline == .off ? String(localized: "ohne Rand")
                : outline == .thin ? String(localized: "Rand dünn") : String(localized: "Rand normal"),
            shadow ? String(localized: "mit Schatten") : String(localized: "ohne Schatten"),
            background ? String(localized: "mit Hintergrund") : String(localized: "ohne Hintergrund"),
            position == .bottom ? String(localized: "unten") : String(localized: "höher"),
        ].joined(separator: ", ")
    }

    /// The line under the file switch: it says what applies **now** (spec section 3).
    var fileStyleLine: String {
        keepFileStyle
            ? String(localized: "Bei ASS und SSA bestimmt die Datei Schrift, Farbe und Position. Schilder und Karaoke bleiben im Bild.")
            : String(localized: "Auch ASS und SSA sehen dann aus wie oben. Schilder rutschen als Zeile nach unten.")
    }
}

// MARK: - Size of the picture

extension SubtitleStyle {
    /// **The picture height the player's text is sized against, in points.** The preview
    /// draws at this height, not at its own, so "Normal" is as big here as in the player
    /// (spec section 5: iPhone the short side, Mac the visible screen, TV 1080).
    @MainActor static var previewHeight: CGFloat {
        #if os(tvOS)
        1080
        #elseif canImport(UIKit)
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let bounds = scenes.first?.screen.bounds ?? CGRect(x: 0, y: 0, width: 393, height: 852)
        return min(bounds.width, bounds.height)
        #else
        NSScreen.main?.visibleFrame.height ?? 900
        #endif
    }

    /// Point size of the text for a look: height x 6.25 % x base x step.
    @MainActor static func previewPoints(for look: SubtitleLook) -> CGFloat {
        previewHeight * 0.0625
            * CGFloat(SubtitleLook.textScalePercent(look: look, baseScale: Double(baseScale))) / 100
    }
}

// MARK: - Preview

/// **The picture with the subtitle, drawn by the app, not by VLC.** A player with a looping
/// clip would cost battery and a second of start-up for a settings page. The price is that
/// the drawing can differ from VLC's; that is what the measurement in spec section 11 is for.
///
/// The text is drawn like VLC calculates it: outline = step percent of the text height in
/// black at 230/255, shadow = black 160/255, 4 percent of the height straight down, hard,
/// background = black 160/255 as a box per line with a quarter of the height around it, no
/// rounded corners. "Higher" lifts the text by 7 percent of the picture height.
struct SubtitlePreview: View {
    let look: SubtitleLook
    var cornerRadius: CGFloat = 16

    /// Gap above the picture's lower edge for "Bottom": VLC's own margin (16 px).
    private static let bottomGap: CGFloat = 16

    var body: some View {
        let points = SubtitleStyle.previewPoints(for: look)
        let lift = look.position == .raised ? SubtitleStyle.previewHeight * 0.07 : 0
        PreviewLayout(lift: lift) {
            picture
            text(points: points)
                .offset(y: -lift)
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .animation(Motion.change, value: look)
        // One element: the text itself is part of the picture and is not read.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Vorschau"))
        .accessibilityValue(look.sentence)
    }

    /// The picture from the bundle. Missing, a gradient with a light strip stands in,
    /// never an empty surface (spec section 6).
    private var picture: some View {
        ZStack {
            LinearGradient(colors: [Color(white: 0.063), Color(white: 0.227)], startPoint: .top, endPoint: .bottom)
            VStack(spacing: 0) {
                Spacer()
                Color(white: 0.75).opacity(0.5).frame(height: 40)
                Color(white: 0.05).frame(height: 30)
            }
            Image("subtitle-preview")
                .resizable()
                .scaledToFill()
        }
        .clipped()
    }

    private func text(points: CGFloat) -> some View {
        VStack(spacing: 0) {
            line(String(localized: "Hörst du das auch?"), points: points)
            line(String(localized: "Da hinten am See."), points: points)
        }
        .padding(.bottom, Self.bottomGap)
    }

    /// One line: shadow, outline and the glyphs themselves, on their box.
    private func line(_ string: String, points: CGFloat) -> some View {
        let font = Font.custom(SubtitleStyle.fontName, fixedSize: points)
        let radius = points * CGFloat(look.outline.thickness) / 100
        let glyphs = Text(string).font(font).foregroundStyle(look.colour.color)
        let ink = Text(string).font(font).foregroundStyle(Color.black)
        return ZStack {
            if look.shadow {
                ZStack {
                    if look.outline != .off { ring(ink, radius: radius) } else { ink }
                }
                .compositingGroup()
                .opacity(160.0 / 255)
                .offset(y: points * 0.04)
            }
            if look.outline != .off {
                ring(ink, radius: radius)
                    .compositingGroup()
                    .opacity(230.0 / 255)
            }
            glyphs
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, look.background ? points / 4 : 0)
        .padding(.vertical, look.background ? points / 8 : 0)
        .background(look.background ? Color.black.opacity(160.0 / 255) : .clear)
    }

    /// The outline: the text copied around a circle.
    private func ring(_ ink: Text, radius: CGFloat) -> some View {
        ZStack {
            ForEach(0..<12, id: \.self) { step in
                let angle = Double(step) / 12 * 2 * .pi
                ink.offset(x: radius * CGFloat(cos(angle)), y: radius * CGFloat(sin(angle)))
            }
        }
    }
}

/// **16:9 at least, taller when the text does not fit** (spec section 5: "Sehr groß" on a
/// wide screen wraps like in the player; the picture grows instead of cutting the text).
private struct PreviewLayout: Layout {
    let lift: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 360
        let text = subviews[1].sizeThatFits(ProposedViewSize(width: width, height: nil))
        return CGSize(width: width, height: max(width * 9 / 16, (text.height + lift) / 0.85))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews[0].place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
        let text = subviews[1].sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
        // **Centred on its own width.** The text block is narrower than the picture; placed at
        // `minX` with the default top-leading anchor it sat at the left edge.
        subviews[1].place(at: CGPoint(x: bounds.midX, y: bounds.maxY - text.height), anchor: .top,
                          proposal: ProposedViewSize(width: bounds.width, height: text.height))
    }
}
