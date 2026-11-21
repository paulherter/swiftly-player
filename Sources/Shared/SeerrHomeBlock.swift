import JellyfinKit
import SwiftUI
import SwiftlyCore

/// **What Seerr adds to the Home page**, in two sections that sit in the Home row order like any other row
/// (Settings > Darstellung > Startseite): the banner "<Titel> ist da" with Abspielen and a close X plus the
/// manager's "Wartet auf dich" line (`.arrival`), and the "Meine Anfragen" rail (`.requests`).
///
/// Every word and the decision whether anything shows come from the core (`SeerrHomeInfo.show`): without a
/// connection, or with nothing to say, nothing is drawn, not even a heading. The Home page loads this together
/// with its own rows; until Seerr answers, the banner's room of the last start holds a calm skeleton of the card's
/// final shape (`ArrivalSkeleton`) that the real card fades in over, and the other parts keep their room blank
/// (`SeerrReserved`), so nothing pops in and pushes the rows down.
struct SeerrHomeBlock: View {
    /// Which section of the core's block this draws.
    enum Part { case arrival, requests }

    let part: Part
    let flow: SeerrHomeFlow
    let model: AppModel
    /// "Abspielen": the library item of the arrived title.
    let play: (_ libraryId: String) -> Void
    /// A tap on a card or its cover: the title's page.
    let open: (_ libraryId: String) -> Void

    @Environment(\.wide) private var wide

    var body: some View {
        // A part with nothing in it is not a view at all, so it adds no gap between the rows.
        if let info = flow.block(model), has(info) {
            VStack(alignment: .leading, spacing: Theme.railsSpacing) {
                if part == .arrival {
                    let pending = info.state == .pending
                    VStack(spacing: 12) {
                        if !info.arrivals.isEmpty {
                            ArrivalStack(arrivals: info.arrivals,
                                         expanded: info.arrivalsExpanded,
                                         play: play,
                                         openTitle: open,
                                         close: { flow.dismissArrival($0) },
                                         setExpanded: { flow.setArrivalsExpanded($0) })
                                .modifier(SeerrReserved(pending: pending))
                                // Pending: the skeleton of the exact final shape sits under the (invisible) cards and
                                // stays until the real ones are opaque, so the card tone never dips in between.
                                .background {
                                    if pending {
                                        ArrivalSkeleton(count: info.arrivals.count)
                                            .transition(.asymmetric(
                                                insertion: .identity,
                                                removal: .opacity.animation(Theme.reveal.delay(0.2))))
                                    }
                                }
                                .transition(.opacity)
                                #if DEBUG
                                // Proof hook (Werkzeuge/arrivals-run.sh): `-SwiftlyLiveExpandArrivals <ms>` taps the closed stack open
                                // (the same `setArrivalsExpanded(true)` the tap calls) <ms> after the real cards are in.
                                .task(id: pending) {
                                    let args = ProcessInfo.processInfo.arguments
                                    guard !pending, !info.arrivalsExpanded, info.arrivals.count > 1,
                                          let at = args.firstIndex(of: "-SwiftlyLiveExpandArrivals"), at + 1 < args.count,
                                          let ms = Int(args[at + 1]) else { return }
                                    try? await Task.sleep(for: .milliseconds(ms))
                                    flow.setArrivalsExpanded(true)
                                }
                                #endif
                        }
                        if let attention = info.attention {
                            AttentionLine(attention: attention)
                                .modifier(SeerrReserved(pending: pending))
                        }
                    }
                }
                if part == .requests {
                    requested(info)
                }
            }
            // Pending: the core's blank content of the last shape takes the room, invisible (the banner part shows its
            // skeleton instead, see above).
            .modifier(SeerrReserved(pending: part == .requests && info.state == .pending))
        }
    }

    private func has(_ info: SwiftlyCore.SeerrHomeInfo) -> Bool {
        switch part {
        case .arrival: info.arrival != nil || info.attention != nil
        case .requests: !info.rail.isEmpty
        }
    }

    private func requested(_ info: SwiftlyCore.SeerrHomeInfo) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            RailTitle(name: info.railTitle)
                .padding(.horizontal, Theme.margin(wide: wide))
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: Theme.tileSpacing) {
                    ForEach(info.rail) { card in
                        NavigationLink(value: card.route) {
                            SeerrTile(card: card, width: Theme.railsWidth(wide: wide))
                        }
                        .buttonStyle(Theme.PressRow())
                    }
                }
                .padding(.horizontal, Theme.margin(wide: wide))
            }
            .scrollIndicators(.hidden)
        }
    }
}

