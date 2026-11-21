import JellyfinKit
import SwiftlyCore
import SwiftUI

// **The player's menus on Apple TV** (design "Swiftly-Player-Menues-2", TV frames 20 to 27, and the player bar's TV frame).
//
// The core builds every level (`PlayerMenusModel`, via the shared `PlayerMenuSession` / `PlayerMenuSpecs`); this file only
// draws a `MenuLevelSpec` for ten feet and the remote: 72 pt rows, white focus with dark text, one box that takes the place of
// the bar's capsule (top right; the season box hangs under the pill, top left). Menu goes one level back, then closes.
// "Zeit anpassen": left / right steps the time by 0.1 s without a focused button.

enum TVMenuMetric {
    static let width: CGFloat = 600
    static let wide: CGFloat = 640
    static let row: CGFloat = 72
    static let pad: CGFloat = 24
    static let boxPad: CGFloat = 12
    static let radius: CGFloat = 28
    static let rowRadius: CGFloat = 16
    static let label: CGFloat = 30
    static let detail: CGFloat = 24
    static let glyph: CGFloat = 28
    static let pill: CGFloat = 64
    static let top: CGFloat = 60
    static let side: CGFloat = 80
}

// MARK: - The layer

/// The menu over the player: nothing mounted while no menu is open (it stays for the close motion).
struct TVPlayerMenuLayer: View {
    let session: PlayerMenuSession
    let host: PlayerMenuHost
    /// "Problem melden" is not on Apple TV.
    var canReport = false
    /// Called after a row picked an audio or subtitle track: the box closes at once, as in Apple's players (Back stays the way
    /// out of the box without a choice). The host closes through its own path, so focus returns to the bar button that opened it.
    var closeAfterPick: () -> Void = {}
    @State private var shown = false

    var body: some View {
        // The host's closures first, so the core reads fresh inputs below.
        let _ = { session.host = host }()
        if let kind = session.kind, kind != .folgen, let model = session.model {
            let menus = model.menus
            let current = session.navigator.current
            let level = current.flatMap { session.level($0) } ?? PlayerMenuSession.root(kind)
            let built = PlayerMenuSpecs(menus: menus, tab: session.tab, canReport: canReport)
                .build(level, isRoot: current == nil)
            let hangsFromPill = kind == .seasons
            TVMenuBox(spec: built.spec, wide: level == .tracks(tab: .subtitles) || level == .tracks(tab: .audio)) { act($0, built) }
                .id(built.spec.id)
                .transition(.opacity)
                .scaleEffect(shown && session.isOpen ? 1 : 0.96, anchor: hangsFromPill ? .topLeading : .topTrailing)
                .opacity(shown && session.isOpen ? 1 : 0)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                // The season box hangs under the Folgen box's first row, its left edge in line with the Folgen box's.
                .padding(.top, hangsFromPill ? TVMenuMetric.top + TVMenuMetric.boxPad + TVMenuMetric.row + 8 : TVMenuMetric.top)
                .padding(.trailing, TVMenuMetric.side + (hangsFromPill ? TVFolgenMetric.width - TVMenuMetric.width : 0))
                .onAppear { withAnimation(Motion.menuOpen) { shown = true } }
                .onChange(of: session.isOpen) { _, open in
                    withAnimation(open ? Motion.menuOpen : Motion.menuClose) { shown = open }
                }
                .animation(Motion.menuSwitch, value: built.spec.id)
        }
    }

    private func act(_ action: MenuAction, _ built: PlayerMenuBuilt) {
        func press(_ id: String) { if let core = built.actions[id] { session.press(core) } }
        switch action {
        case .back: session.back()
        case let .segment(id): withAnimation(Motion.menuOpen) { session.tab = id == "audio" ? .audio : .subtitles }
        case .search: break
        case let .select(id):
            press(id)
            // Only a track choice closes the box; other rows (speed, sleep, quality) keep it open to show the new check mark.
            if let core = built.actions[id], case let .player(intent) = core {
                switch intent {
                case .selectAudio, .selectSubtitle: closeAfterPick()
                default: break
                }
            }
        case let .footer(id), let .toggle(id, _): press(id)
        case let .capsule(id, value): press("\(id):\(value)")
        case let .step(ms): press(ms < 0 ? "earlier" : "later")
        case .reset: press("reset")
        }
    }
}

