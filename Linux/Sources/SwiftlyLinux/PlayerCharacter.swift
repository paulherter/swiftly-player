import CGtk
import Foundation
import JellyfinKit

// MARK: - Player icons, shipped as SVG

/// **The player icons are SVG files in `Resources/icons/player`.**
///
/// Redrawn after the Mac symbols (`captions.bubble`, `rectangle.stack`,
/// `slider.horizontal.3`, fullscreen, `tv`, `xmark`, `gobackward`/`goforward`,
/// `pause.fill`/`play.fill`): thin round lines, no system symbols. Breeze and
/// Adwaita show something different for the same names, and GTK's recoloring
/// of symbolic SVGs fills paths instead of stroking them, so a line drawing
/// would arrive as a blob. The app therefore reads the files itself and
/// paints them with Cairo, identically on Linux and Windows.
///
/// Only a small fixed subset is understood: `path` (M L H V C A Z, also
/// relative), `rect` with `rx`, `circle`; `fill`, `stroke`, `stroke-width`,
/// `fill-rule` on the element or the root. `data-zahl="x y groesse"` on the
/// root says where a number belongs (`gobackward.10`).
enum SvgPreAdvice {
    enum PlayerCommand {
        case moveBy(Double, Double)
        case line(Double, Double)
        case curve(Double, Double, Double, Double, Double, Double)
        case arc(cx: Double, cy: Double, r: Double, from: Double, until: Double, uhrzeigersinn: Bool)
        case close
    }

    struct Form {
        let commands: [PlayerCommand]
        let fill: Bool
        let stroke: Double?
        let currentCurrent: Bool
    }

    struct Drawing {
        let width: Double
        let height: Double
        let shape: [Form]
        let figure: (x: Double, y: Double, size: Double)?
    }

    nonisolated(unsafe) private static var cache: [String: Drawing] = [:]
    nonisolated(unsafe) private static var reported: Set<String> = []

    static func drawing(_ name: String) -> Drawing? {
        if let already = cache[name] { return already }
        guard let path = Platform.bundled("icons/player/\(name).svg"),
              let text = try? String(contentsOfFile: path, encoding: .utf8),
              let z = read(text) else {
            if !reported.contains(name) {
                reported.insert(name)
                AppLog.writeOut("[Zeichen] fehlt: \(name).svg")
                fflush(nil)
            }
            return nil
        }
        cache[name] = z
        return z
    }

    // MARK: Parsing

