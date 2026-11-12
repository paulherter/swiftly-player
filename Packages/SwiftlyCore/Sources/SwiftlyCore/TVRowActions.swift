/// **What the Apple TV and Android TV detail row shows before "…"**, taken from the core's `moreMenu()`:
/// "Shuffle" (series only) and "Watch together" get a button of their own, when the core offers them at all.
/// The panel keeps the rest, so nothing is offered twice. "Watched" is not in the core's menu (the host
/// adds it), so it is always in the row and never in the panel.
public struct TVRowActions: Equatable {
    public let shuffle: MenuEntry?
    public let together: MenuEntry?
    /// What stays in the "…" panel, in the core's order.
    public let panel: [MenuEntry]

    public init(menu: [MenuEntry]) {
        shuffle = menu.first { $0.kind == .shuffle }
        together = menu.first { $0.kind == .together }
        panel = menu.filter { $0.kind != .shuffle && $0.kind != .together }
    }
}
