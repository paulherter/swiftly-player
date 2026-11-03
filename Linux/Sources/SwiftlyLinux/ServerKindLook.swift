import CGtk
import Foundation
import JellyfinKit

// MARK: - How a server kind presents itself

// **Everything a screen says about a kind, in one place.**
//
// The counterpart of `Sources/Shared/ServerKindLook.swift`: that file is not reachable from
// here (this app only builds on `JellyfinKit`), so names, sentences, colors and marks are
// repeated and have to follow it. The marks are our own drawings on a 24 grid, one stroke
// weight for all three. No foreign logos, and nothing that looks like one.

extension ServerKind {
    /// The product name. Never translated: it is a name.
    var displayName: String {
        switch self {
        case .jellyfin: "Jellyfin"
        case .plex: "Plex"
        case .emby: "Emby"
        }
    }

    /// The name where people choose or read it. Plex and Emby carry "(Beta)" until they
    /// have run long enough in the wild. Only for showing, never for matching.
    var shownName: String {
        switch self {
        case .jellyfin: displayName
        case .plex, .emby: "\(displayName) (Beta)"
        }
    }

    /// One sentence under the name: what happens next, not what the kind is.
    var pitch: String {
        switch self {
        case .jellyfin: translated("Adresse rein und anmelden, oder per Quick Connect ganz ohne Passwort.")
        case .plex: translated("Einmal bei Plex anmelden, die App findet deine Server.")
        case .emby: translated("Adresse von deinem Server rein, dann Name und Passwort.")
        }
    }

    /// The kind's own color, only used on its mark: Jellyfin blue, Plex amber, Emby green.
    var tint: (red: Double, green: Double, blue: Double) {
        switch self {
        case .jellyfin: (0.0, 0.64, 0.86)
        case .plex: (0.90, 0.63, 0.05)
        case .emby: (0.32, 0.71, 0.29)
        }
    }

    /// The order on the picker. Jellyfin first.
    static let pickerOrder: [ServerKind] = [.jellyfin, .plex, .emby]
}

// MARK: - The marks

/// The mark of a kind as a drawing area. A bare stroke drawing, no tile behind it.
final class KindMark: @unchecked Sendable {
    fileprivate var lives = true
    fileprivate let kind: ServerKind
    fileprivate let size: Double
    /// `nil` draws the kind's own color.
    fileprivate var color: (Double, Double, Double, Double)?
    let display: Widget

    init(kind: ServerKind, size: Int, color: (Double, Double, Double, Double)? = nil) {
        self.kind = kind
        self.size = Double(size)
        self.color = color
        let area: Widget! = gtk_drawing_area_new()
        gtk_widget_add_css_class(area, "swiftly-blank")
        gtk_drawing_area_set_content_width(asCharacter(area), Int32(size))
        gtk_drawing_area_set_content_height(asCharacter(area), Int32(size))
        gtk_widget_set_halign(area, GTK_ALIGN_CENTER)
        gtk_widget_set_valign(area, GTK_ALIGN_CENTER)
        display = area!
        gtk_drawing_area_set_draw_func(asCharacter(area), kindMarkDraw,
                                       Unmanaged.passUnretained(self).toOpaque(), nil)
        // The area holds the mark: the draw callback gets it unretained, see `JumpCharacter`.
        signal(area, "destroy") { self.lives = false }
    }
}

nonisolated(unsafe) private let kindMarkDraw: @convention(c) (
    UnsafeMutablePointer<GtkDrawingArea>?, OpaquePointer?, Int32, Int32, gpointer?
) -> Void = { _, cr, width, height, data in
    guard let cr, let data else { return }
    let mark = Unmanaged<KindMark>.fromOpaque(data).takeUnretainedValue()
    guard mark.lives else { return }

    let unit = min(Double(width), Double(height)) / 24
    let ox = (Double(width) - 24 * unit) / 2, oy = (Double(height) - 24 * unit) / 2
    func p(_ x: Double, _ y: Double) -> (Double, Double) { (ox + x * unit, oy + y * unit) }
    // SwiftUI draws quadratic curves; cairo has cubic ones only.
    func quad(from a: (Double, Double), control c: (Double, Double), to b: (Double, Double)) {
        cairo_curve_to(cr,
                       a.0 + 2.0 / 3 * (c.0 - a.0), a.1 + 2.0 / 3 * (c.1 - a.1),
                       b.0 + 2.0 / 3 * (c.0 - b.0), b.1 + 2.0 / 3 * (c.1 - b.1),
                       b.0, b.1)
    }

    let tint = mark.kind.tint
    let color = mark.color ?? (tint.red, tint.green, tint.blue, 1)
    cairo_set_source_rgba(cr, color.0, color.1, color.2, color.3)
    cairo_set_line_width(cr, 1.8 * unit)
    cairo_set_line_cap(cr, CAIRO_LINE_CAP_ROUND)
    cairo_set_line_join(cr, CAIRO_LINE_JOIN_ROUND)
    let arc = Double.pi / 180

    switch mark.kind {
    case .jellyfin:
        // A bell with three strands: half circle, its rim a straight line.
        let c = p(12, 12)
        cairo_new_path(cr)
        cairo_arc(cr, c.0, c.1, 8 * unit, 180 * arc, 360 * arc)
        cairo_close_path(cr)
        cairo_stroke(cr)
        for (x, end) in [(8.0, 19.5), (12.0, 21.0), (16.0, 19.5)] {
            let a = p(x, 12)
            cairo_move_to(cr, a.0, a.1)
            quad(from: a, control: p(x + 2, (12 + end) / 2), to: p(x, end))
            cairo_stroke(cr)
        }
    case .plex:
        // An orbit: the ring opens where the satellite sits.
        let c = p(12, 12)
        cairo_new_path(cr)
        cairo_arc(cr, c.0, c.1, 8.5 * unit, -18 * arc, 288 * arc)
        cairo_stroke(cr)
        let satellite = p(12 + 8.5 * cos(-45 * arc), 12 + 8.5 * sin(-45 * arc))
        cairo_new_path(cr)
        cairo_arc(cr, c.0, c.1, 3.0 * unit, 0, 2 * Double.pi)
        cairo_fill(cr)
        cairo_new_path(cr)
        cairo_arc(cr, satellite.0, satellite.1, 2.2 * unit, 0, 2 * Double.pi)
        cairo_fill(cr)
    case .emby:
        // Two frames, one behind the other.
        let r = 3 * unit
        let left = p(3.5, 8.5), side = 12 * unit
        cairo_new_path(cr)
        cairo_arc(cr, left.0 + side - r, left.1 + r, r, -90 * arc, 0)
        cairo_arc(cr, left.0 + side - r, left.1 + side - r, r, 0, 90 * arc)
        cairo_arc(cr, left.0 + r, left.1 + side - r, r, 90 * arc, 180 * arc)
        cairo_arc(cr, left.0 + r, left.1 + r, r, 180 * arc, 270 * arc)
        cairo_close_path(cr)
        cairo_stroke(cr)
        let start = p(8.5, 3.5), corner = p(17.5, 3.5)
        cairo_move_to(cr, start.0, start.1)
        cairo_line_to(cr, corner.0, corner.1)
        quad(from: corner, control: p(20.5, 3.5), to: p(20.5, 6.5))
        let end = p(20.5, 15.5)
        cairo_line_to(cr, end.0, end.1)
        cairo_stroke(cr)
    }
}