    private static func attribute(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        guard let muster = try? NSRegularExpression(pattern: #"([A-Za-z_:][-A-Za-z0-9_:.]*)\s*=\s*"([^"]*)""#) else {
            return result
        }
        let ns = text as NSString
        for hit in muster.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            result[ns.substring(with: hit.range(at: 1))] = ns.substring(with: hit.range(at: 2))
        }
        return result
    }

    private static func read(_ text: String) -> Drawing? {
        guard let elementPattern = try? NSRegularExpression(pattern: #"<(svg|path|rect|circle)\b([^>]*)>"#) else {
            return nil
        }
        let ns = text as NSString
        var root: [String: String] = [:]
        var shape: [Form] = []
        var width = 24.0, height = 24.0
        var figure: (Double, Double, Double)?
        for hit in elementPattern.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let art = ns.substring(with: hit.range(at: 1))
            let a = attribute(ns.substring(with: hit.range(at: 2)))
            if art == "svg" {
                root = a
                if let vb = a["viewBox"] {
                    let w = numbers(vb)
                    if w.count == 4 { width = w[2]; height = w[3] }
                }
                if let z = a["data-zahl"] {
                    let w = numbers(z)
                    if w.count == 3 { figure = (w[0], w[1], w[2]) }
                }
                continue
            }
            func value(_ name: String) -> String? { a[name] ?? root[name] }
            let fill = (value("fill") ?? "currentColor") != "none"
            let lineAn = (value("stroke") ?? "none") != "none"
            let stroke = lineAn ? (value("stroke-width").flatMap(Double.init) ?? 1) : nil
            let justNow = value("fill-rule") == "evenodd"
            var commands: [PlayerCommand] = []
            switch art {
            case "path":
                commands = path(a["d"] ?? "")
            case "rect":
                let x = Double(a["x"] ?? "") ?? 0, y = Double(a["y"] ?? "") ?? 0
                let w = Double(a["width"] ?? "") ?? 0, h = Double(a["height"] ?? "") ?? 0
                let r = min(Double(a["rx"] ?? "") ?? 0, w / 2, h / 2)
                commands = [
                    .moveBy(x + r, y), .line(x + w - r, y),
                    .arc(cx: x + w - r, cy: y + r, r: r, from: -.pi / 2, until: 0, uhrzeigersinn: true),
                    .line(x + w, y + h - r),
                    .arc(cx: x + w - r, cy: y + h - r, r: r, from: 0, until: .pi / 2, uhrzeigersinn: true),
                    .line(x + r, y + h),
                    .arc(cx: x + r, cy: y + h - r, r: r, from: .pi / 2, until: .pi, uhrzeigersinn: true),
                    .line(x, y + r),
                    .arc(cx: x + r, cy: y + r, r: r, from: .pi, until: 1.5 * .pi, uhrzeigersinn: true),
                    .close,
                ]
            case "circle":
                let cx = Double(a["cx"] ?? "") ?? 0, cy = Double(a["cy"] ?? "") ?? 0
                let r = Double(a["r"] ?? "") ?? 0
                commands = [.moveBy(cx + r, cy),
                           .arc(cx: cx, cy: cy, r: r, from: 0, until: 2 * .pi, uhrzeigersinn: true),
                           .close]
            default:
                break
            }
            shape.append(Form(commands: commands, fill: fill, stroke: stroke, currentCurrent: justNow))
        }
        return Drawing(width: width, height: height, shape: shape,
                         figure: figure.map { (x: $0.0, y: $0.1, size: $0.2) })
    }

    private static func numbers(_ text: String) -> [Double] {
        text.split(whereSeparator: { $0 == " " || $0 == "," }).compactMap { Double($0) }
    }

    /// Splits `d` into commands with absolute coordinates.
    private static func path(_ d: String) -> [PlayerCommand] {
        // Character by character: a letter is a command, anything else a number.
        var parts: [String] = []
        var figure = ""
        func complete() { if !figure.isEmpty { parts.append(figure); figure = "" } }
        for z in d {
            if z.isLetter && z != "e" && z != "E" {
                complete(); parts.append(String(z))
            } else if z == " " || z == "," || z == "\n" || z == "\t" {
                complete()
            } else if z == "-" && !figure.isEmpty && !figure.hasSuffix("e") && !figure.hasSuffix("E") {
                complete(); figure = "-"
            } else if z == "." && figure.contains(".") {
                complete(); figure = "."
            } else {
                figure.append(z)
            }
        }
        complete()

        var commands: [PlayerCommand] = []
        var i = 0
        var command: Character = "M"
        var x = 0.0, y = 0.0, sx = 0.0, sy = 0.0
        func next() -> Double? {
            guard i < parts.count, let w = Double(parts[i]) else { return nil }
            i += 1
            return w
        }
        while i < parts.count {
            if let b = parts[i].first, b.isLetter {
                command = b
                i += 1
                if b == "Z" || b == "z" {
                    commands.append(.close)
                    x = sx; y = sy
                    continue
                }
            }
            let relative = command.isLowercase
            let dx = relative ? x : 0, dy = relative ? y : 0
            switch command.uppercased() {
            case "M":
                guard let a = next(), let b = next() else { return commands }
                x = a + dx; y = b + dy; sx = x; sy = y
                commands.append(.moveBy(x, y))
                command = relative ? "l" : "L"
            case "L":
                guard let a = next(), let b = next() else { return commands }
                x = a + dx; y = b + dy
                commands.append(.line(x, y))
            case "H":
                guard let a = next() else { return commands }
                x = a + dx
                commands.append(.line(x, y))
            case "V":
                guard let b = next() else { return commands }
                y = b + dy
                commands.append(.line(x, y))
            case "C":
                guard let x1 = next(), let y1 = next(), let x2 = next(),
                      let y2 = next(), let x3 = next(), let y3 = next() else { return commands }
                commands.append(.curve(x1 + dx, y1 + dy, x2 + dx, y2 + dy, x3 + dx, y3 + dy))
                x = x3 + dx; y = y3 + dy
            case "A":
                guard let rx = next(), next() != nil, next() != nil,
                      let large = next(), let sweep = next(),
                      let ex = next(), let ey = next() else { return commands }
                let zx = ex + dx, zy = ey + dy
                if let b = arc(x, y, zx, zy, r: rx, large: large != 0, sweep: sweep != 0) {
                    commands.append(b)
                } else {
                    commands.append(.line(zx, zy))
                }
                x = zx; y = zy
            default:
                // Unknown command: do not guess, discard the rest.
                return commands
            }
        }
        return commands
    }

    /// Arc from endpoint to center form (SVG 1.1, F.6.5), only for `rx == ry`
    /// without rotation; the shipped files draw nothing more.
    private static func arc(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double,
                              r within: Double, large: Bool, sweep: Bool) -> PlayerCommand? {
        guard within > 0, x1 != x2 || y1 != y2 else { return nil }
        let xs = (x1 - x2) / 2, ys = (y1 - y2) / 2
        let d2 = xs * xs + ys * ys
        var r = abs(within)
        if d2 > r * r { r = sqrt(d2) }
        let preCharacter: Double = large != sweep ? 1 : -1
        let k = preCharacter * sqrt(max(0, (r * r - d2) / d2))
        let cx = k * ys + (x1 + x2) / 2
        let cy = -k * xs + (y1 + y2) / 2
        let from = atan2(y1 - cy, x1 - cx)
        let until = atan2(y2 - cy, x2 - cx)
        return .arc(cx: cx, cy: cy, r: r, from: from, until: until, uhrzeigersinn: sweep)
    }
}

