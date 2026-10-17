import JellyfinKit
import SwiftUI

/// **The next episode as a card at the bottom right.** Same as on the iPhone
/// (`Sources/iOS/EpisodeCardsView.swift`). Timing, springs and metrics live in
/// ``EpisodeCard`` in the package, frame, ring and gradient in
/// `Sources/Shared/EpisodeCardParts.swift`; this file only draws it for the window.
///
/// Everything hangs on the same three values as there: `present`, `zoom`, `image`. Every
/// spring starts from the current state.
///
/// **Three deviations, all because of pointer and window:**
/// - **The card stands above the control bar,** where the skip pill stands, not at the
///   bottom edge. On the Mac every pointer movement brings up the controls
///   (`OfferingLayer.Opening.beside`); moving to the card to click it would open
///   the bar. With the card at the bottom the bar would cover its lines, and if the
///   card made the bar wait, the mouse could never reach it. Only a click into the
///   picture (deliberate) makes it wait, like the tap on the picture on iPhone.
/// - **Cancel with the X on the card or with Esc** (`escapeKey`), start with Return.
///   Dragging right or down with the mouse throws it away like the swipe on iPhone.
/// - **Width as on the iPad** (`large`), at most 30 % of the window.
struct EpisodeCardsView: View {
    let episode: Item
    let imageAddress: URL?
    let mass: PlayerMetric
    let present: Bool
    let zoom: Double
    let detailsPresent: Bool
    let image: Double
    let fillContent: FillClock
    let rest: Int
    let onTap: () -> Void
    let cancel: () -> Void

    @State private var drag: CGSize = .zero
    @State private var hovers = false

    private var metrics: EpisodeCard.Metrics { EpisodeCard.iPhone }
    /// Height of the two lines under the card, including spacing.
    private var rows: CGFloat {
        CGFloat(metrics.spacing) + ceil(CGFloat(metrics.small) * 1.2) + 3 + ceil(CGFloat(metrics.title) * 1.2)
    }

    /// Where the card stands: at the right edge of the controls; the lines below end where
    /// the skip pill ends.
    private func card(_ g: GeometryProxy) -> CGRect {
        let width = CGFloat(EpisodeCard.width(metrics, safeWidth: Double(g.size.width), large: true))
        let height = width * 9 / 16
        let bottom = mass.bottom + mass.bar + mass.overBar
        return CGRect(x: g.size.width - mass.page - width,
                      y: g.size.height - bottom - rows - height,
                      width: width, height: height)
    }