/// **The Folgen box** (`PlayerMenuKind.folgen`): the episodes (or chapters) panel of the same menu session as the other boxes,
/// so it opens, closes and is swapped for another menu with the same motion, and Back and the focus return treat it alike.
/// The content is the host's; the season list hangs under its pill as a second box (`TVPlayerMenuLayer` with its own session).
struct TVFolgenLayer<Content: View>: View {
    let session: PlayerMenuSession
    @ViewBuilder let content: (PlayerMenuPanelTab) -> Content
    @State private var shown = false

    var body: some View {
        if session.kind == .folgen {
            content(session.panelTab)
                .opacity(shown && session.isOpen ? 1 : 0)
                .scaleEffect(shown && session.isOpen ? 1 : 0.96, anchor: .topTrailing)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .padding(.top, TVMenuMetric.top)
                .padding(.trailing, TVMenuMetric.side)
                .onAppear { withAnimation(Motion.menuOpen) { shown = true } }
                .onChange(of: session.isOpen) { _, open in
                    withAnimation(open ? Motion.menuOpen : Motion.menuClose) { shown = open }
                }
                .allowsHitTesting(session.isOpen)
        }
    }
}

// MARK: - The box

struct TVMenuBox: View {
    let spec: MenuLevelSpec
    let wide: Bool
    let act: (MenuAction) -> Void
    @FocusState private var focus: String?
    @State private var listHeight: CGFloat = 0

