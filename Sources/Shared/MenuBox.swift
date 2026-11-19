import SwiftUI

// **The player's menu box** (design "Am Knopf", 17.11.): a small solid box anchored to the button that
// opened it. Levels slide inside the box (a back row leads out), the box keeps its width and place, its
// height follows the level. Long lists scroll ONLY inside the list area of a level; the rows around it
// (back row, segments, "Zeit anpassen", footer) stay put and the box never grows past `maxHeight`.
//
// iPhone look first; the metrics sit in `MenuMetric` so Mac and tvOS can bring their own.
// Included in the iPhone/iPad (and Mac) targets.

enum MenuMetric {
    static let width: CGFloat = 300
    /// The episode box is wider (a still beside each title).
    static let folgenWidth: CGFloat = 372
    /// What its content is tall (the box adds its padding).
    static let folgenHeight: CGFloat = 309
    static let row: CGFloat = 44
    static let compactRow: CGFloat = 36
    /// A box shorter than this uses compact rows (design: 44 pt rows even on a landscape phone, whose box is about 300 tall); a safe height shorter than `shortScreen` lets the box use all of it.
    static let compactBelow: CGFloat = 250
    static let shortScreen: CGFloat = 480
    static let pad: CGFloat = 12
    static let boxPad: CGFloat = 6
    static let radius: CGFloat = 16
    static let rowRadius: CGFloat = 10
    /// Free space from the screen edge and from the button.
    static let margin: CGFloat = 12
    static let gap: CGFloat = 6
    /// A level slides this far when it comes or goes.
    static let slide: CGFloat = 12
}

// MARK: - Max height from the available space

private struct MenuMaxHeightKey: EnvironmentKey { static let defaultValue: CGFloat = 400 }

private struct MenuRowKey: EnvironmentKey { static let defaultValue: CGFloat = MenuMetric.row }

extension EnvironmentValues {
    /// The height of one row: compact when the box is short (a phone in landscape), so more rows show.
    var menuRow: CGFloat {
        get { self[MenuRowKey.self] }
        set { self[MenuRowKey.self] = newValue }
    }
    /// The most the content of the current level may be tall (box padding already taken off).
    var menuMaxHeight: CGFloat {
        get { self[MenuMaxHeightKey.self] }
        set { self[MenuMaxHeightKey.self] = newValue }
    }
}

private struct MenuLevelIDKey: EnvironmentKey { static let defaultValue = "" }
private struct MenuNavigatorKey: EnvironmentKey { static let defaultValue: MenuNavigator? = nil }

extension EnvironmentValues {
    /// Which level of the box a row belongs to ("" is the root); the live level registers its keys.
    var menuLevelID: String {
        get { self[MenuLevelIDKey.self] }
        set { self[MenuLevelIDKey.self] = newValue }
    }
    var menuNavigator: MenuNavigator? {
        get { self[MenuNavigatorKey.self] }
        set { self[MenuNavigatorKey.self] = newValue }
    }
}

enum MenuSizing {
    /// **One rule for every device size.** Free height = safe-area height below the button; the box takes at most
    /// 72 % of the safe height (a third of the width of a 16:9 picture is what a short list needs; a long list
    /// scrolls instead of growing) and never less than three rows plus what is fixed.
    static func maxBoxHeight(safeHeight: CGFloat, anchorBottom: CGFloat, safeTop: CGFloat) -> CGFloat {
        let below = safeHeight - (anchorBottom - safeTop) - MenuMetric.gap - MenuMetric.margin
        // A short screen (a phone in landscape) gives the box all the room below the button: 72 % would leave 2 list rows.
        let cap = safeHeight < MenuMetric.shortScreen ? below : min(below, safeHeight * 0.72)
        return max(MenuMetric.row * 3 + 2 * MenuMetric.boxPad, cap)
    }

    /// Compact rows when the box is short.
    static func rowHeight(maxHeight: CGFloat) -> CGFloat {
        maxHeight < MenuMetric.compactBelow ? MenuMetric.compactRow : MenuMetric.row
    }

    static func boxWidth(safeWidth: CGFloat, preferred: CGFloat = MenuMetric.width) -> CGFloat {
        min(preferred, safeWidth - 2 * MenuMetric.margin)
    }
}

// MARK: - The level layout (fixed top, scrolling list, fixed bottom)

enum MenuSlot { case top, list, bottom }
private struct MenuSlotKey: LayoutValueKey { static let defaultValue: MenuSlot = .list }

/// Top and bottom keep their natural height; the list gets what is left up to `maxHeight`, else its own height.
private struct MenuLevelLayout: Layout {
    var maxHeight: CGFloat