// MARK: - The widget

/// A glyph from ``Svgvorrat`` in a fixed box and one color.
///
/// `nudge()` is the Mac's `.symbolEffect(.bounce)`; `figure` is the number in
/// `gobackward.10`/`goforward.10`.
final class PlayerCharacter: @unchecked Sendable {
    fileprivate var lives = true
    fileprivate var name: String
    fileprivate var figure: Int?
    fileprivate var color: (Double, Double, Double, Double)
    fileprivate var impulse = 0.0
    let display: Widget

    init(_ name: String, size: Int32, figure: Int? = nil,
         color: (Double, Double, Double, Double) = (1, 1, 1, 1)) {
        self.name = name
        self.figure = figure
        self.color = color
        let inputField: Widget! = gtk_drawing_area_new()
        gtk_widget_add_css_class(inputField, "swiftly-blank")
        gtk_drawing_area_set_content_width(asCharacter(inputField), size)
        gtk_drawing_area_set_content_height(asCharacter(inputField), size)
        gtk_widget_set_halign(inputField, GTK_ALIGN_CENTER)
        gtk_widget_set_valign(inputField, GTK_ALIGN_CENTER)
        gtk_widget_set_can_target(inputField, 0)
        display = inputField!
        gtk_drawing_area_set_draw_func(asCharacter(inputField), playerCharacterDraw,
                                       Unmanaged.passUnretained(self).toOpaque(), nil)
        // The field holds the object: without this reference it would be gone
        // before GTK paints for the first time.
        let itself = Unmanaged.passRetained(self)
        signal(inputField, "destroy") {
            itself.takeUnretainedValue().lives = false
            itself.release()
        }
    }

    func setName(_ new: String) {
        guard new != name else { return }
        name = new
        gtk_widget_queue_draw(display)
    }

    func setNumber(_ new: Int?) {
        guard new != figure else { return }
        figure = new
        gtk_widget_queue_draw(display)
    }

    /// Like `PlayMarker.setzen`: while playing, the button shows pause.
    func setDown(_ running: Bool) {
        setName(running ? "pause" : "play")
        // **The button is named for what it does**, as on the Mac (`PlayerScreen`,
        // `runsNow ? "Anhalten" : "Abspielen"`). The button is the glyph's
        // parent; the name is updated wherever the glyph changes, also on the
        // space bar.
        if lives, let button = gtk_widget_get_parent(display) {
            caption(button, running ? translated("Anhalten") : translated("Abspielen"))
        }
    }