    var body: some View {
        VStack(spacing: 0) {
            if let backTitle = spec.backTitle {
                TVMenuButton(action: { act(.back) }) { lit in
                    HStack(spacing: 14) {
                        // Same ink as the title beside it: without one the chevron stayed white on the white focused row.
                        Image(icon: "chevron.left", size: TVMenuMetric.detail)
                            .font(.app(size: TVMenuMetric.detail, weight: .semibold))
                            .foregroundStyle(lit ? Theme.reason : Theme.fontQuiet)
                        tvText(backTitle, lit ? Theme.reason : Theme.fontQuiet)
                    }
                }
                .focused($focus, equals: "back")
            }
            if let segments = spec.segments { segmentsView(segments) }
            if !spec.rows.isEmpty {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 0) {
                        ForEach(spec.rows) { rowView($0) }
                    }
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { listHeight = $0 }
                }
                .scrollClipDisabled()
                .frame(height: min(max(listHeight, 1), spec.fixedRows.isEmpty && spec.step == nil ? 760 : 560))
                // Under the back row or the segments the list fades out in a strip, so a scrolled row never runs over them.
                .modifier(FadeUnderHeaderIf(header: spec.backTitle != nil || spec.segments != nil))
            }
            if let step = spec.step { stepView(step) }
            ForEach(spec.fixedRows) { rowView($0) }
            ForEach(spec.footer, id: \.id) { footerView($0) }
        }
        .padding(TVMenuMetric.boxPad)
        .frame(width: wide ? TVMenuMetric.wide : TVMenuMetric.width)
        .background(RoundedRectangle(cornerRadius: TVMenuMetric.radius, style: .continuous).fill(Theme.groupsArea))
        .focusSection()
        .task(id: spec.id) { await LayersFocus.put { if focus == nil { focus = initialFocus } } }
    }

    /// The first thing the remote should land on: the chosen row of a list, the stepper, else the first row.
    private var initialFocus: String? {
        if spec.step != nil { return "step" }
        for row in spec.rows {
            if case let .check(id, _, _, selected, _, enabled) = row, selected, enabled { return id }
        }
        for row in spec.rows + spec.fixedRows {
            switch row {
            case let .value(id, _, _, _, _), let .check(id, _, _, _, _, _), let .toggle(id, _, _), let .device(id, _, _, _, _, _),
                 let .action(id, _, _, _): return id
            case let .capsules(id, _, items, selected, _): return "\(id):\(selected ?? items.first?.id ?? "")"
            default: continue
            }
        }
        if let segments = spec.segments { return "seg:\(segments.selected)" }
        return spec.footer.first?.id
    }

    // MARK: Rows

    @ViewBuilder
    private func rowView(_ row: MenuRowSpec) -> some View {
        switch row {
        case let .value(id, label, value, enabled, loading):
            TVMenuButton(enabled: enabled, action: { act(.select(id)) }) { lit in
                HStack(spacing: 12) {
                    tvText(label, lit ? Theme.reason : Theme.font).layoutPriority(1)
                    Spacer(minLength: 8)
                    if loading {
                        Loader(size: 28, strength: 3)
                    } else if let value {
                        tvText(value, lit ? Theme.reason.opacity(0.7) : Theme.fontVeryQuiet, weight: .regular)
                    }
                    Image(icon: "chevron.right", size: TVMenuMetric.detail)
                        .font(.app(size: TVMenuMetric.detail, weight: .semibold))
                        .foregroundStyle(lit ? Theme.reason.opacity(0.7) : Theme.fontVeryQuiet)
                }
            }
            .focused($focus, equals: id)
        case let .check(id, label, detail, selected, loading, enabled):
            TVMenuButton(enabled: enabled, action: { act(.select(id)) }) { lit in
                HStack(spacing: 14) {
                    ZStack {
                        if selected {
                            Image(icon: "checkmark", size: TVMenuMetric.glyph)
                                .font(.app(size: TVMenuMetric.glyph, weight: .semibold))
                                .foregroundStyle(lit ? Theme.reason : Theme.font)
                        }
                    }
                    .frame(width: 36)
                    tvText(label, lit ? Theme.reason : Theme.font).layoutPriority(1)
                    Spacer(minLength: 8)
                    if loading {
                        Loader(size: 28, strength: 3)
                    } else if let detail {
                        tvText(detail, lit ? Theme.reason.opacity(0.7) : Theme.fontVeryQuiet, size: TVMenuMetric.detail, weight: .regular)
                    }
                }
            }
            .focused($focus, equals: id)
        case let .toggle(id, label, isOn):
            TVMenuButton(action: { act(.toggle(id, !isOn)) }) { lit in
                HStack(spacing: 12) {
                    tvText(label, lit ? Theme.reason : Theme.font).layoutPriority(1)
                    Spacer(minLength: 8)
                    tvText(isOn ? String(localized: "An") : String(localized: "Aus"),
                           lit ? Theme.reason.opacity(0.7) : Theme.fontVeryQuiet, weight: .regular)
                }
            }
            .focused($focus, equals: id)
        case let .capsules(id, caption, items, selected, _):
            VStack(alignment: .leading, spacing: 10) {
                tvText(caption, Theme.fontQuiet, size: TVMenuMetric.detail, weight: .regular)
                    .padding(.horizontal, TVMenuMetric.pad)
                HStack(spacing: 10) {
                    ForEach(items) { item in
                        TVPill(label: item.label, selected: item.id == selected) { act(.capsule(id, item.id)) }
                            .focused($focus, equals: "\(id):\(item.id)")
                    }
                }
                .padding(.horizontal, TVMenuMetric.pad / 2)
            }
            .padding(.vertical, 14)
            .focusSection()
        case let .device(id, name, kind, loading, enabled, symbol):
            TVMenuButton(enabled: enabled, action: { act(.select(id)) }) { lit in
                HStack(spacing: 14) {
                    Image(icon: symbol, size: TVMenuMetric.glyph + 4)
                        .font(.app(size: TVMenuMetric.glyph, weight: .semibold))
                        .foregroundStyle(lit ? Theme.reason : Theme.font)
                    tvText(name, lit ? Theme.reason : Theme.font).layoutPriority(1)
                    Spacer(minLength: 8)
                    if loading {
                        Loader(size: 28, strength: 3)
                    } else {
                        tvText(kind, lit ? Theme.reason.opacity(0.7) : Theme.fontVeryQuiet, size: TVMenuMetric.detail, weight: .regular)
                    }
                }
            }
            .focused($focus, equals: id)
        case let .person(name, status):
            HStack {
                tvText(name, Theme.font)
                Spacer(minLength: 8)
                tvText(status, Theme.fontVeryQuiet, size: TVMenuMetric.detail, weight: .regular)
            }
            .padding(.horizontal, TVMenuMetric.pad)
            .frame(height: TVMenuMetric.row)
        case let .action(id, label, symbol, destructive):
            TVMenuButton(action: { act(.select(id)) }) { lit in
                HStack(spacing: 14) {
                    if let symbol {
                        Image(icon: symbol, size: TVMenuMetric.glyph + 4)
                            .font(.app(size: TVMenuMetric.glyph, weight: .semibold))
                    }
                    tvText(label, lit ? Theme.reason : (destructive ? Theme.warning : Theme.font))
                    Spacer(minLength: 0)
                }
                .foregroundStyle(lit ? Theme.reason : (destructive ? Theme.warning : Theme.font))
            }
            .focused($focus, equals: id)
        case let .section(text):
            tvText(text, Theme.fontQuiet, size: TVMenuMetric.detail, weight: .semibold)
                .padding(.horizontal, TVMenuMetric.pad).frame(height: 56, alignment: .leading)
        case let .hint(text):
            tvText(text, Theme.fontVeryQuiet, size: TVMenuMetric.detail, weight: .regular, lines: 3)
                .padding(.horizontal, TVMenuMetric.pad).padding(.vertical, 12)
        case .divider:
            Rectangle().fill(Color.white.opacity(0.08)).frame(height: 2)
                .padding(.horizontal, TVMenuMetric.pad).padding(.vertical, 8)
        }
    }

    private func footerView(_ button: MenuFooterButton) -> some View {
        TVMenuButton(action: { act(.footer(button.id)) }) { lit in
            HStack(spacing: 14) {
                Image(icon: button.symbol, size: TVMenuMetric.glyph + 4)
                    .font(.app(size: TVMenuMetric.glyph, weight: .semibold))
                tvText(button.label, lit ? Theme.reason : (button.quiet ? Theme.fontQuiet : Theme.font))
                Spacer(minLength: 0)
            }
            .foregroundStyle(lit ? Theme.reason : (button.quiet ? Theme.fontQuiet : Theme.font))
        }
        .focused($focus, equals: button.id)
    }

    // MARK: Segments (Untertitel | Ton)

    private func segmentsView(_ segments: MenuSegmentsSpec) -> some View {
        HStack(spacing: 6) {
            ForEach(segments.items) { item in
                TVSegment(label: item.label, selected: item.id == segments.selected) { act(.segment(item.id)) }
                    .focused($focus, equals: "seg:\(item.id)")
            }
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: TVMenuMetric.rowRadius + 4, style: .continuous).fill(Color.white.opacity(0.06)))
        .padding(.bottom, 8)
        .focusSection()
    }

    // MARK: Zeit anpassen

    @State private var stepSide = 1

    private func stepView(_ step: MenuStepSpec) -> some View {
        VStack(spacing: 14) {
            tvText(step.caption, Theme.fontQuiet, size: TVMenuMetric.detail, weight: .regular, lines: 2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
            tvText(step.value, Theme.font, size: 56, weight: .bold).frame(maxWidth: .infinity)
            HStack(spacing: 10) {
                stepButton(step.earlierLabel, lit: focus == "step" && stepSide < 0)
                stepButton(step.laterLabel, lit: focus == "step" && stepSide > 0)
            }
            .focusable()
            .focused($focus, equals: "step")
            // Left / right steps the time, with or without a button in view (design: 0,1 s per press).
            .onMoveCommand { direction in
                switch direction {
                case .left: stepSide = -1; act(.step(ms: step.earlierMs))
                case .right: stepSide = 1; act(.step(ms: step.laterMs))
                default: break
                }
            }
            if step.canReset {
                TVMenuButton(action: { act(.reset) }) { lit in
                    tvText(step.resetLabel, lit ? Theme.reason : Theme.fontQuiet).frame(maxWidth: .infinity)
                }
                .focused($focus, equals: "reset")
            }
        }
        .padding(.vertical, 12)
    }

    private func stepButton(_ label: String, lit: Bool) -> some View {
        tvText(label, lit ? Theme.reason : Theme.font)
            .frame(maxWidth: .infinity).frame(height: TVMenuMetric.pill)
            .background(RoundedRectangle(cornerRadius: TVMenuMetric.pill / 2, style: .continuous)
                .fill(lit ? Color.white : Color.white.opacity(0.10)))
            .scaleEffect(lit ? Theme.focusMagnifier : 1)
            .animation(Theme.focusAnimation, value: lit)
    }
}

