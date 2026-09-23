import CGtk
import Foundation

// MARK: - Die Zeichen des Players, als SVG mitgeliefert

/// **Die Symbole des Players liegen als SVG in `Ressourcen/icons/player`.**
///
/// Nachgezeichnet nach den Mac-Symbolen (`captions.bubble`, `rectangle.stack`,
/// `slider.horizontal.3`, Vollbild, `xmark`, `gobackward`/`goforward`,
/// `pause.fill`/`play.fill`) — dünne runde Linien, keine Systemsymbole. Breeze
/// und Adwaita zeigen für dieselben Namen etwas anderes, und GTKs Umfärbung
/// symbolischer SVGs füllt Pfade, statt sie zu ziehen: eine Linienzeichnung
/// käme dort als Klecks an. Deshalb liest die App die Dateien selbst und malt
/// sie mit Cairo — auf Linux und Windows gleich.
///
/// Verstanden wird eine kleine, feste Teilmenge: `path` (M L H V C A Z, auch
/// relativ), `rect` mit `rx`, `circle`; `fill`, `stroke`, `stroke-width`,
/// `fill-rule` am Element oder an der Wurzel. `data-zahl="x y groesse"` an der
/// Wurzel sagt, wo eine Zahl hineingehört (`gobackward.10`).
enum Svgvorrat {
    enum Befehl {
        case bewege(Double, Double)
        case linie(Double, Double)
        case kurve(Double, Double, Double, Double, Double, Double)
        case bogen(cx: Double, cy: Double, r: Double, von: Double, bis: Double, uhrzeigersinn: Bool)
        case schliessen
    }

    struct Form {
        let befehle: [Befehl]
        let fuellen: Bool
        let strich: Double?
        let geradeUngerade: Bool
    }

    struct Zeichnung {
        let breite: Double
        let hoehe: Double
        let formen: [Form]
        let zahl: (x: Double, y: Double, groesse: Double)?
    }

    nonisolated(unsafe) private static var speicher: [String: Zeichnung] = [:]
    nonisolated(unsafe) private static var gemeldet: Set<String> = []

    static func zeichnung(_ name: String) -> Zeichnung? {
        if let schon = speicher[name] { return schon }
        guard let pfad = Plattform.mitgeliefert("icons/player/\(name).svg"),
              let text = try? String(contentsOfFile: pfad, encoding: .utf8),
              let z = lesen(text) else {
            if !gemeldet.contains(name) {
                gemeldet.insert(name)
                Protokoll.schreib("[Zeichen] fehlt: \(name).svg")
                fflush(nil)
            }
            return nil
        }
        speicher[name] = z
        return z
    }

    // MARK: Lesen

