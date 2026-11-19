import SwiftUI
import SwiftlyCore

/// **The "<Titel> ist da" notices as a stack, for Mac and Apple TV** (the iPhone draws the same core state in
/// `SeerrHomeBlock`; its swipe has no counterpart here, so the same steps are a click / a select).
/// The state is the core's (`ArrivalDeck`, `arrivalsExpanded`, the stored shape while Seerr has not answered); this
/// only draws it.
///
/// - Closed: the front card, up to two cards peek out below it, the count sits in the front card. Click (Mac) or select
///   (TV) on the stack opens it.
/// - Open: every card in a list, "Weniger anzeigen" below closes it. All cards are the same views in both states,
///   so open and close are one interruptible spring.
/// - X removes a card (Mac: a hover state; TV: a focusable control), the cards below close the gap with the same spring.
/// - Pending: a skeleton of the final shape sits under the invisible real cards and stays until they are opaque.
struct DesktopArrivalSection: View {
    let arrivals: [SwiftlyCore.SeerrArrival]
    let expanded: Bool
    let pending: Bool
    let play: (_ libraryId: String) -> Void
    let openTitle: (_ libraryId: String) -> Void
    let close: (_ requestId: Int64) -> Void
    let setExpanded: (_ on: Bool) -> Void
    /// tvOS: true while focus is on a control of the stack (the Start page makes room for the open stack then).
    var focusWithin: Binding<Bool> = .constant(false)
    /// tvOS: the page sets this to put focus on the front card (the stack is its first focusable row); the stack
    /// takes the request and resets it.
    var claimFocus: Binding<Bool> = .constant(false)

    var body: some View {
        DesktopArrivalStack(arrivals: arrivals, expanded: expanded, play: play, openTitle: openTitle,
                            close: close, setExpanded: setExpanded, focusWithin: focusWithin,
                            claimFocus: claimFocus)
            .modifier(SeerrReserved(pending: pending))
            .background {
                if pending {
                    DesktopArrivalSkeleton(count: arrivals.count)
                        .transition(.asymmetric(insertion: .identity,
                                                removal: .opacity.animation(Theme.reveal.delay(0.2))))
                }
            }
            .padding(.horizontal, DesktopArrival.edge)
            #if DEBUG
            // Proof hook: `-SwiftlyLiveExpandArrivals <ms>` opens the closed stack (the same `setExpanded(true)` the
            // click / select calls) <ms> after the real cards are in.
            .task(id: pending) {
                let args = ProcessInfo.processInfo.arguments
                guard !pending, !expanded, arrivals.count > 1,
                      let at = args.firstIndex(of: "-SwiftlyLiveExpandArrivals"), at + 1 < args.count,
                      let ms = Int(args[at + 1]) else { return }
                try? await Task.sleep(for: .milliseconds(ms))
                setExpanded(true)
            }
            #endif
    }
}

/// Sizes of the one card (fixed, so the skeleton, the stack and the rows below never disagree).
enum DesktopArrival {
    #if os(tvOS)
    static let edge = Theme.edgePage
    static let card: CGFloat = 168
    static let poster = CGSize(width: 80, height: 120)
    static let inset: CGFloat = 24
    static let gap: CGFloat = 20
    static let footer: CGFloat = 96
    static let peek: CGFloat = 20
    static let corner = Theme.corner
    static let lineSize: CGFloat = 30
    static let subSize: CGFloat = 24
    #else
    static let edge = Theme.edgeSpacing
    static let card: CGFloat = 84
    static let poster = CGSize(width: 40, height: 60)
    static let inset: CGFloat = 12
    static let gap: CGFloat = 8
    static let footer: CGFloat = 44
    static let peek: CGFloat = ArrivalMotion.peek
    static let corner = Theme.cornerCard
    static let lineSize: CGFloat = 15
    static let subSize: CGFloat = 12
    #endif
    static let closedRoom: CGFloat = ArrivalMotion.closedRoom
    static let shownBehind = 2
}