func tvText(_ text: String, _ color: Color, size: CGFloat = TVMenuMetric.label, weight: Font.Weight = .semibold,
                    lines: Int = 1) -> some View {
    Text(verbatim: text).font(.app(size: size, weight: weight)).foregroundStyle(color)
        .lineLimit(lines).truncationMode(.tail).fixedSize(horizontal: false, vertical: lines > 1)
}

// MARK: - Focusable parts

/// Draws nothing itself: the label decides, and the style only presses.
private struct TVFlat: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.scaleEffect(configuration.isPressed ? 0.98 : 1)
    }
}

/// A 72 pt row: white with dark text when focused (1.03, lift), otherwise nothing.
struct TVMenuButton<Content: View>: View {
    var enabled = true
    let action: () -> Void
    @ViewBuilder let content: (Bool) -> Content

    var body: some View {
        Button(action: action) { Face(content: content) }
            .buttonStyle(TVFlat())
            .disabled(!enabled)
            .opacity(enabled ? 1 : 0.4)
    }

    private struct Face: View {
        @Environment(\.isFocused) private var focused
        let content: (Bool) -> Content

        var body: some View {
            content(focused)
                .padding(.horizontal, TVMenuMetric.pad)
                .frame(maxWidth: .infinity, minHeight: TVMenuMetric.row, alignment: .leading)
                .background {
                    RoundedRectangle(cornerRadius: TVMenuMetric.rowRadius, style: .continuous)
                        .fill(focused ? Color.white : .clear)
                        .lift(focused)
                }
                .scaleEffect(focused ? Theme.focusMagnifierWide : 1)
                .animation(Theme.focusAnimation, value: focused)
                .contentShape(Rectangle())
        }
    }
}

