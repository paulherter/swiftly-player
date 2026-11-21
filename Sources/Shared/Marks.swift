import JellyfinKit
import SwiftUI

/// The marks as vector paths, unchanged from the SVG templates.
///
/// The strings are deliberately **not** wrapped. A line break in the middle
/// of a number turns "2.37" into the two numbers "2." and "37", and the
/// path then collapses into a few points without any error appearing.
enum Mark {

    static let emblemBox = CGRect(x: 0, y: 0, width: 1024, height: 1024)
    /// The play shape slightly larger than in the template, around its own
    /// center. The same value is in the app icon.
    static let emblemMagnifier: CGFloat = 1.14

    /// Corner radius of the symbol, as a fraction of its edge length.
    static let emblemCorner: CGFloat = 230.0 / 1024

    /// The template's colors. Deliberately own values and not `Theme.accent`:
    /// the mark is fixed, and the app's appearance may move independently of
    /// it.
    /// **The same tone as `Theme.accent`.** Before, this had its own value and
    /// the app had two turquoises: the mark #2FDBC0, the interface #5CD1C2.
    /// Whoever changes the accent changes the mark with it.
    static let markAccent = Color(red: 0.314, green: 0.835, blue: 0.855)   // #50D5DA
    static let markArea = Color(red: 0.090, green: 0.094, blue: 0.106)  // #17181B

    /// The play shape in the app mark.
    static let emblemForm = "M440.1,280l285,163.2c38,21.7,51.2,70,29.6,108-7,12.3-17.2,22.5-29.6,29.6l-285,163.2c-37.9,21.8-86.3,8.6-108.1-29.3-6.9-12-10.5-25.6-10.5-39.4v-326.6c0-43.7,35.5-79.2,79.2-79.2,13.8,0,27.4,3.6,39.4,10.5Z"
}

// MARK: - Views

/// The app icon as the first-start and sign-in pages show it above their question.
///
/// The shipped icon's own picture (`AppIconPreview-Standard` in each platform's catalog),
/// never redrawn: square on iPhone, iPad and Mac, 5:3 on Apple TV, where the icon is
/// landscape. The picture has square corners, so the rounding is applied here.
struct AppIconMark: View {
    /// Height of the icon; the width follows the picture.
    var height: CGFloat = 40
    /// `nil` rounds like the app icon does (`Mark.emblemCorner` of the height).
    var corner: CGFloat?

    var body: some View {
        Image("AppIconPreview-Standard")
            .resizable()
            .scaledToFit()
            .frame(height: height)
            .clipShape(RoundedRectangle(cornerRadius: corner ?? height * Mark.emblemCorner,
                                        style: .continuous))
            .accessibilityLabel("Swiftly")
    }
}

/// The symbol: rounded square with the play shape.
///
/// Flat and without extras, just like the template. The surface is a
/// rounded rectangle instead of a path so the corner stays clean at any
/// size.
struct Emblem: View {
    var size: CGFloat = 64

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * Mark.emblemCorner, style: .continuous)
                .fill(Mark.markArea)
            SVGForm(data: Mark.emblemForm, box: Mark.emblemBox)
                .fill(LookStore.shared.palette.logoStyle)
                // Around the center of the shape, not that of the square: a play shape
                // deliberately sits slightly to the right of it.
                .scaleEffect(Mark.emblemMagnifier,
                             anchor: UnitPoint(x: (322 + 755) / 2 / 1024,
                                               y: (270 + 744) / 2 / 1024))
        }
        .frame(width: size, height: size)
        .accessibilityLabel("Swiftly")
    }
}