/// **Several "ist da" notices as a stack** (like the notification stacks of iOS). The state lives in the core
/// (`ArrivalDeck`, `arrivalsExpanded`); this draws the cards by their place in the core's order.
///
/// - Closed: the front card, up to two cards peek out below it (lifted by a shadow, edged by a light hairline, so they
///   read on a dark page) and a small count sits in the front card. A tap on the stack opens it.
/// - Open: every card in a list, each slides to its place a little after the one above it, "Weniger anzeigen" below
///   closes it again. All cards are the same views in both states, so open and close are one interruptible spring.
/// - Dismiss: any card moves away to either side with the finger (`SwipeAwayCard`, scroll physics: 1:1, momentum, rubber
///   band) or with its X; the cards below close the gap with the same spring. The last card closes the block.
/// - Reduce Motion: cards switch place at once, only opacity eases.
private struct ArrivalStack: View {
    let arrivals: [SwiftlyCore.SeerrArrival]
    let expanded: Bool
    let play: (_ libraryId: String) -> Void
    let openTitle: (_ libraryId: String) -> Void
    let close: (_ requestId: Int64) -> Void
    let setExpanded: (_ on: Bool) -> Void

    /// Height of one card (measured from the front card; the cards are the same size).
    @State private var cardHeight: CGFloat = 84

    /// Peek of each card behind, gap in the open list, room of "Weniger anzeigen", and how many cards peek at all.
    private let peek = ArrivalMotion.peek
    private let gap: CGFloat = 8
    private let footer: CGFloat = 44
    private let shownBehind = 2

    private var stacked: Bool { arrivals.count > 1 }
    private var open: Bool { expanded && stacked }
    private var calm: Bool { Theme.motionReduced }

    var body: some View {
        let count = arrivals.count
        ZStack(alignment: .top) {
            ForEach(Array(arrivals.enumerated()), id: \.element.requestId) { index, arrival in
                let behind = open ? 0 : min(index, shownBehind)
                SwipeAwayCard(arrival: arrival,
                              badge: stacked && !open && index == 0 ? count : nil,
                              depth: behind,
                              lifted: stacked && !open && index < shownBehind,
                              play: { play(arrival.libraryId) },
                              // The first tap on a closed stack opens it; after that a tap opens the title.
                              tap: { stacked && !open ? setExpanded(true) : openTitle(arrival.libraryId) },
                              close: { close(arrival.requestId) })
                    .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { height in
                        if index == 0, height > 0 { cardHeight = height }
                    }
                    .scaleEffect(open ? 1 : 1 - 0.05 * CGFloat(behind), anchor: .bottom)
                    .offset(y: open ? CGFloat(index) * (cardHeight + gap) : CGFloat(behind) * peek)
                    .animation(calm ? nil : ArrivalMotion.spring.delay(stagger(index, of: count)), value: open)
                    .opacity(!open && index > shownBehind ? 0 : 1)
                    .animation(calm ? Theme.reveal : ArrivalMotion.spring.delay(stagger(index, of: count)), value: open)
                    .zIndex(Double(count - index))
                    .allowsHitTesting(open || index == 0)
                    .accessibilityHidden(!open && index != 0)
                    .transition(.opacity)
            }
        }
        .frame(height: height(count), alignment: .top)
        .frame(maxWidth: .infinity, alignment: .top)
        .overlay(alignment: .bottom) { if open { collapseButton } }
        .contentShape(Rectangle())
        // A tap anywhere on the closed stack opens it; the buttons of the front card keep their own taps.
        .onTapGesture { if stacked, !open { setExpanded(true) } }
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: Text("Alle Meldungen anzeigen")) { if stacked { setExpanded(true) } }
    }

    private func height(_ count: Int) -> CGFloat {
        if open { return CGFloat(count) * cardHeight + CGFloat(count - 1) * gap + footer }
        return cardHeight + (count > 1 ? ArrivalMotion.closedRoom : 0)
    }

    /// Each card follows the one above it by a breath, not more (the whole change stays under a quarter second longer).
    private func stagger(_ index: Int, of count: Int) -> Double {
        calm ? 0 : 0.03 * Double(min(index, 4))
    }

    private var collapseButton: some View {
        Button { setExpanded(false) } label: {
            Text("Weniger anzeigen")
                .font(.app(size: 13, weight: .semibold))
                .foregroundStyle(Theme.fontQuiet)
                .padding(.horizontal, 14)
                .frame(height: 32)
                .background(Theme.groupsArea, in: Capsule())
                // 32 drawn, 44 to hit.
                .frame(height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(Theme.PressButton())
        .transition(.opacity)
        .animation(calm ? Theme.reveal : ArrivalMotion.spring.delay(0.08), value: open)
    }
}

/// One arrival card that goes away to either side. **Scroll physics instead of a drag gesture of ours** (same reason as
/// `SwipeRow`): the card sits in a horizontal scroll area between two empty fields, so UIKit decides horizontal against
/// vertical, the card follows the finger 1:1, carries its speed and bounces at the end. Once it has left the area
/// (and the finger is up) the core drops it and the cards below close the gap.
private struct SwipeAwayCard: View {
    let arrival: SwiftlyCore.SeerrArrival
    let badge: Int?
    let depth: Int
    let lifted: Bool
    let play: () -> Void
    let tap: () -> Void
    let close: () -> Void

    private enum Field: Hashable { case away, card, gone }
    @State private var width: CGFloat = 0
    @State private var offset: CGFloat = 0
    @State private var phase: ScrollPhase = .idle
    @State private var left = false
    /// The card has been seen in its place: before that the scroll area still reports offset 0 (the empty field), which
    /// must not count as "the card went away".
    @State private var seated = false

    /// From this share of the card's width outside the area, the card counts as gone.
    private let leaves: CGFloat = 0.7

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 0) {
                Color.clear.frame(height: 1).containerRelativeFrame(.horizontal).id(Field.away)
                ArrivalBanner(arrival: arrival, badge: badge, depth: depth, lifted: lifted, play: play, tap: tap, close: close)
                    .containerRelativeFrame(.horizontal)
                    .id(Field.card)
                Color.clear.frame(height: 1).containerRelativeFrame(.horizontal).id(Field.gone)
            }
            .scrollTargetLayout()
        }
        .scrollIndicators(.hidden)
        .scrollClipDisabled()
        .scrollTargetBehavior(.viewAligned)
        // The card starts in the middle field, without a scroll animation (a scroll position set after the first frame
        // would slide the card in from the side).
        .defaultScrollAnchor(.center)
        .onScrollGeometryChange(for: [CGFloat].self) { [$0.contentOffset.x, $0.containerSize.width] } action: { _, new in
            offset = new[0]
            width = new[1]
            decide()
        }
        .onScrollPhaseChange { _, new in
            phase = new
            decide()
        }
        .accessibilityAction(named: Text("Ausblenden")) { close() }
    }

    private func decide() {
        guard !left, width > 0 else { return }
        if abs(offset - width) < 1 { seated = true }
        guard seated, phase != .interacting else { return }
        if abs(offset - width) > width * leaves {
            left = true
            Theme.jerk(.lightweight)
            close()
        }
    }
}