/// A capsule of a row of choices (sleep minutes, speed steps, subtitle look).
private struct TVPill: View {
    let label: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) { Face(label: label, selected: selected) }.buttonStyle(TVFlat())
    }

    private struct Face: View {
        @Environment(\.isFocused) private var focused
        let label: String
        let selected: Bool

        var body: some View {
            tvText(label, focused ? Theme.reason : Theme.font)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity).frame(height: TVMenuMetric.pill)
                .background(RoundedRectangle(cornerRadius: TVMenuMetric.pill / 2, style: .continuous)
                    .fill(focused ? Color.white : (selected ? Color.white.opacity(0.22) : Color.white.opacity(0.08)))
                    .lift(focused))
                .scaleEffect(focused ? Theme.focusMagnifier : 1)
                .animation(Theme.focusAnimation, value: focused)
        }
    }
}

private struct TVSegment: View {
    let label: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) { Face(label: label, selected: selected) }.buttonStyle(TVFlat())
    }

    private struct Face: View {
        @Environment(\.isFocused) private var focused
        let label: String
        let selected: Bool

        var body: some View {
            tvText(label, focused ? Theme.reason : (selected ? Theme.font : Theme.fontQuiet))
                .frame(maxWidth: .infinity).frame(height: TVMenuMetric.pill - 8)
                .background(RoundedRectangle(cornerRadius: TVMenuMetric.rowRadius, style: .continuous)
                    .fill(focused ? Color.white : (selected ? Color.white.opacity(0.14) : .clear))
                    .lift(focused))
                .animation(Theme.focusAnimation, value: focused)
        }
    }
}

// MARK: - The bar: pill and capsule (player-leiste SPEC, Apple TV)

extension View {
    /// One glass for every part of the bar: black 18 % over an ultra-thin material (dark), hairline edge, no shadow.
    func tvBarGlass<S: InsettableShape>(_ shape: S) -> some View {
        background {
            ZStack {
                Rectangle().fill(.ultraThinMaterial).environment(\.colorScheme, .dark)
                Theme.scrimGlass
            }
            .clipShape(shape)
        }
        .overlay { shape.strokeBorder(Theme.glassEdge, lineWidth: 1) }
    }
}

/// One half of the capsule (88 x 88, glyph 38).
struct TVBarHalf: View {
    let symbol: String
    let label: LocalizedStringKey
    var open = false
    let action: () -> Void

    var body: some View {
        Button(action: action) { Face(symbol: symbol, open: open) }
            .buttonStyle(TVFlat())
            .accessibilityLabel(Text(label))
    }

    private struct Face: View {
        @Environment(\.isFocused) private var focused
        let symbol: String
        let open: Bool

        var body: some View {
            Image(icon: symbol, size: 38)
                .font(.app(size: 38, weight: .medium))
                .foregroundStyle(focused ? Theme.reason : Theme.font)
                .frame(width: 88, height: 88)
                .background {
                    Circle().fill(focused ? Color.white : (open ? Color.white.opacity(0.18) : .clear)).lift(focused)
                }
                .scaleEffect(focused ? Theme.focusMagnifierSmall : 1)
                .animation(Theme.focusAnimation, value: focused)
        }
    }
}

/// The capsule: Folgen, Untertitel and Einstellungen side by side in one glass (no X and no Übergeben on Apple TV: Menu closes).
struct TVBarCapsule<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 0) { content }
            .tvBarGlass(Capsule())
    }
}

/// `fadesUnderHeader` only when something sits above the list.
struct FadeUnderHeaderIf: ViewModifier {
    let header: Bool

    @ViewBuilder func body(content: Content) -> some View {
        if header { content.fadesUnderHeader(20) } else { content }
    }
}