    func nudge() {
        // No bounce with reduced motion (Mac: `.symbolEffect(.bounce,
        // value: Stil.motionReduced ? 0 : takt)`).
        guard !motionReduced() else { return }
        runningCount(on: display, duration: 0.3) { [weak self] e in
            guard let self, self.lives else { return }
            self.impulse = sin(Double.pi * e)
            gtk_widget_queue_draw(self.display)
        } done: { [weak self] in
            guard let self, self.lives else { return }
            self.impulse = 0
            gtk_widget_queue_draw(self.display)
        }
    }
}

nonisolated(unsafe) private let playerCharacterDraw: @convention(c) (
    UnsafeMutablePointer<GtkDrawingArea>?, OpaquePointer?, Int32, Int32, gpointer?
) -> Void = { _, cr, width, height, data in
    guard let cr, let data else { return }
    let z = Unmanaged<PlayerCharacter>.fromOpaque(data).takeUnretainedValue()
    guard z.lives, let image = SvgPreAdvice.drawing(z.name) else { return }
    let w = Double(width), h = Double(height)
    let s = min(w / image.width, h / image.height)
    cairo_save(cr)
    cairo_translate(cr, w / 2, h / 2)
    let f = 1 + 0.16 * z.impulse
    cairo_scale(cr, s * f, s * f)
    cairo_translate(cr, -image.width / 2, -image.height / 2)
    cairo_set_source_rgba(cr, z.color.0, z.color.1, z.color.2, z.color.3)
    cairo_set_line_cap(cr, CAIRO_LINE_CAP_ROUND)
    cairo_set_line_join(cr, CAIRO_LINE_JOIN_ROUND)
    for form in image.shape {
        cairo_new_path(cr)
        for command in form.commands {
            switch command {
            case let .moveBy(x, y): cairo_move_to(cr, x, y)
            case let .line(x, y): cairo_line_to(cr, x, y)
            case let .curve(x1, y1, x2, y2, x3, y3): cairo_curve_to(cr, x1, y1, x2, y2, x3, y3)
            case let .arc(cx, cy, r, from, until, clock):
                if clock { cairo_arc(cr, cx, cy, r, from, until) }
                else { cairo_arc_negative(cr, cx, cy, r, from, until) }
            case .close: cairo_close_path(cr)
            }
        }
        if form.fill {
            cairo_set_fill_rule(cr, form.currentCurrent ? CAIRO_FILL_RULE_EVEN_ODD : CAIRO_FILL_RULE_WINDING)
            if form.stroke != nil { cairo_fill_preserve(cr) } else { cairo_fill(cr) }
        }
        if let stroke = form.stroke {
            cairo_set_line_width(cr, stroke)
            cairo_stroke(cr)
        }
    }
    if let figure = z.figure, let place = image.figure {
        let text = "\(figure)"
        cairo_select_font_face(cr, "sans-serif", CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_BOLD)
        cairo_set_font_size(cr, place.size)
        var mass = cairo_text_extents_t()
        cairo_text_extents(cr, text, &mass)
        cairo_move_to(cr, place.x - mass.width / 2 - mass.x_bearing,
                      place.y - mass.height / 2 - mass.y_bearing)
        cairo_show_text(cr, text)
    }
    cairo_restore(cr)
}

// MARK: - Soft fade in and out

/// The two easing curves the player needs: the same Bézier curves as
/// SwiftUI's `.easeOut` and `.easeInOut`, plus `linear` for reduced motion
/// (``motionReduced()``).
enum IdLine {
    case easeOut, easeInOut, easeIn, linear

    /// The curves live in the package (`FadeTimes`) so the Mac and GTK compute
    /// the same.
    func value(_ t: Double) -> Double {
        switch self {
        case .linear: t
        case .easeOut: FadeTimes.easeOut(t)
        case .easeInOut: FadeTimes.easeInOut(t)
        case .easeIn: FadeTimes.easeIn(t)
        }
    }
}

