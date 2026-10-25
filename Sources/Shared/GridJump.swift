import SwiftUI

// What every grid with a letter strip shares, on iPhone, iPad, Apple TV and the Mac:
// the jump request, the tiles on screen and the anchor that jumps without moving
// sideways. The strips themselves differ per platform (touch, focus, pointer).

/// A request to scroll a grid to one title; the serial lets the same title be asked
/// for twice in a row.
struct ScrollJump: Equatable {
    let id: String
    let serial: Int
}

/// The tiles a grid has on screen. **A plain box, not observed**: it changes on every
/// scroll, and only the letter derived from it is state.
final class OnScreenTiles {
    var ids: Set<String> = []
}

extension ScrollJump {
    /// **Where to hold a tile when jumping to it: its top at the top, and not moved sideways.**
    ///
    /// `scrollTo` lines up the anchor point of the tile with the same point of the scroll
    /// view, horizontally too, even in a vertical scroll view: `.top` centred the tile,
    /// `.topLeading` pushed it to the screen edge, and the whole grid stayed shifted by
    /// that much. The horizontal part is therefore chosen so the tile's place in the grid
    /// is already the lined-up one: for a tile starting at `x0` with width `w` in a view of
    /// width `W`, `x = x0 / (W - w)`.
    ///
    /// - Parameters:
    ///   - index: The tile's position in the grid.
    ///   - columns: Columns of the grid.
    ///   - leading, trailing: The grid's side margins.
    ///   - usable: The grid's own width, between the margins.
    ///   - spacing: Between two columns.
    static func anchor(index: Int, columns: Int, leading: CGFloat, trailing: CGFloat,
                       usable: CGFloat, spacing: CGFloat) -> UnitPoint {
        guard columns > 0 else { return .top }
        let tile = (usable - CGFloat(columns - 1) * spacing) / CGFloat(columns)
        let x0 = leading + CGFloat(index % columns) * (tile + spacing)
        return anchor(tileStart: x0, tileWidth: tile, viewport: leading + usable + trailing)
    }

    /// The same for a grid whose tiles have a fixed width (the Mac's adaptive columns):
    /// the tile starts at `tileStart` in a scroll view `viewport` wide.
    static func anchor(tileStart: CGFloat, tileWidth: CGFloat, viewport: CGFloat) -> UnitPoint {
        guard viewport - tileWidth > 0 else { return .top }
        return UnitPoint(x: tileStart / (viewport - tileWidth), y: 0)
    }
}
