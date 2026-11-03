import JellyfinKit
import SwiftUI

// MARK: - How a server kind presents itself

// **Everything a screen says about a kind, in one place.**
//
// The picker, the sign-in pages and later the TV and the Mac all name the kind,
// describe it in one sentence and show its mark. Kept here, outside the iOS-only
// `Style.swift`, so the tvOS and macOS targets can list this file and draw the same
// marks without a second copy.
//
// **No foreign logos, and nothing that looks like one.** Jellyfin, Plex and Emby are
// named as text; the marks are our own, drawn from one stroke on one grid. Each was
// checked against its kind's real logo: no triangle for Jellyfin, no chevron for Plex (and nothing that reads as the share symbol),
// no hexagon or play shape for Emby.

extension ServerKind {
    /// The product name. Never translated: it is a name, and it is what people search
    /// for on their server's start page.
    var displayName: String {
        switch self {
        case .jellyfin: "Jellyfin"
        case .plex: "Plex"
        case .emby: "Emby"
        }
    }

    /// The name where people choose or read it: Plex and Emby carry "(Beta)" until they
    /// have run long enough in the wild. Never used for matching, only for showing.
    var shownName: String {
        switch self {
        case .jellyfin: displayName
        case .plex, .emby: "\(displayName) (Beta)"
        }
    }

    /// One sentence under the name: what happens next, not what the kind is. Someone
    /// choosing already knows which server they run; what they do not know is whether
    /// they will need an address, a password or a browser.
    var pitch: LocalizedStringKey {
        switch self {
        case .jellyfin: "Adresse rein und anmelden, oder per Quick Connect ganz ohne Passwort."
        case .plex: "Einmal bei Plex anmelden, die App findet deine Server."
        case .emby: "Adresse von deinem Server rein, dann Name und Passwort."
        }
    }

    /// The kind's own color, used only on its mark: Jellyfin blue, Plex amber, Emby
    /// green. A hue, not a logo; the drawing stays ours.
    var tint: Color {
        switch self {
        case .jellyfin: Color(red: 0.0, green: 0.64, blue: 0.86)
        case .plex: Color(red: 0.90, green: 0.63, blue: 0.05)
        case .emby: Color(red: 0.32, green: 0.71, blue: 0.29)
        }
    }

    /// The order on the picker. Jellyfin first: it is what the app grew up with and
    /// what most people who already use it run.
    static let pickerOrder: [ServerKind] = [.jellyfin, .plex, .emby]
}

// MARK: - The marks

/// **The mark of a server kind**: a bare stroke drawing, no tile behind it.
///
/// One stroke weight for all three, scaled with the size, so they read as one family
/// at 28 on the picker and at 44 on a sign-in page. The color is the caller's: white
/// at rest, quiet when the card is disabled. Never the accent; the mark is an identity,
/// not a state.
struct ServerKindMark: View {
    let kind: ServerKind
    var size: CGFloat = 28
    /// Nil draws the kind's own color.
    var color: Color?

    var body: some View {
        let color = color ?? kind.tint
        return shape
            .stroke(color, style: StrokeStyle(lineWidth: size * ServerKindMark.weight,
                                              lineCap: .round, lineJoin: .round))
            .overlay { dots.fill(color) }
            .frame(width: size, height: size)
            // The name stands next to it as text; read aloud, the mark is nothing.
            .accessibilityHidden(true)
    }

    /// 1.8 on a 24 grid: the weight of SF Symbols' regular at that size.
    static let weight: CGFloat = 1.8 / 24

    private var shape: AnyShape {
        switch kind {
        case .jellyfin: AnyShape(BellMark())
        case .plex: AnyShape(OrbitMark())
        case .emby: AnyShape(StackMark())
        }
    }

    /// The filled parts. Only Plex has some; the others draw an empty path.
    private var dots: AnyShape {
        kind == .plex ? AnyShape(OrbitDots()) : AnyShape(EmptyMark())
    }
}

/// Points on the 24 grid, scaled into the frame.
private func grid(_ rect: CGRect) -> (CGFloat, CGFloat) -> CGPoint {
    let unit = min(rect.width, rect.height) / 24
    return { x, y in CGPoint(x: rect.minX + x * unit, y: rect.minY + y * unit) }
}

/// **Jellyfin: a bell with three strands.** The name is a jellyfish; the logo is not,
/// so the animal is ours to draw. Open at the bottom, three strands of equal length
/// with one soft bend each.
private struct BellMark: Shape {
    func path(in rect: CGRect) -> Path {
        let p = grid(rect)
        let unit = min(rect.width, rect.height) / 24
        var path = Path()
        // The bell: a half circle, its rim a straight line.
        path.addArc(center: p(12, 12), radius: 8 * unit,
                    startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
        path.closeSubpath()
        // Three strands, the middle one a touch longer.
        for (x, end) in [(CGFloat(8), CGFloat(19.5)), (12, 21), (16, 19.5)] {
            path.move(to: p(x, 12))
            path.addQuadCurve(to: p(x, end), control: p(x + 2, (12 + end) / 2))
        }
        return path
    }
}

/// **Plex: an orbit.** An account that knows its servers: the core is the account,
/// the point on the ring is what the app finds on it. The ring opens where the point
/// sits, so the two never touch. An earlier draft (ring plus two linked points) read
/// as the share symbol and was dropped.
private struct OrbitMark: Shape {
    func path(in rect: CGRect) -> Path {
        let p = grid(rect)
        let unit = min(rect.width, rect.height) / 24
        var path = Path()
        // Clockwise in screen terms from just past the point round to just before it.
        path.addArc(center: p(12, 12), radius: 8.5 * unit,
                    startAngle: .degrees(-18), endAngle: .degrees(-72), clockwise: false)
        return path
    }
}

private struct OrbitDots: Shape {
    func path(in rect: CGRect) -> Path {
        let p = grid(rect)
        let unit = min(rect.width, rect.height) / 24
        var path = Path()
        let satellite = p(12 + 8.5 * cos(-.pi / 4), 12 + 8.5 * sin(-.pi / 4))
        for (c, r) in [(p(12, 12), 3.0 * unit), (satellite, 2.2 * unit)] {
            path.addEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
        }
        return path
    }
}

/// **Emby: two frames, one behind the other.** A library you keep yourself: the front
/// frame whole, the one behind only as the edge that shows.
private struct StackMark: Shape {
    func path(in rect: CGRect) -> Path {
        let p = grid(rect)
        let unit = min(rect.width, rect.height) / 24
        var path = Path()
        path.addRoundedRect(in: CGRect(origin: p(3.5, 8.5), size: CGSize(width: 12 * unit, height: 12 * unit)),
                            cornerSize: CGSize(width: 3 * unit, height: 3 * unit), style: .continuous)
        // The frame behind: top and right edge, joined by its corner.
        path.move(to: p(8.5, 3.5))
        path.addLine(to: p(17.5, 3.5))
        path.addQuadCurve(to: p(20.5, 6.5), control: p(20.5, 3.5))
        path.addLine(to: p(20.5, 15.5))
        return path
    }
}

private struct EmptyMark: Shape {
    func path(in rect: CGRect) -> Path { Path() }
}