    var body: some View {
        GeometryReader { g in
            let card = card(g)
            let offset = zoom > 0 ? .zero : drag
            ZStack(alignment: .topLeading) {
                // The gradient only fades; it does not travel with the card.
                CardsScrim()
                    .opacity(detailsPresent && present ? 1 : 0)
                    .animation(detailsCurve, value: detailsPresent)
                    .allowsHitTesting(false)

                Group {
                    Button(action: onTap) {
                        cardImage
                            .modifier(CardsShape(zoom: zoom, card: card, whole: g.size,
                                                 corner: CGFloat(metrics.corner)))
                    }
                    .buttonStyle(Theme.PressButton())
                    .disabled(zoom > 0)
                    .onHover { hovers = $0 && zoom == 0 }
                    .animation(Theme.timeFloat, value: hovers)
                    .modifier(CardsStatus(zoom: zoom, card: card, whole: g.size))
                    .accessibilityLabel(Text("Nächste Folge abspielen: \(abbreviation)"))
                    .accessibilityValue(Text("Startet in \(rest) Sekunden"))
                    .accessibilityAction(named: Text("Karte schließen"), cancel)

                    details
                        .frame(width: card.width, alignment: .leading)
                        .offset(x: card.minX, y: card.maxY + CGFloat(metrics.spacing))
                        .opacity(detailsPresent ? 1 : 0)
                        .offset(y: detailsPresent || Theme.motionReduced ? 0 : 6)
                        .animation(detailsCurve, value: detailsPresent)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)

                    // The round X at the card corner: card gone, countdown off, credits keep running.
                    closeButton
                        .position(x: card.maxX - 16, y: card.minY + 16)
                        .opacity(detailsPresent ? 1 : 0)
                        .animation(detailsCurve, value: detailsPresent)
                        .allowsHitTesting(detailsPresent)
                }
                .offset(offset)
                .gesture(dragGesture, including: zoom > 0 ? .none : .all)
                .opacity(present ? 1 : 0)
                .scaleEffect(zoom > 0 ? 1 : (present ? 1 : EpisodeCard.startMetric),
                             anchor: UnitPoint(x: card.midX / max(g.size.width, 1),
                                               y: card.midY / max(g.size.height, 1)))
                .offset(x: present || Theme.motionReduced ? 0 : EpisodeCard.offset)
            }
        }
        .ignoresSafeArea()
        // Gone is gone: forget the drag once the card has left.
        .onChange(of: present) { _, now in
            guard !now else { return }
            Task {
                try? await Task.sleep(for: .milliseconds(600))
                var still = Transaction()
                still.disablesAnimations = true
                withTransaction(still) { drag = .zero }
            }
        }
    }

    /// Follows the pointer to the right and down; far enough, or with enough momentum, the
    /// card is gone, otherwise it springs back. Same rule as the swipe on iPhone
    /// (``Folgenkarte/weggewischt(x:y:schwungX:schwungY:)``).
    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { w in
                let z = EpisodeCard.dragged(Double(w.translation.width), Double(w.translation.height))
                drag = CGSize(width: z.x, height: z.y)
            }
            .onEnded { w in
                let t = w.translation, p = w.predictedEndTranslation
                if EpisodeCard.swipedAway(x: Double(t.width), y: Double(t.height),
                                           momentumX: Double(p.width), momentumY: Double(p.height)) {
                    AppLog.writeOut("[Karte] weggezogen")
                    cancel()
                } else {
                    let f = EpisodeCard.spring(EpisodeCard.distanceOmega)
                    withAnimation(Theme.motionReduced ? Theme.fadeReduced
                                  : .interpolatingSpring(mass: 1, stiffness: f.stiffness,
                                                         damping: f.damping)) {
                        drag = .zero
                    }
                }
            }
    }

    /// Small and round at the card corner; on the Mac with a 32 pt hit area, since a pointer is more precise than a thumb.
    private var closeButton: some View {
        Button {
            AppLog.writeOut("[Karte] × geklickt")
            cancel()
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.font)
                .frame(width: 24, height: 24)
                .background(Theme.area.opacity(0.85), in: Circle())
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(Theme.PressButton())
        .help(Text("Karte schließen"))
        .accessibilityLabel(Text("Karte schließen"))
    }

    /// Ring and lines go to ``Folgenkarte/angabenAus`` on start.
    private var detailsCurve: Animation {
        Theme.motionReduced ? Theme.fadeReduced : .easeOut(duration: EpisodeCard.detailsOut)
    }

    // From the package (`episodeCode`), not hard-coded: it was fixed as "F", also in
    // English, where it is "E".
    private var abbreviation: String {
        episode.episodeCode ?? episode.name
    }

    private var cardImage: some View {
        ZStack {
            Color.black
            NetworkImage(url: imageAddress, preRank: true)
                .opacity(image)
            CountdownRing(fillContent: fillContent, throughMeasure: CGFloat(metrics.ring))
                .opacity(detailsPresent ? 1 : 0)
                .scaleEffect(hovers && !Theme.motionReduced ? 1.06 : 1)
                .animation(detailsCurve, value: detailsPresent)
                .animation(Theme.timeFloat, value: hovers)
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 12) {
                Text(verbatim: abbreviation)
                Spacer(minLength: 0)
                Text("in \(rest) s")
                    .monospacedDigit()
            }
            .font(.system(size: CGFloat(metrics.small), weight: .semibold))
            .foregroundStyle(Theme.fontVeryQuiet)
            .lineLimit(1)
            Text(verbatim: episode.name)
                .font(.system(size: CGFloat(metrics.title), weight: .semibold))
                .foregroundStyle(Theme.font)
                .lineLimit(1)
        }
    }
}
