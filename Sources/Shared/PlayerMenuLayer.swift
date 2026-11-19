import JellyfinKit
import SwiftlyCore
import SwiftUI

// **The menus of the player's buttons** (Ton & Untertitel, Optionen, Übergeben an …, the season button), drawn with
// the shared menu box.
//
// The core builds every level (`PlayerMenusModel`, `PlayerMenus`): which rows exist, their order, their words and what
// a press does. This file owns no list of options. It turns a core page into a `MenuLevelSpec` (`PlayerMenuSpecs`),
// fills the inputs only the host knows (group, subtitle look, seasons, devices) and carries out the host actions.

/// The anchors: where each opening button sits (global frame).
struct PlayerMenuAnchors {
    var frames: [PlayerMenuKind: CGRect] = [:]
    /// The whole top-right capsule: the Folgen box hangs from its lower right edge.
    var capsule: CGRect = .zero
    /// The Folgen button (episodes, or chapters of a film): not a menu of this layer, but it takes the place of an open one.
    var folgen: CGRect = .zero
}

extension View {
    /// Reports the button's frame so the box can grow from it.
    func menuAnchor(_ kind: PlayerMenuKind, into anchors: Binding<PlayerMenuAnchors>) -> some View {
        onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { anchors.wrappedValue.frames[kind] = $0 }
    }

    /// Reports the Folgen button's frame, so a tap on it while a menu is open reaches it (see `PlayerMenuLayer.holes`).
    func folgenAnchor(into anchors: Binding<PlayerMenuAnchors>) -> some View {
        onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { anchors.wrappedValue.folgen = $0 }
    }
}

// MARK: - The layer

/// The menu layer over the player: nothing mounted while closed.
struct PlayerMenuLayer: View {
    let session: PlayerMenuSession
    let anchors: PlayerMenuAnchors
    let host: PlayerMenuHost
    let canReport: Bool
    var canLock = true
    /// The content of the episode box (`.folgen`) for the tab it opened at; only the screen that has such a box gives it.
    var folgen: ((PlayerMenuPanelTab) -> AnyView)? = nil
    /// Read here so the box redraws when the switch flips.
    @AppStorage("technikschild") private var techBadge = false

    var body: some View {
        // The host's closures first, so the core reads fresh inputs below.
        let _ = {
            var host = host
            let base = host.inputs
            let badge = techBadge
            host.inputs = { var inputs = base(); inputs.techBadge = badge; return inputs }
            session.host = host
        }()
        if let kind = session.kind, let model = session.model {
            let menus = model.menus
MenuPresenter(isOpen: session.isOpen, anchor: anchor(for: kind), navigator: session.navigator,
                          close: { session.close() }, passThrough: holes(for: kind), contentKey: "\(kind)",
                          preferredWidth: kind == .folgen ? MenuMetric.folgenWidth : MenuMetric.width, root: {
                if kind == .folgen, let folgen { folgen(session.panelTab) } else {
                    levelView(PlayerMenuSession.root(kind), menus: menus, isRoot: true)
                }
            }, pushed: { id in
                if let level = session.level(id) { levelView(level, menus: menus, isRoot: false) }
            })
        }
    }

    /// Where a box hangs from: its own button; the episode box from the capsule's lower right edge, as it always did.
    private func anchor(for kind: PlayerMenuKind) -> CGRect {
        guard kind == .folgen else { return anchors.frames[kind] ?? .zero }
        let c = anchors.capsule, f = anchors.folgen
        guard c != .zero, f != .zero else { return f }
        return CGRect(x: f.minX, y: c.minY, width: c.maxX - f.minX, height: c.height)
    }

    /// The bar's own buttons stay tappable under the closing backdrop, Folgen among them: one tap swaps the open menu for the
    /// episode box (without its hole the backdrop took the tap and only closed the menu). The panel's season button has no
    /// bar beside it.
    private func holes(for kind: PlayerMenuKind) -> [CGRect] {
        guard kind != .seasons else { return [] }
        let buttons = [PlayerMenuKind.tracks, .settings, .handoff].compactMap { anchors.frames[$0] }
        return anchors.folgen == .zero ? buttons : buttons + [anchors.folgen]
    }

    private func levelView(_ level: PlayerMenuLevel, menus: PlayerMenus, isRoot: Bool) -> some View {
        let built = PlayerMenuSpecs(menus: menus, tab: session.tab, canReport: canReport, canLock: canLock)
            .build(level, isRoot: isRoot)
        return MenuLevelView(spec: built.spec) { act($0, built) }
    }

    private func act(_ action: MenuAction, _ built: PlayerMenuBuilt) {
        func press(_ id: String) { if let core = built.actions[id] { session.press(core) } }
        switch action {
        case .back: session.back()
        case let .segment(id): withAnimation(Motion.menuOpen) { session.tab = id == "audio" ? .audio : .subtitles }
        case .search: press("search")
        case let .footer(id), let .select(id), let .toggle(id, _): press(id)
        case let .capsule(id, value): press("\(id):\(value)")
        case let .step(ms): press(ms < 0 ? "earlier" : "later")
        case .reset: press("reset")
        }
    }
}