    private func parts(_ subviews: Subviews, _ width: CGFloat) -> (top: CGFloat, list: CGFloat, bottom: CGFloat) {
        let size = ProposedViewSize(width: width, height: nil)
        var top: CGFloat = 0, list: CGFloat = 0, bottom: CGFloat = 0
        for view in subviews {
            let h = view.sizeThatFits(size).height
            switch view[MenuSlotKey.self] {
            case .top: top += h
            case .list: list += h
            case .bottom: bottom += h
            }
        }
        return (top, min(list, max(0, maxHeight - top - bottom)), bottom)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? MenuMetric.width
        let p = parts(subviews, width)
        return CGSize(width: width, height: p.top + p.list + p.bottom)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let p = parts(subviews, bounds.width)
        var y = bounds.minY
        for slot in [MenuSlot.top, .list, .bottom] {
            for view in subviews where view[MenuSlotKey.self] == slot {
                let h = slot == .list ? p.list : view.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil)).height
                view.place(at: CGPoint(x: bounds.minX, y: y), anchor: .topLeading,
                           proposal: ProposedViewSize(width: bounds.width, height: h))
                y += h
            }
        }
    }
}

/// One level: `top` and `bottom` stay put, `list` scrolls when it does not fit.
struct MenuLevel<Top: View, List: View, Bottom: View>: View {
    @Environment(\.menuMaxHeight) private var maxHeight
    let top: Top
    let list: List
    let bottom: Bottom

    init(@ViewBuilder top: () -> Top, @ViewBuilder list: () -> List, @ViewBuilder bottom: () -> Bottom) {
        self.top = top(); self.list = list(); self.bottom = bottom()
    }

    var body: some View {
        MenuLevelLayout(maxHeight: maxHeight) {
            VStack(spacing: 0) { top }.layoutValue(key: MenuSlotKey.self, value: .top)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 0) { list; Color.clear.frame(height: 0).id("menu-end") }
                }
                #if DEBUG
                .onReceive(NotificationCenter.default.publisher(for: Notification.Name("swiftly.debug.menuScrollEnd"))) { _ in
                    withAnimation { proxy.scrollTo("menu-end", anchor: .bottom) }
                }
                #endif
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollIndicators(.automatic)
            .layoutValue(key: MenuSlotKey.self, value: .list)
            VStack(spacing: 0) { bottom }.layoutValue(key: MenuSlotKey.self, value: .bottom)
        }
    }
}

// MARK: - The box

private struct SlideFade: ViewModifier {
    let x: CGFloat
    let opacity: Double
    func body(content: Content) -> some View {
        content.offset(x: Theme.motionReduced ? 0 : x).opacity(opacity)
    }
}

/// The box: a solid dark surface with the levels inside. `root` is the first level; `level(id)` makes a pushed one.
struct MenuBox<Root: View, Pushed: View>: View {
    let navigator: MenuNavigator
    let width: CGFloat
    let maxHeight: CGFloat
    /// A new key swaps the root content with a cross-fade (another menu from another button).
    let contentKey: String
    let root: Root
    let pushed: (String) -> Pushed

    @State private var heights: [String: CGFloat] = [:]

    init(navigator: MenuNavigator, width: CGFloat, maxHeight: CGFloat, contentKey: String = "",
         @ViewBuilder root: () -> Root, @ViewBuilder pushed: @escaping (String) -> Pushed) {
        self.navigator = navigator; self.width = width; self.maxHeight = maxHeight; self.contentKey = contentKey
        self.root = root(); self.pushed = pushed
    }

    private var shown: [String] { [""] + navigator.path + (navigator.leaving.map { [$0] } ?? []) }
    private var depth: Int { navigator.path.count }

    private func place(_ id: String) -> (x: CGFloat, o: Double, live: Bool) {
        let level = id.isEmpty ? 0 : (navigator.path.firstIndex(of: id).map { $0 + 1 } ?? depth + 1)
        if level == depth { return (0, 1, true) }
        return (level < depth ? -MenuMetric.slide : MenuMetric.slide, 0, false)
    }