    private static func attribute(_ text: String) -> [String: String] {
        var ergebnis: [String: String] = [:]
        guard let muster = try? NSRegularExpression(pattern: #"([A-Za-z_:][-A-Za-z0-9_:.]*)\s*=\s*"([^"]*)""#) else {
            return ergebnis
        }
        let ns = text as NSString
        for treffer in muster.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            ergebnis[ns.substring(with: treffer.range(at: 1))] = ns.substring(with: treffer.range(at: 2))
        }
        return ergebnis
    }

    private static func lesen(_ text: String) -> Zeichnung? {
        guard let elementmuster = try? NSRegularExpression(pattern: #"<(svg|path|rect|circle)\b([^>]*)>"#) else {
            return nil
        }
        let ns = text as NSString
        var wurzel: [String: String] = [:]
        var formen: [Form] = []
        var breite = 24.0, hoehe = 24.0
        var zahl: (Double, Double, Double)?
        for treffer in elementmuster.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let art = ns.substring(with: treffer.range(at: 1))
            let a = attribute(ns.substring(with: treffer.range(at: 2)))
            if art == "svg" {
                wurzel = a
                if let vb = a["viewBox"] {
                    let w = zahlen(vb)
                    if w.count == 4 { breite = w[2]; hoehe = w[3] }
                }
                if let z = a["data-zahl"] {
                    let w = zahlen(z)
                    if w.count == 3 { zahl = (w[0], w[1], w[2]) }
                }
                continue
            }
            func wert(_ name: String) -> String? { a[name] ?? wurzel[name] }
            let fuellen = (wert("fill") ?? "currentColor") != "none"
            let strichAn = (wert("stroke") ?? "none") != "none"
            let strich = strichAn ? (wert("stroke-width").flatMap(Double.init) ?? 1) : nil
            let gerade = wert("fill-rule") == "evenodd"
            var befehle: [Befehl] = []
            switch art {
            case "path":
                befehle = pfad(a["d"] ?? "")
            case "rect":
                let x = Double(a["x"] ?? "") ?? 0, y = Double(a["y"] ?? "") ?? 0
                let w = Double(a["width"] ?? "") ?? 0, h = Double(a["height"] ?? "") ?? 0
                let r = min(Double(a["rx"] ?? "") ?? 0, w / 2, h / 2)
                befehle = [
                    .bewege(x + r, y), .linie(x + w - r, y),
                    .bogen(cx: x + w - r, cy: y + r, r: r, von: -.pi / 2, bis: 0, uhrzeigersinn: true),
                    .linie(x + w, y + h - r),
                    .bogen(cx: x + w - r, cy: y + h - r, r: r, von: 0, bis: .pi / 2, uhrzeigersinn: true),
                    .linie(x + r, y + h),
                    .bogen(cx: x + r, cy: y + h - r, r: r, von: .pi / 2, bis: .pi, uhrzeigersinn: true),
                    .linie(x, y + r),
                    .bogen(cx: x + r, cy: y + r, r: r, von: .pi, bis: 1.5 * .pi, uhrzeigersinn: true),
                    .schliessen,
                ]
            case "circle":
                let cx = Double(a["cx"] ?? "") ?? 0, cy = Double(a["cy"] ?? "") ?? 0
                let r = Double(a["r"] ?? "") ?? 0
                befehle = [.bewege(cx + r, cy),
                           .bogen(cx: cx, cy: cy, r: r, von: 0, bis: 2 * .pi, uhrzeigersinn: true),
                           .schliessen]
            default:
                break
            }
            formen.append(Form(befehle: befehle, fuellen: fuellen, strich: strich, geradeUngerade: gerade))
        }
        return Zeichnung(breite: breite, hoehe: hoehe, formen: formen,
                         zahl: zahl.map { (x: $0.0, y: $0.1, groesse: $0.2) })
    }

    private static func zahlen(_ text: String) -> [Double] {
        text.split(whereSeparator: { $0 == " " || $0 == "," }).compactMap { Double($0) }
    }

    /// Zerlegt `d` in Befehle mit absoluten Koordinaten.
    private static func pfad(_ d: String) -> [Befehl] {
        // Zeichen für Zeichen: ein Buchstabe ist ein Befehl, sonst eine Zahl.
        var teile: [String] = []
        var zahl = ""
        func abschliessen() { if !zahl.isEmpty { teile.append(zahl); zahl = "" } }
        for z in d {
            if z.isLetter && z != "e" && z != "E" {
                abschliessen(); teile.append(String(z))
            } else if z == " " || z == "," || z == "\n" || z == "\t" {
                abschliessen()
            } else if z == "-" && !zahl.isEmpty && !zahl.hasSuffix("e") && !zahl.hasSuffix("E") {
                abschliessen(); zahl = "-"
            } else if z == "." && zahl.contains(".") {
                abschliessen(); zahl = "."
            } else {
                zahl.append(z)
            }
        }
        abschliessen()

        var befehle: [Befehl] = []
        var i = 0
        var befehl: Character = "M"
        var x = 0.0, y = 0.0, sx = 0.0, sy = 0.0
        func naechste() -> Double? {
            guard i < teile.count, let w = Double(teile[i]) else { return nil }
            i += 1
            return w
        }
        while i < teile.count {
            if let b = teile[i].first, b.isLetter {
                befehl = b
                i += 1
                if b == "Z" || b == "z" {
                    befehle.append(.schliessen)
                    x = sx; y = sy
                    continue
                }
            }
            let relativ = befehl.isLowercase
            let dx = relativ ? x : 0, dy = relativ ? y : 0
            switch befehl.uppercased() {
            case "M":
                guard let a = naechste(), let b = naechste() else { return befehle }
                x = a + dx; y = b + dy; sx = x; sy = y
                befehle.append(.bewege(x, y))
                befehl = relativ ? "l" : "L"
            case "L":
                guard let a = naechste(), let b = naechste() else { return befehle }
                x = a + dx; y = b + dy
                befehle.append(.linie(x, y))
            case "H":
                guard let a = naechste() else { return befehle }
                x = a + dx
                befehle.append(.linie(x, y))
            case "V":
                guard let b = naechste() else { return befehle }
                y = b + dy
                befehle.append(.linie(x, y))
            case "C":
                guard let x1 = naechste(), let y1 = naechste(), let x2 = naechste(),
                      let y2 = naechste(), let x3 = naechste(), let y3 = naechste() else { return befehle }
                befehle.append(.kurve(x1 + dx, y1 + dy, x2 + dx, y2 + dy, x3 + dx, y3 + dy))
                x = x3 + dx; y = y3 + dy
            case "A":
                guard let rx = naechste(), naechste() != nil, naechste() != nil,
                      let gross = naechste(), let sweep = naechste(),
                      let ex = naechste(), let ey = naechste() else { return befehle }
                let zx = ex + dx, zy = ey + dy
                if let b = bogen(x, y, zx, zy, r: rx, gross: gross != 0, sweep: sweep != 0) {
                    befehle.append(b)
                } else {
                    befehle.append(.linie(zx, zy))
                }
                x = zx; y = zy
            default:
                // Unbekannter Befehl: nicht raten, Rest verwerfen.
                return befehle
            }
        }
        return befehle
    }

    /// Kreisbogen von der Endpunkt- in die Mittelpunktform (SVG 1.1, F.6.5),
    /// nur für `rx == ry` ohne Drehung — mehr zeichnen unsere Dateien nicht.
    private static func bogen(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double,
                              r rein: Double, gross: Bool, sweep: Bool) -> Befehl? {
        guard rein > 0, x1 != x2 || y1 != y2 else { return nil }
        let xs = (x1 - x2) / 2, ys = (y1 - y2) / 2
        let d2 = xs * xs + ys * ys
        var r = abs(rein)
        if d2 > r * r { r = sqrt(d2) }
        let vorzeichen: Double = gross != sweep ? 1 : -1
        let k = vorzeichen * sqrt(max(0, (r * r - d2) / d2))
        let cx = k * ys + (x1 + x2) / 2
        let cy = -k * xs + (y1 + y2) / 2
        let von = atan2(y1 - cy, x1 - cx)
        let bis = atan2(y2 - cy, x2 - cx)
        return .bogen(cx: cx, cy: cy, r: r, von: von, bis: bis, uhrzeigersinn: sweep)
    }
}

