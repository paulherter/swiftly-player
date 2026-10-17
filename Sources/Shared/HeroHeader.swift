import JellyfinKit
import SwiftUI

/// The header of the detail pages in the **wide** version, composed
/// horizontally.
///
/// On iPhone the hero image sits on top and everything else below it; at 390 pt
/// width there is no other option. Once there is width, that is the wrong
/// arrangement: a 300 pt strip across 1000 pt is no longer a hero image but a
/// letterbox slot, and the text below runs to a line length nobody reads.
///
/// This layout is taken from **TV**, where it proved itself
/// (`Sources/tvOS/DetailView.swift`): the image fills the area as background,
/// poster and text block stand side by side, all left-aligned at the bottom. Two
/// scrims make it legible: one from the left for the text, one from below for the
/// buttons. Without the left one, white text ends up on a bright sky sooner or
/// later.
///
/// The nice side effect: **the poster sets the measure.** The text block is as
/// wide as what remains beside a 168 pt poster, so no invented reading column is
/// needed to keep the lines short.
///
/// The height is based on the content, not the screen: poster 252 plus 40 below
/// plus air. On TV the hero image fills the full 1080 pt and that works there; on
/// an iPad full height would only mean scrolling to reach the description.
///
/// It is deliberately its own component: the movie and series pages share this
/// header. Written twice, it would have to be changed twice.
struct HeroHeader<ContentBody: View>: View {
    let image: URL?
    let poster: URL?
    let title: String
    /// Logo address for "title as logo"; `nil`: always the text.
    var logo: URL?
    let secondaryLine: String
    /// Share already watched, as a bar at the bottom edge of the poster.
    ///
    /// There and not in the button, the same decision as on TV: "Resume from 51:10"
    /// wraps and throws the button row off. This app shows progress as a bar
    /// everywhere anyway.
    var progress: Double?
    /// Detail line, buttons, action row: what stands under the title is decided by
    /// the page.
    @ViewBuilder var content: () -> ContentBody
    /// **Is the color of the header image under the page?** Then the header does not
    /// paint its scrims in `reason` but fades the image out with a mask, so what lies
    /// underneath, the ``Stimmungsgrund``, shows through. The same computation as the
    /// backdrop on the Mac (`BackdropsFade`): a paint presupposes that `reason` is
    /// behind it.
    @Environment(\.onImageTint) private var onImage

    var body: some View {
        HStack(alignment: .bottom, spacing: 32) {
            Picture(url: poster,
                 width: Theme.heroPosterWidth, height: Theme.heroPosterHeight,
                 corner: Theme.cornerTile, progress: progress) {
                Theme.area.overlay {
                    Image(systemName: "film").foregroundStyle(Theme.fontVeryQuiet)
                }
            }
            // **The poster says nothing that is not stated beside it.**
            //
            // It had no treatment so far, which for VoiceOver is an empty area in the middle
            // of every detail page. Two ways were possible; this is the right one: the title
            // stands right next to it, and the poster would only repeat it as an image. What
            // it additionally carries is the progress bar, and that is a drawing *in* the
            // image and so was missing entirely. It moves to the title, where it is read.
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 0) {
                // **Title and subtitle as one statement, the buttons not.**
                //
                // Exactly the pattern from `HomeView.Tile`, found by the tvOS side; here it
                // was never adopted. `content()` stays outside on purpose: those are buttons, and
                // each must be reachable individually.
                VStack(alignment: .leading, spacing: 0) {
                    TitleMark(title: title, logo: logo, slot: .column)
                        // **The title over a hero image *is* the page title.** The same level as
                        // "Settings", and iPad and Mac carry it 1:1 like the iPhone. Before: 40 bold
                        // with −1, a separate level for a role that already had one, and thus the spot
                        // where the wide version started a second design. Tracking stays at −0.021 em,
                        // computed at 28: the same −0.6 as on the movie and series pages.
                        // The title mark carries the same font, tracking and two lines; with "title as
                        // logo" the logo takes its place.
                    Text(secondaryLine)
                        // Year, seasons and genre count as one entry, which is 12 on the scale. It used
                        // to be 14, a number that appears in no step.
                        .font(Theme.small)
                        .foregroundStyle(Theme.fontQuiet)
                        .lineLimit(1)
                        .padding(.top, 8)
                }
                .accessibilityElement(children: .combine)
                // Only from one percent: "zero percent watched" is no information, just noise
                // in front of every title.
                .accessibilityValue(progress.map {
                    Text("\(Int($0 * 100)) Prozent gesehen")
                } ?? Text(""))

                content()
                    .padding(.top, 12)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.edgePageWide)
        .padding(.top, 40)
        .padding(.bottom, 40)
        // **Minimum height, not fixed.** 420 was computed for the horizontal button row.
        // Once it stacks (portrait, half window) the block is clearly taller, and a
        // fixed height cut it off: poster gone at the bottom, buttons completely. Now the
        // header grows with its content and keeps 420 only as a lower bound so some of
        // the image stays visible.
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(minHeight: Theme.heroHeightWide, alignment: .bottom)
        // As background and not as a sibling in the stack: a background never takes part
        // in determining its host's size. The header had choked on exactly that before.
        .background { background }
        .clipped()
    }

