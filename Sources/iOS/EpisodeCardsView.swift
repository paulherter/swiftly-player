import JellyfinKit
import SwiftUI

/// **The next episode as a card at the bottom right** (variant C of the
/// design). Timings, springs and dimensions live in ``EpisodeCard`` in the
/// package; here only the drawing for iPhone and iPad.
///
/// Everything hangs on three values the player moves with springs: `present` (slide
/// in/out), `zoom` (card to full image) and `image` (opacity of the thumbnail
/// while the new episode plays underneath). Each spring starts from the current
/// state, so tapping mid-motion causes no jump.
///
/// **Fully inside the safe area:** layout is computed from the edges of the
/// safe area, not the screen, and the card gets narrower on narrow devices
/// (``Folgenkarte/breite(_:safeWidth:gross:)``). Otherwise the title ran off
/// the bottom of the screen.
///
/// **Dismissing is unambiguous:** the round X at the card corner, or swiping
/// away to the right or down. Tapping the image brings up the controls; the card
/// then leaves, the countdown waits, and the card returns with the controls
/// (`OfferingLayer.cardWaitsControls`).
struct EpisodeCardsView: View {
    let episode: Item
    let imageAddress: URL?
    let pad: Bool
    /// Right margin, like the controls.
    let page: CGFloat
    let present: Bool
    let zoom: Double
    let detailsPresent: Bool
    let image: Double
    let fillContent: FillClock
    let rest: Int
    let onTap: () -> Void
    let cancel: () -> Void

    @State private var drag: CGSize = .zero

    private var metrics: EpisodeCard.Metrics { EpisodeCard.iPhone }
    /// Height of the two lines below the card, including spacing.
    private var rows: CGFloat {
        CGFloat(metrics.spacing) + ceil(CGFloat(metrics.small) * 1.2) + 3 + ceil(CGFloat(metrics.title) * 1.2)
    }

    /// **The window's safe margins.** The reader itself extends beyond the safe
    /// area and then reports zero (measured in the simulator, iPhone 17 Pro Max in
    /// landscape: 0 instead of 62 left and right), so take it from the window, and
    /// the larger of the two.
    private func safe(_ g: GeometryProxy) -> EdgeInsets {
        let f = UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow }.first?.safeAreaInsets ?? .zero
        let e = g.safeAreaInsets
        return EdgeInsets(top: max(e.top, f.top), leading: max(e.leading, f.left),
                          bottom: max(e.bottom, f.bottom), trailing: max(e.trailing, f.right))
    }

    /// Where the card sits, inside the safe area.
    private func card(_ g: GeometryProxy) -> CGRect {
        let safe = safe(g)
        let safeWidth = g.size.width - safe.leading - safe.trailing
        let width = CGFloat(EpisodeCard.width(metrics, safeWidth: Double(safeWidth), large: pad))
        let height = width * 9 / 16
        let bottom = safe.bottom + CGFloat(EpisodeCard.bottomSpacing)
        return CGRect(x: g.size.width - safe.trailing - page - width,
                      y: g.size.height - bottom - rows - height,
                      width: width, height: height)
    }

    var body: some View {
        GeometryReader { g in
            let card = card(g)
            let offset = zoom > 0 ? .zero : drag
            ZStack(alignment: .topLeading) {
                // The gradient only fades; it does not move with the card.
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

                    // The round X at the card corner: card gone, countdown off, credits keep
                    // playing.
                    closeButton
                        .position(x: card.maxX - 18, y: card.minY + 18)
                        .opacity(detailsPresent ? 1 : 0)
                        .animation(detailsCurve, value: detailsPresent)
                        .allowsHitTesting(detailsPresent)
                }
                .offset(offset)
                .gesture(swipe, including: zoom > 0 ? .none : .all)
                // **Only the card moves in and out**, from the right, from 94% size, with
                // opacity.
                .opacity(present ? 1 : 0)
                .scaleEffect(zoom > 0 ? 1 : (present ? 1 : EpisodeCard.startMetric),
                             anchor: UnitPoint(x: card.midX / max(g.size.width, 1),
                                               y: card.midY / max(g.size.height, 1)))
                .offset(x: present || Theme.motionReduced ? 0 : EpisodeCard.offset)
            }
            #if DEBUG
            .onChange(of: card, initial: true) { _, k in
                let s = safe(g)
                AppLog.writeOut("[Karte] Rahmen \(Int(k.minX)),\(Int(k.minY)) \(Int(k.width))×\(Int(k.height))"
                    + " · Zeilen bis \(Int(k.maxY + rows)) · Schirm \(Int(g.size.width))×\(Int(g.size.height))"
                    + " · sicher o\(Int(s.top)) l\(Int(s.leading)) u\(Int(s.bottom)) r\(Int(s.trailing))"
                    + " · unten frei \(Int(g.size.height - s.bottom - k.maxY - rows))"
                    + " · rechts frei \(Int(g.size.width - s.trailing - k.maxX))")
            }
            #endif
        }
        .ignoresSafeArea()
        // Gone is gone: forget the swipe once the card has left.
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

    /// Follows the finger right and down; far enough or with enough momentum the
    /// card is gone, otherwise it springs back.
    private var swipe: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { w in
                let z = EpisodeCard.dragged(Double(w.translation.width), Double(w.translation.height))
                drag = CGSize(width: z.x, height: z.y)
            }
            .onEnded { w in
                let t = w.translation, p = w.predictedEndTranslation
                if EpisodeCard.swipedAway(x: Double(t.width), y: Double(t.height),
                                           momentumX: Double(p.width), momentumY: Double(p.height)) {
                    AppLog.writeOut("[Karte] weggewischt")
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

    /// Bare symbol at the card corner like the other player icons (no circle: a
    /// circle is an image, not a button), 44 point hit area.
    private var closeButton: some View {
        Button {
            AppLog.writeOut("[Karte] × gedrückt")
            cancel()
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.font)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(Theme.PressButton())
        .accessibilityLabel(Text("Karte schließen"))
    }

    /// The ring and lines go into ``Folgenkarte/angabenAus`` at the start.
    private var detailsCurve: Animation {
        Theme.motionReduced ? Theme.fadeReduced : .easeOut(duration: EpisodeCard.detailsOut)
    }

    // From the package (`episodeCode`), no longer by hand: it was hard-coded
    // as "F", also in English, where it is "E".
    private var abbreviation: String {
        episode.episodeCode ?? episode.name
    }

    private var cardImage: some View {
        ZStack {
            Color.black
            Picture(url: imageAddress, corner: 0)
                .opacity(image)
            CountdownRing(fillContent: fillContent, throughMeasure: CGFloat(metrics.ring))
                .opacity(detailsPresent ? 1 : 0)
                .animation(detailsCurve, value: detailsPresent)
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