private final class FadeRun {
    let from: Double
    let to: Double
    let duration: Double
    let curve: IdLine
    let number: Int
    let done: (() -> Void)?
    /// From the first frame, not from the request; see ``Run``.
    var beginning: Date?
    init(from: Double, to: Double, duration: Double, curve: IdLine, number: Int,
         done: (() -> Void)?) {
        self.from = from; self.to = to; self.duration = duration
        self.curve = curve; self.number = number; self.done = done
    }
}

/// Per widget only the newest run counts: a new `blenden` replaces the old
/// one, starting from the **current** value, so nothing jumps.
nonisolated(unsafe) private var fadeState: [UnsafeMutableRawPointer: Int] = [:]
nonisolated(unsafe) private var fadeCounter = 0

nonisolated(unsafe) private let blendTick: @convention(c) (
    UnsafeMutablePointer<GtkWidget>?, OpaquePointer?, gpointer?
) -> gboolean = { widget, _, data in
    guard let widget, let data else { return 0 }
    let l = Unmanaged<FadeRun>.fromOpaque(data).takeUnretainedValue()
    let key = UnsafeMutableRawPointer(widget)
    guard fadeState[key] == l.number else { return 0 }
    let now = Date()
    let beginning = l.beginning ?? now
    l.beginning = beginning
    let t = min(now.timeIntervalSince(beginning) / l.duration, 1)
    gtk_widget_set_opacity(widget, l.from + (l.to - l.from) * l.curve.value(t))
    if t >= 1 {
        fadeState[key] = nil
        l.done?()
        return 0
    }
    return 1
}

nonisolated(unsafe) private let blendShare: @convention(c) (gpointer?) -> Void = { data in
    guard let data else { return }
    Unmanaged<FadeRun>.fromOpaque(data).release()
}

/// Fades a widget to `target` at the window's frame rate. If it is not visible
/// (not mapped), the value is set immediately: there would be no frame clock,
/// and a run would hang.
func crossfade(_ widget: Widget!, on target: Double, duration: Double,
             curve: IdLine = .easeOut, done: (() -> Void)? = nil) {
    guard let widget else { return }
    // **With reduced motion every fade is short and linear**, like
    // `Theme.linearReduced` on the Mac. It stays a fade: nothing should appear
    // abruptly anyway.
    let reduced = motionReduced()
    let duration = reduced ? min(duration, Theme.timeReduced) : duration
    let curve: IdLine = reduced ? .linear : curve
    let key = UnsafeMutableRawPointer(widget)
    fadeCounter += 1
    let number = fadeCounter
    fadeState[key] = number
    let from = gtk_widget_get_opacity(widget)
    guard duration > 0, abs(from - target) > 0.001, gtk_widget_get_mapped(widget) != 0 else {
        fadeState[key] = nil
        gtk_widget_set_opacity(widget, target)
        done?()
        return
    }
    let run = FadeRun(from: from, to: target, duration: duration, curve: curve,
                         number: number, done: done)
    _ = gtk_widget_add_tick_callback(widget, blendTick,
                                     Unmanaged.passRetained(run).toOpaque(), blendShare)
}

// MARK: - The skip marker

/// The circle on the left or right when skipping with the arrow keys, copied
/// from the Mac's `Sprungmarke`: 108 round, black 45 %, the glyph at 32 inside
/// and "10 s" below.
final class JumpMark {
    let display: Widget
    let symbolText: PlayerCharacter
    let text: Widget

    init(back: Bool) {
        let circle = stack(GTK_ORIENTATION_VERTICAL, spacing: 6)
        gtk_widget_add_css_class(circle, "swiftly-sprungmarke")
        gtk_widget_set_size_request(circle, 108, 108)
        symbolText = PlayerCharacter(back ? "back" : "forward", size: 36)
        gtk_widget_set_margin_top(symbolText.display, 18)
        append(circle, symbolText.display)
        text = label("", style: "swiftly-sprungtext")
        gtk_widget_set_halign(text, GTK_ALIGN_CENTER)
        append(circle, text)
        gtk_widget_set_can_target(circle, 0)
        gtk_widget_set_opacity(circle, 0)
        display = circle!
    }
}