/// "<Titel> ist da": a card of the page's group tone with the poster, the core's line, one Abspielen pill and the X.
private struct ArrivalBanner: View {
    let arrival: SwiftlyCore.SeerrArrival
    /// How many cards the closed stack holds (only on its front card).
    var badge: Int?
    /// 0 = in front; behind the front card it grows (a little darker, a light hairline so the edge reads on dark).
    var depth: Int = 0
    /// A shadow below the card, so the card behind it reads as a separate sheet.
    var lifted = false
    let play: () -> Void
    /// A tap on the card or its cover (the pill and the X keep their own taps).
    let tap: () -> Void
    let close: () -> Void

    var body: some View {
        CardView {
            HStack(spacing: 12) {
                Picture(url: arrival.poster.flatMap { URL(string: $0) }, corner: 6)
                    .frame(width: 40, height: 60)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: arrival.line)
                        .growing(15, .semibold)
                        .lineLimit(2)
                    HStack(spacing: 6) {
                        Text("Deine Anfrage")
                            .font(Theme.small)
                            .foregroundStyle(Theme.fontVeryQuiet)
                        if let badge {
                            Text(verbatim: badge.formatted())
                                .font(Theme.badge)
                                .monospacedDigit()
                                .foregroundStyle(Theme.fontQuiet)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(Theme.area, in: Capsule())
                                .transition(.opacity)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isButton)
                .accessibilityAction(.default, tap)
                ValuePill(symbol: "play.fill", text: String(localized: "Abspielen"), perform: play)
                Button(action: close) {
                    Image(icon: "xmark", size: 13)
                        .font(.app(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.fontQuiet)
                        // 28 drawn, 44 to hit.
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(Theme.PressButton())
                .padding(.trailing, -10)
                .accessibilityLabel(Text("Ausblenden"))
            }
            .padding(.vertical, 12)
            .padding(.leading, 12)
            .padding(.trailing, 4)
            .contentShape(Rectangle())
            .onTapGesture(perform: tap)
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cornerCard, style: .continuous)
                    .fill(Color.black.opacity(0.10 * Double(depth)))
                    .allowsHitTesting(false)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cornerCard, style: .continuous)
                    .strokeBorder(Color.white.opacity(depth > 0 ? 0.12 : 0), lineWidth: 1)
                    .allowsHitTesting(false)
            )
        }
        .shadow(color: .black.opacity(lifted ? 0.28 : 0), radius: 8, y: 3)
    }
}