private struct DesktopArrivalStack: View {
    let arrivals: [SwiftlyCore.SeerrArrival]
    let expanded: Bool
    let play: (_ libraryId: String) -> Void
    let openTitle: (_ libraryId: String) -> Void
    let close: (_ requestId: Int64) -> Void
    let setExpanded: (_ on: Bool) -> Void
    var focusWithin: Binding<Bool> = .constant(false)
    var claimFocus: Binding<Bool> = .constant(false)

    @FocusState private var focusKey: String?

    private var stacked: Bool { arrivals.count > 1 }
    private var open: Bool { expanded && stacked }
    private var calm: Bool { Theme.motionReduced }

    var body: some View {
        let count = arrivals.count
        ZStack(alignment: .top) {
            ForEach(Array(arrivals.enumerated()), id: \.element.requestId) { index, arrival in
                let behind = open ? 0 : min(index, DesktopArrival.shownBehind)
                DesktopArrivalCard(arrival: arrival,
                                   badge: stacked && !open && index == 0 ? count : nil,
                                   depth: behind,
                                   interactive: open || index == 0,
                                   focusKey: $focusKey,
                                   play: { play(arrival.libraryId) },
                                   tap: { stacked && !open ? setExpanded(true) : openTitle(arrival.libraryId) },
                                   close: { withAnimation(ArrivalMotion.spring) { close(arrival.requestId) } })
                    .frame(height: DesktopArrival.card)
                    .scaleEffect(open ? 1 : 1 - 0.05 * CGFloat(behind), anchor: .bottom)
                    .offset(y: open ? CGFloat(index) * (DesktopArrival.card + DesktopArrival.gap)
                                    : CGFloat(behind) * DesktopArrival.peek)
                    .opacity(!open && index > DesktopArrival.shownBehind ? 0 : 1)
                    .animation(calm ? Theme.reveal : ArrivalMotion.spring.delay(0.03 * Double(min(index, 4))), value: open)
                    .zIndex(Double(count - index))
                    .allowsHitTesting(open || index == 0)
                    #if os(tvOS)
                    .disabled(!(open || index == 0))
                    #endif
                    .accessibilityHidden(!open && index != 0)
                    .transition(.opacity)
            }
        }
        .frame(height: DesktopArrivalMetrics.height(count: count, open: open), alignment: .top)
        .frame(maxWidth: .infinity, alignment: .top)
        .overlay(alignment: .bottom) { if open { collapse } }
        .animation(calm ? Theme.reveal : ArrivalMotion.spring, value: count)
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: Text("Alle Meldungen anzeigen")) { if stacked { setExpanded(true) } }
        #if os(tvOS)
        .focusSection()
        .onChange(of: focusKey != nil) { _, now in focusWithin.wrappedValue = now }
        .onChange(of: claimFocus.wrappedValue, initial: true) { _, claim in
            guard claim, let first = arrivals.first else { return }
            focusKey = "\(first.requestId)-tap"
            claimFocus.wrappedValue = false
        }
        #endif
    }

    private var collapse: some View {
        Button { setExpanded(false) } label: {
            Text("Weniger anzeigen")
                .font(.app(size: DesktopArrival.lineSize - 2, weight: .semibold))
                .foregroundStyle(Theme.fontQuiet)
                .padding(.horizontal, DesktopArrival.inset + 2)
                .frame(height: DesktopArrival.footer - 12)
                .background(Theme.area, in: Capsule())
                .frame(height: DesktopArrival.footer)
                .contentShape(Rectangle())
        }
        #if os(tvOS)
        .buttonStyle(ArrivalFocusStyle(shape: Capsule()))
        .focused($focusKey, equals: "collapse")
        #else
        .buttonStyle(Theme.PressButton())
        #endif
        .transition(.opacity)
    }
}

enum DesktopArrivalMetrics {
    static func height(count: Int, open: Bool) -> CGFloat {
        let card = DesktopArrival.card, gap = DesktopArrival.gap
        if open && count > 1 { return CGFloat(count) * card + CGFloat(count - 1) * gap + DesktopArrival.footer }
        return card + (count > 1 ? DesktopArrival.closedRoom : 0)
    }
}

