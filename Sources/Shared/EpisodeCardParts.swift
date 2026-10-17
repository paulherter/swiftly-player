import JellyfinKit
import SwiftUI

// **What iPhone and TV share of the episode card** (``EpisodeCard``, variant
// C): the held transition, the frame between card and full image, the countdown
// ring and the gradient at the bottom right. Each platform draws the card
// itself, since focus and dimensions differ.

/// The next-episode card while it zooms into the picture. Held at the start
/// so it does not vanish with the offer that the transition removes.
struct CardsSwitch: Equatable {
    let episodeID: String
    let beginning = Date()
    /// Since when (from `beginning`) the first frame of the new episode is up.
    var imageSince: Double?
    var since: Double { Date().timeIntervalSince(beginning) }
}

/// **Shape of the card between card and full image**: size, corner, shadow.
/// Animatable, so the spring pulls the zoom frame by frame from the current
/// state. Sits on the button's content so press and focus lift the whole card
/// instead of being cut off at its mask.
struct CardsShape: ViewModifier, @MainActor Animatable {
    var zoom: Double
    let card: CGRect
    let whole: CGSize
    let corner: CGFloat

    var animatableData: Double {
        get { zoom }
        set { zoom = newValue }
    }

    func body(content: Content) -> some View {
        let r = EpisodeCard.frameRect(card: (card.minX, card.minY, card.width, card.height),
                                   whole: (whole.width, whole.height), zoom: zoom)
        let rest = 1 - zoom
        content
            .frame(width: r.b, height: r.h)
            .clipShape(RoundedRectangle(cornerRadius: corner * rest, style: .continuous))
            .shadow(color: .black.opacity(0.6 * rest), radius: 17 * rest, y: 14 * rest)
    }
}

/// **Position of the card** via spacing, not `offset`: focus on TV and the
/// hit test on iPhone follow the position in the layout.
struct CardsStatus: ViewModifier, @MainActor Animatable {
    var zoom: Double
    let card: CGRect
    let whole: CGSize

    var animatableData: Double {
        get { zoom }
        set { zoom = newValue }
    }

    func body(content: Content) -> some View {
        let r = EpisodeCard.frameRect(card: (card.minX, card.minY, card.width, card.height),
                                   whole: (whole.width, whole.height), zoom: zoom)
        content
            .padding(.leading, r.x)
            .padding(.top, r.y)
    }
}

/// Countdown ring with play symbol. The fill runs continuously, not in steps
/// (`FillClock`). Dimensions follow the design's proportions (56 grid).
struct CountdownRing: View {
    let fillContent: FillClock
    let throughMeasure: CGFloat

    var body: some View {
        let d = throughMeasure
        let stroke = d * 3 / 56
        TimelineView(.animation) { time in
            let share = fillContent.share(now: time.date)
            ZStack {
                Circle().fill(.black.opacity(0.5))
                Circle().inset(by: stroke)
                    .stroke(Color.white.opacity(0.18), lineWidth: stroke)
                Circle().inset(by: stroke)
                    .trim(from: 0, to: share)
                    .stroke(Theme.accent, style: StrokeStyle(lineWidth: stroke, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Image(systemName: "play.fill")
                    .font(.system(size: d * 0.3))
                    .foregroundStyle(Theme.font)
                    .offset(x: d * 0.03)
            }
            .frame(width: d, height: d)
        }
    }
}

/// The dark gradient at the bottom right, under card and lines, so the text
/// stays readable on any credits.
struct CardsScrim: View {
    var body: some View {
        EllipticalGradient(stops: [
            .init(color: .black.opacity(0.78), location: 0),
            .init(color: .clear, location: 0.7),
        ], center: UnitPoint(x: 0.88, y: 0.92), startRadiusFraction: 0, endRadiusFraction: 0.75)
        .ignoresSafeArea()
    }
}