// MARK: - Das Widget

/// Ein Zeichen aus ``Svgvorrat``, in einer festen Kiste und einer Farbe.
///
/// `stupsen()` ist das `.symbolEffect(.bounce)` vom Mac; `zahl` steht in
/// `gobackward.10`/`goforward.10`.
final class Playerzeichen: @unchecked Sendable {
    fileprivate var lebt = true
    fileprivate var name: String
    fileprivate var zahl: Int?
    fileprivate var farbe: (Double, Double, Double, Double)
    fileprivate var wucht = 0.0
    let anzeige: Widget

    init(_ name: String, groesse: Int32, zahl: Int? = nil,
         farbe: (Double, Double, Double, Double) = (1, 1, 1, 1)) {
        self.name = name
        self.zahl = zahl
        self.farbe = farbe
        let feld: Widget! = gtk_drawing_area_new()
        gtk_widget_add_css_class(feld, "swiftly-blank")
        gtk_drawing_area_set_content_width(alsZeichen(feld), groesse)
        gtk_drawing_area_set_content_height(alsZeichen(feld), groesse)
        gtk_widget_set_halign(feld, GTK_ALIGN_CENTER)
        gtk_widget_set_valign(feld, GTK_ALIGN_CENTER)
        gtk_widget_set_can_target(feld, 0)
        anzeige = feld!
        gtk_drawing_area_set_draw_func(alsZeichen(feld), playerzeichenMalen,
                                       Unmanaged.passUnretained(self).toOpaque(), nil)
        // Das Feld hält das Objekt: ohne diesen Verweis wäre es fort, bevor
        // GTK zum ersten Mal malt.
        let selbst = Unmanaged.passRetained(self)
        beiSignal(feld, "destroy") {
            selbst.takeUnretainedValue().lebt = false
            selbst.release()
        }
    }

    func setzeName(_ neu: String) {
        guard neu != name else { return }
        name = neu
        gtk_widget_queue_draw(anzeige)
    }

    func setzeZahl(_ neu: Int?) {
        guard neu != zahl else { return }
        zahl = neu
        gtk_widget_queue_draw(anzeige)
    }

    /// Wie `Abspielzeichen.setzen`: läuft es, zeigt der Knopf Pause.
    func setzen(_ laeuft: Bool) {
        setzeName(laeuft ? "pause" : "abspielen")
    }