/// **The card before it exists.** While Seerr has not answered, the banner's room of the last start (one card, or the
/// stack with its peeking cards) holds the card's own shape: the same tone, corners, peek, shadow and hairline as the
/// real ones, with quiet bars where the poster, the two lines and the pill will be. A slow, faint light passes over the
/// bars (nothing at Reduce Motion). It is laid out by the real, invisible cards on top of it, so it has exactly their
/// size; the real card fades in over it in place.
private struct ArrivalSkeleton: View {
    let count: Int
    @Environment(\.wide) private var wide

    private let peek = ArrivalMotion.peek
    private let shownBehind = 2

    var body: some View {
        GeometryReader { box in
            let behind = min(count - 1, shownBehind)
            let card = max(box.size.height - (count > 1 ? ArrivalMotion.closedRoom : 0), 0)
            ZStack(alignment: .top) {
                ForEach(Array((0...behind).reversed()), id: \.self) { depth in
                    let shape = RoundedRectangle(cornerRadius: Theme.cornerCard, style: .continuous)
                    shape.fill(Theme.groupsArea)
                        .overlay(shape.fill(Color.black.opacity(0.10 * Double(depth))))
                        .overlay(shape.strokeBorder(Color.white.opacity(depth > 0 ? 0.12 : 0), lineWidth: 1))
                        .overlay { if depth == 0 { bars } }
                        .frame(height: card)
                        .scaleEffect(1 - 0.05 * CGFloat(depth), anchor: .bottom)
                        .offset(y: CGFloat(depth) * peek)
                        .shadow(color: .black.opacity(count > 1 && depth < shownBehind ? 0.28 : 0), radius: 8, y: 3)
                }
            }
            .padding(.horizontal, Theme.margin(wide: wide))
            .frame(width: box.size.width, height: box.size.height, alignment: .top)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// Poster, two lines, pill: the places of the real card's parts (same insets as `ArrivalBanner`).
    private var bars: some View {
        let shapes = HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 6, style: .continuous).frame(width: 40, height: 60)
            VStack(alignment: .leading, spacing: 8) {
                Capsule().frame(width: 150, height: 14)
                Capsule().frame(width: 84, height: 11)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Capsule().frame(width: 92, height: Theme.pillMinHeight)
            Color.clear.frame(width: 28, height: 1)
        }
        .padding(.vertical, 12)
        .padding(.leading, 12)
        .padding(.trailing, 4)
        return shapes
            .foregroundStyle(Theme.area)
            .overlay { SkeletonLight().mask(shapes) }
    }
}

/// A faint band of light that passes over the skeleton bars about every two seconds, slowly and without a hard edge
/// (apple-design: a placeholder breathes, it does not flash). Reduce Motion: no movement.
private struct SkeletonLight: View {
    @State private var moved = false

    var body: some View {
        GeometryReader { box in
            LinearGradient(colors: [.clear, Color.white.opacity(0.08), .clear], startPoint: .leading, endPoint: .trailing)
                .frame(width: box.size.width * 0.55)
                .offset(x: moved ? box.size.width : -box.size.width * 0.55)
        }
        .clipped()
        .onAppear {
            guard !Theme.motionReduced else { return }
            withAnimation(.easeInOut(duration: 1.8).repeatForever(autoreverses: false)) { moved = true }
        }
    }
}

/// The manager's line: what waits for a decision, leading to the administration page.
private struct AttentionLine: View {
    let attention: SwiftlyCore.SeerrAttention

    var body: some View {
        CardView {
            NavigationLink(value: SeerrAdminRoute()) {
                HStack(spacing: 14) {
                    Image(icon: "clock", size: Theme.rowSymbolSize)
                        .font(.app(size: Theme.rowSymbolSize))
                        .frame(width: Theme.rowIconWidth)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: attention.title)
                            .font(.app(size: Theme.rowTitleSize, weight: .medium))
                        Text(verbatim: attention.detail)
                            .font(Theme.small)
                            .foregroundStyle(Theme.fontVeryQuiet)
                    }
                    Spacer(minLength: 0)
                    SeerrCountMark(count: Int(attention.count))
                    Image(icon: "chevron.right", size: 13)
                        .font(.app(size: 13, weight: .semibold))
                        .accessibilityHidden(true)
                }
                .foregroundStyle(Theme.font)
                .padding(.horizontal, 16)
                .padding(.vertical, Theme.rowPadV)
                .frame(minHeight: Theme.rowHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(Theme.PressRow())
            .accessibilityElement(children: .combine)
        }
    }
}

/// The number on a line that waits for someone (the warning tone, dark text on it, like the tile capsules).
struct SeerrCountMark: View {
    let count: Int

    var body: some View {
        if count > 0 {
            Text(verbatim: count.formatted())
                .font(Theme.badge)
                .monospacedDigit()
                .foregroundStyle(Theme.reason)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Theme.warning, in: Capsule())
                .accessibilityHidden(true)
        }
    }
}
