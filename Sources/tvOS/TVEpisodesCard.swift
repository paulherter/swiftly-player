import JellyfinKit
import SwiftUI

/// **The next episode as a card at the bottom right, on the TV.** As on iPhone, with focus:
/// while the card is shown it has focus and grows by 6 %; a click presses it in briefly and
/// starts playback, Menu slides it out and the credits keep playing. Timings, springs and
/// sizes come from ``EpisodeCard``, shared parts from `EpisodeCardParts.swift`.
struct TVEpisodesCard: View {
    let episode: Item
    let imageAddress: URL?
    let present: Bool
    let zoom: Double
    let detailsPresent: Bool
    let image: Double
    let fillContent: FillClock
    let rest: Int
    let focus: FocusState<PlayerScreen.FocusTarget?>.Binding
    let onTap: () -> Void

    private let metrics = EpisodeCard.tv
    private var width: CGFloat { CGFloat(metrics.width) }
    private var height: CGFloat { width * 9 / 16 }
    private var rows: CGFloat {
        CGFloat(metrics.spacing) + CGFloat(metrics.small) * 1.3 + 6 + CGFloat(metrics.title) * 1.25
    }

    var body: some View {
        GeometryReader { g in
            let card = CGRect(x: g.size.width - Theme.edgePage - width,
                               y: g.size.height - Theme.edgeTop - rows - height,
                               width: width, height: height)
            ZStack(alignment: .topLeading) {
                CardsScrim()
                    .opacity(detailsPresent && present ? 1 : 0)
                    .animation(detailsCurve, value: detailsPresent)
                    .allowsHitTesting(false)

                Button(action: onTap) {
                    ZStack {
                        Color.black
                        Picture(url: imageAddress, corner: 0)
                            .opacity(image)
                        CountdownRing(fillContent: fillContent, throughMeasure: CGFloat(metrics.ring))
                            .opacity(detailsPresent ? 1 : 0)
                            .animation(detailsCurve, value: detailsPresent)
                    }
                    .modifier(CardsShape(zoom: zoom, card: card, whole: g.size,
                                         corner: CGFloat(metrics.corner)))
                }
                .buttonStyle(CardsStyle(zoomed: zoom > 0))
                .focused(focus, equals: .offering)
                .disabled(!present || zoom > 0)
                .modifier(CardsStatus(zoom: zoom, card: card, whole: g.size))
                .accessibilityLabel(Text("Nächste Folge abspielen: \(abbreviation)"))
                .accessibilityValue(Text("Startet in \(rest) Sekunden"))

                details
                    .frame(width: width, alignment: .leading)
                    .offset(x: card.minX, y: card.maxY + CGFloat(metrics.spacing))
                    .opacity(detailsPresent ? 1 : 0)
                    .offset(y: detailsPresent || Theme.motionReduced ? 0 : 12)
                    .animation(detailsCurve, value: detailsPresent)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .opacity(present ? 1 : 0)
            .scaleEffect(zoom > 0 ? 1 : (present ? 1 : EpisodeCard.startMetric),
                         anchor: UnitPoint(x: card.midX / max(g.size.width, 1),
                                           y: card.midY / max(g.size.height, 1)))
            .offset(x: present || Theme.motionReduced ? 0 : EpisodeCard.offset * 2)
        }
        .ignoresSafeArea()
    }

    private var detailsCurve: Animation {
        Theme.motion(.easeOut(duration: EpisodeCard.detailsOut))
    }

    // From the package (`episodeCode`), not hardcoded: it was fixed to "F", also in
    // English, where it is "E".
    private var abbreviation: String {
        episode.episodeCode ?? episode.name
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 24) {
                Text(verbatim: abbreviation)
                Spacer(minLength: 0)
                Text("in \(rest) s")
                    .monospacedDigit()
            }
            .font(.system(size: CGFloat(metrics.small), weight: .semibold))
            .foregroundStyle(Theme.fontVeryQuiet)
            Text(verbatim: episode.name)
                .font(.system(size: CGFloat(metrics.title), weight: .semibold))
                .foregroundStyle(Theme.font)
                .lineLimit(1)
        }
    }
}

/// Focus raises the card (``Folgenkarte/fokusmass``), a click presses it in, via a spring
/// from the current state. None of this while zooming.
private struct CardsStyle: ButtonStyle {
    let zoomed: Bool

    func makeBody(configuration: Configuration) -> some View {
        Inner(configuration: configuration, zoomed: zoomed)
    }

    private struct Inner: View {
        let configuration: ButtonStyleConfiguration
        let zoomed: Bool
        @Environment(\.isFocused) private var focused

        var body: some View {
            let hoist = focused && !zoomed ? EpisodeCard.focusMetric : 1
            let press = configuration.isPressed ? 1 - EpisodeCard.clickPress : 1
            configuration.label
                .scaleEffect(Theme.motionReduced ? 1 : hoist * press)
                .animation(Theme.motion(.interpolatingSpring(
                    mass: 1, stiffness: EpisodeCard.spring(EpisodeCard.appearOmega).stiffness,
                    damping: EpisodeCard.spring(EpisodeCard.appearOmega).damping)),
                           value: hoist * press)
        }
    }
}