    func stupsen() {
        laufen(auf: anzeige, dauer: 0.3) { [weak self] e in
            guard let self, self.lebt else { return }
            self.wucht = sin(Double.pi * e)
            gtk_widget_queue_draw(self.anzeige)
        } fertig: { [weak self] in
            guard let self, self.lebt else { return }
            self.wucht = 0
            gtk_widget_queue_draw(self.anzeige)
        }
    }
}

nonisolated(unsafe) private let playerzeichenMalen: @convention(c) (
    UnsafeMutablePointer<GtkDrawingArea>?, OpaquePointer?, Int32, Int32, gpointer?
) -> Void = { _, cr, breite, hoehe, daten in
    guard let cr, let daten else { return }
    let z = Unmanaged<Playerzeichen>.fromOpaque(daten).takeUnretainedValue()
    guard z.lebt, let bild = Svgvorrat.zeichnung(z.name) else { return }
    let w = Double(breite), h = Double(hoehe)
    let s = min(w / bild.breite, h / bild.hoehe)
    cairo_save(cr)
    cairo_translate(cr, w / 2, h / 2)
    let f = 1 + 0.16 * z.wucht
    cairo_scale(cr, s * f, s * f)
    cairo_translate(cr, -bild.breite / 2, -bild.hoehe / 2)
    cairo_set_source_rgba(cr, z.farbe.0, z.farbe.1, z.farbe.2, z.farbe.3)
    cairo_set_line_cap(cr, CAIRO_LINE_CAP_ROUND)
    cairo_set_line_join(cr, CAIRO_LINE_JOIN_ROUND)
    for form in bild.formen {
        cairo_new_path(cr)
        for befehl in form.befehle {
            switch befehl {
            case let .bewege(x, y): cairo_move_to(cr, x, y)
            case let .linie(x, y): cairo_line_to(cr, x, y)
            case let .kurve(x1, y1, x2, y2, x3, y3): cairo_curve_to(cr, x1, y1, x2, y2, x3, y3)
            case let .bogen(cx, cy, r, von, bis, uhr):
                if uhr { cairo_arc(cr, cx, cy, r, von, bis) }
                else { cairo_arc_negative(cr, cx, cy, r, von, bis) }
            case .schliessen: cairo_close_path(cr)
            }
        }
        if form.fuellen {
            cairo_set_fill_rule(cr, form.geradeUngerade ? CAIRO_FILL_RULE_EVEN_ODD : CAIRO_FILL_RULE_WINDING)
            if form.strich != nil { cairo_fill_preserve(cr) } else { cairo_fill(cr) }
        }
        if let strich = form.strich {
            cairo_set_line_width(cr, strich)
            cairo_stroke(cr)
        }
    }
    if let zahl = z.zahl, let ort = bild.zahl {
        let text = "\(zahl)"
        cairo_select_font_face(cr, "sans-serif", CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_BOLD)
        cairo_set_font_size(cr, ort.groesse)
        var mass = cairo_text_extents_t()
        cairo_text_extents(cr, text, &mass)
        cairo_move_to(cr, ort.x - mass.width / 2 - mass.x_bearing,
                      ort.y - mass.height / 2 - mass.y_bearing)
        cairo_show_text(cr, text)
    }
    cairo_restore(cr)
}

// MARK: - Weiches Ein- und Ausblenden

/// Die zwei Kennlinien, die der Player braucht — dieselben Bézierkurven wie
/// SwiftUIs `.easeOut` und `.easeInOut`.
enum Kennlinie {
    case easeOut, easeInOut

    func wert(_ t: Double) -> Double {
        let (x1, y1, x2, y2): (Double, Double, Double, Double) =
            self == .easeOut ? (0, 0, 0.58, 1) : (0.42, 0, 0.58, 1)
        func b(_ s: Double, _ p1: Double, _ p2: Double) -> Double {
            3 * p1 * (1 - s) * (1 - s) * s + 3 * p2 * (1 - s) * s * s + s * s * s
        }
        func db(_ s: Double, _ p1: Double, _ p2: Double) -> Double {
            3 * p1 * (1 - s) * (1 - s) + 6 * (p2 - p1) * (1 - s) * s + 3 * (1 - p2) * s * s
        }
        var s = t
        for _ in 0..<8 {
            let d = db(s, x1, x2)
            guard abs(d) > 1e-6 else { break }
            s = min(max(s - (b(s, x1, x2) - t) / d, 0), 1)
        }
        return b(s, y1, y2)
    }
}