    @ViewBuilder
    private var background: some View {
        if onImage {
            // The same steps as below, only as transparency: where `reason` lies there with
            // opacity a, the image shows 1 − a here.
            NetworkImage(url: image, preRank: true)
                .mask {
                    LinearGradient(stops: [
                        .init(color: .black.opacity(0.04), location: 0),
                        .init(color: .black.opacity(0.18), location: 0.32),
                        .init(color: .black.opacity(0.82), location: 0.62),
                        .init(color: .black,               location: 1),
                    ], startPoint: .leading, endPoint: .trailing)
                }
                .mask {
                    LinearGradient(stops: [
                        .init(color: .clear,               location: 0),
                        .init(color: .black.opacity(0.05), location: 0.26),
                        .init(color: .black.opacity(0.28), location: 0.44),
                        .init(color: .black.opacity(0.70), location: 0.60),
                        .init(color: .black,               location: 0.78),
                    ], startPoint: .bottom, endPoint: .top)
                }
                .allowsHitTesting(false)
        } else {
            painted
        }
    }

    private var painted: some View {
        ZStack {
            Theme.reason
            // **Still not `Picture`, but now `NetworkImage`.**
            //
            // `Picture` is a tile image: it measures itself against a width, rounds corners and
            // crops. The hero image should fill the area edge to edge and has no aspect
            // ratio to hold on to; with `Picture` it slid left and broke off abruptly, and in a
            // narrow window it disappeared entirely. `NetworkImage` draws exactly what is needed
            // here: a filling image without frame, corners or crop.
            //
            // **`AsyncImage` stood here until recently, the only place in the app.** The
            // banner at the top loaded noticeably slowly. Three reasons, all fixed by the
            // same change: it decoded on the main thread, and this is the largest area on
            // the page, so the most expensive image; it remembered nothing, so everything ran
            // again on every return; and it showed up in no measurement because the
            // measurement lives in our own loader.
            //
            // `vorrang` skips the gate. The banner fills half the screen; while it is
            // missing, the page looks unfinished no matter how many posters are already
            // below. Queueing it behind twenty tiles would turn the gate against its own
            // purpose.
            //
            // The soft fade-in stays: `NetworkImage` brings it itself, with the same duration.
            // **Nothing appears abruptly.**
            NetworkImage(url: image, preRank: true)
            // From the left, so the text holds.
            LinearGradient(stops: [
                .init(color: Theme.reason.opacity(0.96), location: 0),
                .init(color: Theme.reason.opacity(0.82), location: 0.32),
                .init(color: Theme.reason.opacity(0.18), location: 0.62),
                .init(color: Theme.reason.opacity(0),    location: 1),
            ], startPoint: .leading, endPoint: .trailing)
            // From below, so the button row holds and the transition into the page below
            // does not cut off.
            LinearGradient(stops: [
                .init(color: Theme.reason,               location: 0),
                .init(color: Theme.reason.opacity(0.95), location: 0.26),
                .init(color: Theme.reason.opacity(0.72), location: 0.44),
                .init(color: Theme.reason.opacity(0.30), location: 0.60),
                .init(color: Theme.reason.opacity(0),    location: 0.78),
            ], startPoint: .bottom, endPoint: .top)
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Actions as a panel

/// Where the More button is. The panel hangs on it.
///
/// Via an anchor preference and not fixed coordinates: on movie and series pages
/// the button sits in button rows ending at different distances to the right, and
/// the row shifts with the label length ("Resume from 1:42:10" vs. "Play").
struct ActionAnchor: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil
    static func reduce(value: inout Anchor<CGRect>?,
                       nextValue: () -> Anchor<CGRect>?) {
        value = nextValue() ?? value
    }
}

extension View {
    /// Remembers this button as the attachment point for the action panel.
    func asActionAnchor() -> some View {
        anchorPreference(key: ActionAnchor.self, value: .bounds) { $0 }
    }
}

/// The same actions as in `ActionSheet`, but as a panel at the trigger.
///
/// At 1024 pt width a sheet from below is wrong: an entry would be 50 pt tall and
/// 1000 wide, and the way from the button to the bottom edge is the whole screen.
///
/// Three differences from the sheet, all with the same reason: the panel is small
/// and its trigger stays visible beside it:
/// - **all four corners** 12 instead of only the top ones,
/// - **no Cancel row**; tapping outside closes. A Cancel row is the grammar of a
/// sheet taking half the height,
/// - **30 percent dimming** instead of 55. A 320 pt box needs no half curtain.
///
/// Rows, hairlines, title size and colors are unchanged from the sheet.
struct ActionPanel: View {
    @Binding var opened: Bool
    let title: String
    let actions: [TitleAction]
    /// Frame of the trigger in the same space as this panel.
    let anchor: CGRect
    /// The space in which the panel may sit, so it does not run out of the window.
    let space: CGSize

    private static let width: CGFloat = 320
    private static let spacing: CGFloat = 12

    var body: some View {
        ZStack(alignment: .topLeading) {
            Rectangle()
                // `reason`, not raw black: the scrim is the page underneath, which is `#101010`.
                .fill(Theme.reason.opacity(0.30))
                .ignoresSafeArea()
                .onTapGesture { close() }

            panel
                .frame(width: Self.width)
                .offset(x: left, y: top)
        }
        .transition(.opacity)
        // The scrim closes on tap; with VoiceOver there is no tapping an area without
        // traits. `.escape` is the exit the system provides for it, as the player does.
        .accessibilityAction(.escape) { close() }
    }

    /// Right-aligned to the trigger, but never past the edge.
    private var left: CGFloat {
        let wished = anchor.maxX - Self.width
        return min(max(Theme.edgePageWide, wished),
                   space.width - Self.width - Theme.edgePageWide)
    }

    /// Below the trigger, unless there is no room left; then above.
    private var top: CGFloat {
        let height = 48 + CGFloat(actions.count) * 50
        let below = anchor.maxY + Self.spacing
        guard below + height > space.height - 24 else { return below }
        return max(24, anchor.minY - Self.spacing - height)
    }

    private var panel: some View {
        VStack(spacing: 0) {
            Text(title)
                // Subtitle of a sheet: 13 in `schriftLeise`. Semibold stood here without reason:
                // 13 is medium on the scale, semibold only starts at 15.
                .font(Theme.tile)
                .foregroundStyle(Theme.fontQuiet)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Theme.edgeSpacing)
                .padding(.top, 18)
                .padding(.bottom, 12)

            ForEach(Array(actions.enumerated()), id: \.element.id) { pair in
                if pair.offset > 0 {
                    // The same hairline as in `ActionSheet`: continuous.
                    SheetLine()
                }
                Button {
                    close()
                    pair.element.perform()
                } label: {
                    HStack(spacing: 14) {
                        Image(systemName: pair.element.symbol)
                            .font(.system(size: 17))
                            .frame(width: 20)
                            .accessibilityHidden(true)
                        pair.element.label
                            // Row of an action list: 15, as in `ActionSheet`. 16 is on no scale, and the
                            // same row in two sizes is exactly why the scale exists.
                            .font(Theme.body)
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(pair.element.cautionary ? Theme.warning : Theme.font)
                    .padding(.horizontal, Theme.edgeSpacing)
                    // **`minHeight`, not `height`.** The same bug as once with `Schalter`: a fixed
                    // height on a text line cuts the text off once someone enlarges the system font.
                    // The dimension remains the minimum.
                    .frame(minHeight: 50)
                    .contentShape(Rectangle())
                }
                .buttonStyle(Theme.PressRow())
            }
        }
        .background {
            RoundedRectangle(cornerRadius: Theme.cornerArea, style: .continuous).fill(Theme.area)
        }
        .overlay {
        }
    }

    private func close() {
        // The same spring as the sheets. It already existed as `Theme.sheetMotion`,
        // with the comment "otherwise four sheets would have four curves", and that is
        // exactly what had happened.
        withAnimation(Theme.sheetMotion) { opened = false }
    }
}