    var body: some View {
        let inner = width - 2 * MenuMetric.boxPad
        ZStack(alignment: .topLeading) {
            ForEach(shown, id: \.self) { id in
                let p = place(id)
                Group { id.isEmpty ? AnyView(root.id(contentKey).transition(.opacity)) : AnyView(pushed(id)) }
                    .environment(\.menuLevelID, id)
                    .frame(width: inner)
                    .fixedSize(horizontal: false, vertical: true)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { heights[id] = $0 }
                    .offset(x: Theme.motionReduced ? 0 : p.x)
                    .opacity(p.o)
                    .allowsHitTesting(p.live)
                    .accessibilityHidden(!p.live)
                    .transition(.modifier(active: SlideFade(x: MenuMetric.slide, opacity: 0),
                                          identity: SlideFade(x: 0, opacity: 1)))
            }
        }
        .foregroundStyle(Theme.font)
        .environment(\.menuNavigator, navigator)
        .environment(\.menuMaxHeight, max(0, maxHeight - 2 * MenuMetric.boxPad))
        .environment(\.menuRow, MenuSizing.rowHeight(maxHeight: maxHeight))
        .frame(width: inner, height: heights[navigator.current ?? ""], alignment: .topLeading)
        .clipped()
        .animation(Motion.menuOpen, value: heights[navigator.current ?? ""])
        .padding(MenuMetric.boxPad)
        // A solid surface, no blur: the film stays as it is behind it.
        .background(Theme.groupsArea, in: RoundedRectangle(cornerRadius: MenuMetric.radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: MenuMetric.radius, style: .continuous).strokeBorder(Theme.margin, lineWidth: 1))
        .shadow(color: .black.opacity(0.4), radius: 16, y: 12)
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Anchoring to the button

/// Appear from the button: scale 0.92 → 1, opacity, y −6 → 0; the anchor is the button's centre on the box's top edge.
private struct MenuAppear: ViewModifier {
    let shown: Bool
    let anchor: UnitPoint
    func body(content: Content) -> some View {
        if Theme.motionReduced {
            content.opacity(shown ? 1 : 0)
        } else {
            content
                .scaleEffect(shown ? 1 : 0.92, anchor: anchor)
                .offset(y: shown ? 0 : -6)
                .opacity(shown ? 1 : 0)
        }
    }
}

/// Fills the screen it is laid over; draws the box under `anchor` (a frame in global coordinates) and closes on a tap beside it.
struct MenuPresenter<Root: View, Pushed: View>: View {
    let isOpen: Bool
    let anchor: CGRect
    let navigator: MenuNavigator
    let close: () -> Void
    /// Frames (global) the closing tap passes through to, e.g. the other buttons of the bar: a tap on one of them goes to
    /// that button (which swaps the menu) instead of only closing this one.
    var passThrough: [CGRect] = []
    /// Changes when the box's content is swapped for another menu (a switch from one button to the next): the old and the new
    /// content cross-fade while the box moves and resizes.
    var contentKey: String = ""
    /// The box's width; it animates when one menu turns into another of another width.
    var preferredWidth: CGFloat = MenuMetric.width
    let root: Root
    let pushed: (String) -> Pushed

    /// The box appears one frame AFTER it is mounted, so opening animates like closing does (a view mounted already "shown"
    /// would just be there).
    @State private var shown = false

    init(isOpen: Bool, anchor: CGRect, navigator: MenuNavigator, close: @escaping () -> Void,
         passThrough: [CGRect] = [], contentKey: String = "", preferredWidth: CGFloat = MenuMetric.width,
         @ViewBuilder root: () -> Root, @ViewBuilder pushed: @escaping (String) -> Pushed) {
        self.isOpen = isOpen; self.anchor = anchor; self.navigator = navigator; self.close = close
        self.passThrough = passThrough; self.contentKey = contentKey; self.preferredWidth = preferredWidth
        self.root = root(); self.pushed = pushed
    }

    var body: some View {
        GeometryReader { proxy in
            let origin = proxy.frame(in: .global).origin
            let safe = proxy.safeAreaInsets
            let size = proxy.size
            let width = MenuSizing.boxWidth(safeWidth: size.width - safe.leading - safe.trailing, preferred: preferredWidth)
            let local = anchor.offsetBy(dx: -origin.x, dy: -origin.y)
            let maxH = MenuSizing.maxBoxHeight(safeHeight: size.height - safe.top - safe.bottom,
                                               anchorBottom: local.maxY, safeTop: safe.top)
            // Right edge on the button's right edge, kept inside the safe area.
            let left = min(max(local.maxX - width, safe.leading + MenuMetric.margin),
                           size.width - safe.trailing - MenuMetric.margin - width)
            let unit = UnitPoint(x: min(max((local.midX - left) / width, 0), 1), y: 0)
            ZStack(alignment: .topLeading) {
                Color.clear
                    .contentShape(HolesShape(holes: passThrough.map { $0.offsetBy(dx: -origin.x, dy: -origin.y) }), eoFill: true)
                    .onTapGesture(perform: close)
                MenuBox(navigator: navigator, width: width, maxHeight: maxH, contentKey: contentKey, root: { root }, pushed: pushed)
                    .modifier(MenuAppear(shown: shown, anchor: unit))
                    .offset(x: left, y: local.maxY + MenuMetric.gap)
                    .animation(Motion.menuOpen, value: left)
                    .animation(Motion.menuOpen, value: local.maxY)
                    .animation(Motion.menuOpen, value: width)
                    .allowsHitTesting(isOpen)
            }
            .animation(shown ? Motion.menuOpen : Motion.menuClose, value: shown)
        }
        .allowsHitTesting(isOpen)
        .onAppear { shown = isOpen }
        .onChange(of: isOpen) { _, now in shown = now }
    }
}

/// The whole area minus some holes (even-odd), as a hit shape: taps in a hole go to what lies beneath.
private struct HolesShape: Shape {
    let holes: [CGRect]
    func path(in rect: CGRect) -> Path {
        var path = Path(rect)
        for hole in holes { path.addRect(hole) }
        return path
    }
}