/// One card: poster, the core's line, "Abspielen", X.
private struct DesktopArrivalCard: View {
    let arrival: SwiftlyCore.SeerrArrival
    let badge: Int?
    let depth: Int
    let interactive: Bool
    /// tvOS: which control of the stack holds focus (`<request id>-tap|play|close`, `collapse`).
    let focusKey: FocusState<String?>.Binding
    let play: () -> Void
    let tap: () -> Void
    let close: () -> Void

    @State private var hover = false

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: DesktopArrival.corner, style: .continuous) }

    private var info: some View {
        HStack(spacing: DesktopArrival.inset) {
            Picture(url: arrival.poster.flatMap { URL(string: $0) },
                    width: DesktopArrival.poster.width, height: DesktopArrival.poster.height, symbolText: "film")
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: arrival.line)
                    .font(.app(size: DesktopArrival.lineSize, weight: .semibold))
                    .foregroundStyle(Theme.font)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                HStack(spacing: 8) {
                    Text("Deine Anfrage")
                        .font(.app(size: DesktopArrival.subSize))
                        .foregroundStyle(Theme.fontVeryQuiet)
                    if let badge {
                        Text(verbatim: badge.formatted())
                            .font(.app(size: DesktopArrival.subSize, weight: .semibold))
                            .monospacedDigit()
                            .foregroundStyle(Theme.fontQuiet)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Theme.groupsArea, in: Capsule())
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var playLabel: some View {
        HStack(spacing: 6) {
            Image(icon: "play.fill", size: DesktopArrival.subSize)
            Text("Abspielen")
        }
        .font(.app(size: DesktopArrival.subSize + 1, weight: .semibold))
    }

    private var xmark: some View {
        Image(icon: "xmark", size: DesktopArrival.subSize + 1)
            .font(.app(size: DesktopArrival.subSize + 1, weight: .semibold))
            .foregroundStyle(Theme.fontQuiet)
            .frame(width: DesktopArrival.subSize + 20, height: DesktopArrival.subSize + 20)
    }

    var body: some View {
        #if os(tvOS)
        HStack(spacing: 16) {
            Button(action: tap) { info.frame(maxHeight: .infinity) }
                .buttonStyle(ArrivalFocusStyle(shape: shape))
                .focused(focusKey, equals: "\(arrival.requestId)-tap")
            Button(action: play) { playLabel.padding(.horizontal, 22).frame(height: 64) }
                .buttonStyle(ArrivalFocusStyle(shape: Capsule(), fill: true))
                .focused(focusKey, equals: "\(arrival.requestId)-play")
            Button(action: close) { xmark.frame(width: 64, height: 64) }
                .buttonStyle(ArrivalFocusStyle(shape: Circle()))
                .focused(focusKey, equals: "\(arrival.requestId)-close")
                .accessibilityLabel(Text("Ausblenden"))
        }
        .padding(.vertical, DesktopArrival.inset)
        .padding(.horizontal, DesktopArrival.inset)
        .frame(maxHeight: .infinity)
        .background(shape.fill(Theme.area))
        .overlay(depthWash)
        #else
        HStack(spacing: DesktopArrival.inset) {
            info
                .contentShape(Rectangle())
                .onTapGesture(perform: tap)
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isButton)
                .accessibilityAction(.default, tap)
            Button(action: play) {
                playLabel
                    .foregroundStyle(Theme.font)
                    .padding(.horizontal, 12)
                    .frame(height: 30)
                    .background(Theme.groupsArea, in: Capsule())
                    .modifier(HoverWash(shape: Capsule()))
            }
            .buttonStyle(Theme.PressButton())
            Button(action: close) {
                xmark.modifier(HoverWash(shape: Circle())).contentShape(Circle())
            }
            .buttonStyle(Theme.PressButton())
            .accessibilityLabel(Text("Ausblenden"))
        }
        .padding(.vertical, DesktopArrival.inset)
        .padding(.leading, DesktopArrival.inset)
        .padding(.trailing, 8)
        .frame(maxHeight: .infinity)
        .background(shape.fill(Theme.area))
        .overlay(shape.fill(Theme.font.opacity(hover && interactive ? 0.05 : 0)).allowsHitTesting(false))
        .overlay(depthWash)
        .contentShape(shape)
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.12), value: hover)
        #endif
    }

    /// Behind the front card the card is lifted toward the text colour (dark on dark disappeared) with a hairline,
    /// so the peeking edge reads in both looks.
    private var depthWash: some View {
        ZStack {
            shape.fill(Theme.font.opacity(0.10 * Double(min(depth, 2))))
            shape.strokeBorder(Theme.font.opacity(0.16 * Double(min(depth, 1))), lineWidth: 1)
        }
        .allowsHitTesting(false)
    }
}