private final class Blendlauf {
    let von: Double
    let nach: Double
    let dauer: Double
    let kennlinie: Kennlinie
    let nummer: Int
    let fertig: (() -> Void)?
    let beginn = Date()
    init(von: Double, nach: Double, dauer: Double, kennlinie: Kennlinie, nummer: Int,
         fertig: (() -> Void)?) {
        self.von = von; self.nach = nach; self.dauer = dauer
        self.kennlinie = kennlinie; self.nummer = nummer; self.fertig = fertig
    }
}

/// Je Widget gilt nur der jüngste Lauf: ein neues `blenden` löst den alten ab,
/// und zwar vom **jetzigen** Stand aus — nichts springt.
nonisolated(unsafe) private var blendstand: [UnsafeMutableRawPointer: Int] = [:]
nonisolated(unsafe) private var blendzaehler = 0

nonisolated(unsafe) private let blendTakt: @convention(c) (
    UnsafeMutablePointer<GtkWidget>?, OpaquePointer?, gpointer?
) -> gboolean = { widget, _, daten in
    guard let widget, let daten else { return 0 }
    let l = Unmanaged<Blendlauf>.fromOpaque(daten).takeUnretainedValue()
    let schluessel = UnsafeMutableRawPointer(widget)
    guard blendstand[schluessel] == l.nummer else { return 0 }
    let t = min(Date().timeIntervalSince(l.beginn) / l.dauer, 1)
    gtk_widget_set_opacity(widget, l.von + (l.nach - l.von) * l.kennlinie.wert(t))
    if t >= 1 {
        blendstand[schluessel] = nil
        l.fertig?()
        return 0
    }
    return 1
}

nonisolated(unsafe) private let blendFreigeben: @convention(c) (gpointer?) -> Void = { daten in
    guard let daten else { return }
    Unmanaged<Blendlauf>.fromOpaque(daten).release()
}

/// Blendet ein Widget auf `ziel`, im Bildtakt des Fensters. Ist es nicht zu
/// sehen (nicht abgebildet), wird der Wert sofort gesetzt — dort gäbe es
/// keinen Takt, und ein Lauf bliebe hängen.
func blenden(_ widget: Widget!, auf ziel: Double, dauer: Double,
             kennlinie: Kennlinie = .easeOut, fertig: (() -> Void)? = nil) {
    guard let widget else { return }
    let schluessel = UnsafeMutableRawPointer(widget)
    blendzaehler += 1
    let nummer = blendzaehler
    blendstand[schluessel] = nummer
    let von = gtk_widget_get_opacity(widget)
    guard dauer > 0, abs(von - ziel) > 0.001, gtk_widget_get_mapped(widget) != 0 else {
        blendstand[schluessel] = nil
        gtk_widget_set_opacity(widget, ziel)
        fertig?()
        return
    }
    let lauf = Blendlauf(von: von, nach: ziel, dauer: dauer, kennlinie: kennlinie,
                         nummer: nummer, fertig: fertig)
    _ = gtk_widget_add_tick_callback(widget, blendTakt,
                                     Unmanaged.passRetained(lauf).toOpaque(), blendFreigeben)
}

// MARK: - Die Sprungmarke

/// Der Kreis links oder rechts, wenn mit den Pfeiltasten gesprungen wird —
/// wörtlich `Sprungmarke` vom Mac: 108 rund, Schwarz 45 %, darin das Zeichen
/// in 32 und „10 s" darunter.
final class Sprungmarke {
    let anzeige: Widget
    let zeichen: Playerzeichen
    let text: Widget

    init(zurueck: Bool) {
        let kreis = stapel(GTK_ORIENTATION_VERTICAL, abstand: 6)
        gtk_widget_add_css_class(kreis, "swiftly-sprungmarke")
        gtk_widget_set_size_request(kreis, 108, 108)
        zeichen = Playerzeichen(zurueck ? "zurueck" : "vor", groesse: 36)
        gtk_widget_set_margin_top(zeichen.anzeige, 18)
        anhaengen(kreis, zeichen.anzeige)
        text = beschriftung("", stil: "swiftly-sprungtext")
        gtk_widget_set_halign(text, GTK_ALIGN_CENTER)
        anhaengen(kreis, text)
        gtk_widget_set_can_target(kreis, 0)
        gtk_widget_set_opacity(kreis, 0)
        anzeige = kreis!
    }
}