#if os(tvOS)
/// A focusable control of the arrival card: lifts and lightens while focused.
private struct ArrivalFocusStyle<S: Shape>: ButtonStyle {
    let shape: S
    var fill = false
    @Environment(\.isFocused) private var focused

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Theme.font)
            .background(shape.fill(Theme.groupsArea.opacity(fill ? 1 : 0)))
            .background(shape.fill(Theme.font.opacity(focused ? 0.18 : 0)))
            .scaleEffect(focused ? 1.05 : 1)
            .animation(Theme.focusAnimation, value: focused)
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}
#else
/// Mac hover: a light wash toward the text colour.
private struct HoverWash<S: Shape>: ViewModifier {
    let shape: S
    @State private var hover = false

    func body(content: Content) -> some View {
        content
            .overlay(shape.fill(Theme.font.opacity(hover ? 0.12 : 0)).allowsHitTesting(false))
            .onHover { hover = $0 }
            .animation(.easeOut(duration: 0.12), value: hover)
    }
}
#endif

/// The card before it exists: the same shape, tone, peek and hairline, quiet bars where the poster, the two lines and
/// the pill will be, a slow faint light over them (nothing at Reduce Motion). Laid out by the real, invisible cards.
private struct DesktopArrivalSkeleton: View {
    let count: Int

    var body: some View {
        let behind = min(count - 1, DesktopArrival.shownBehind)
        ZStack(alignment: .top) {
            ForEach(Array((0...max(behind, 0)).reversed()), id: \.self) { depth in
                let shape = RoundedRectangle(cornerRadius: DesktopArrival.corner, style: .continuous)
                shape.fill(Theme.area)
                    .overlay(shape.fill(Theme.font.opacity(0.10 * Double(depth))))
                    .overlay(shape.strokeBorder(Theme.font.opacity(depth > 0 ? 0.16 : 0), lineWidth: 1))
                    .overlay { if depth == 0 { bars } }
                    .frame(height: DesktopArrival.card)
                    .scaleEffect(1 - 0.05 * CGFloat(depth), anchor: .bottom)
                    .offset(y: CGFloat(depth) * DesktopArrival.peek)
            }
        }
        .frame(height: DesktopArrivalMetrics.height(count: count, open: false), alignment: .top)
        .frame(maxWidth: .infinity, alignment: .top)
        .padding(.horizontal, 0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var bars: some View {
        let p = DesktopArrival.poster
        let s = DesktopArrival.subSize
        let shapes = HStack(spacing: DesktopArrival.inset) {
            RoundedRectangle(cornerRadius: 6, style: .continuous).frame(width: p.width, height: p.height)
            VStack(alignment: .leading, spacing: 8) {
                Capsule().frame(width: s * 7, height: s * 0.9)
                Capsule().frame(width: s * 4, height: s * 0.7)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Capsule().frame(width: s * 6, height: s * 2.2)
            Color.clear.frame(width: s * 2, height: 1)
        }
        .padding(DesktopArrival.inset)
        return shapes
            .foregroundStyle(Theme.groupsArea)
            .overlay { DesktopSkeletonLight().mask(shapes) }
    }
}

private struct DesktopSkeletonLight: View {
    @State private var moved = false

    var body: some View {
        GeometryReader { box in
            LinearGradient(colors: [.clear, Theme.font.opacity(0.08), .clear], startPoint: .leading, endPoint: .trailing)
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
