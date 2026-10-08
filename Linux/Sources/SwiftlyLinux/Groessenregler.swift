import CGtk
import Foundation

/// **Größe der Oberfläche** — ein Regler mit Rasten von 80 bis 150 %.
///
/// Gebaut wie der Lautstärkeregler (`Lautstaerkeregler.swift`): eine
/// Zeichenfläche, Spur 4, Füllung im Akzent bis zum Griff, Griff weiß. Kein
/// `GtkScale` (E4) — der brächte Spur, Griff und Maße des Systems mit.
///
/// **Übernommen wird beim Loslassen, nicht beim Ziehen.** Jede Stufe legt die
/// ganze Oberfläche neu aus, auch den Regler selbst; stünde die Änderung
/// schon während des Ziehens, liefe die Spur unter dem Zeiger davon. Beim
/// Ziehen wandern nur Griff und Prozentzahl.
///
/// Mit der Tastatur: Pfeile eine Stufe, Pos1/Ende an die Enden — das wirkt
/// sofort, weil dabei nichts unter dem Zeiger liegt.
final class Groessenregler: @unchecked Sendable {
    static let hoehe = 32.0
    static let griff = 16.0
    /// Luft links und rechts, damit der Griff an den Enden ganz zu sehen ist.
    static let rand = 10.0

    let anzeige: Widget
    private let feld: Widget
    private let wertfeld: Widget
    private(set) var stufe: Int
    private var zieht = false
    fileprivate var lebt = true
    private let stufen = Skalierung.stufen

    /// Eine Stufe ist gewählt und soll gelten.
    var gewaehlt: ((Double) -> Void)?

    init(wert: Double, titel: String, unter: String?) {
        stufe = Self.stufeZu(Skalierung.gerastet(wert))

        let block = stapel(GTK_ORIENTATION_VERTICAL, abstand: 0)
        anzeige = block!

        let w = beschriftung("", stil: "swiftly-koerper")
        gtk_widget_add_css_class(w, "dim-label")
        gtk_widget_set_valign(w, GTK_ALIGN_CENTER)
        wertfeld = w!
        let kopf = zeilenrumpf(symbol: "zoom-in-symbolic", titel: titel, unter: unter,
                               akzent: false, rechts: w)
        gtk_widget_add_css_class(kopf, "swiftly-zeilenrumpf")
        anhaengen(block, kopf)

        // **Die Rolle steht beim Bau fest** — `accessible-role` ist eine
        // Eigenschaft, die GTK nur bei der Geburt annimmt.
        var rolle = GValue()
        g_value_init(&rolle, gtk_accessible_role_get_type())
        g_value_set_enum(&rolle, Int32(GTK_ACCESSIBLE_ROLE_SLIDER.rawValue))
        let roh: UnsafeMutablePointer<GObject>? = "accessible-role".withCString { name in
            var namen: [UnsafePointer<CChar>?] = [name]
            return withUnsafePointer(to: &rolle) { werte in
                namen.withUnsafeMutableBufferPointer {
                    g_object_new_with_properties(gtk_drawing_area_get_type(), 1, $0.baseAddress, werte)
                }
            }
        }
        g_value_unset(&rolle)
        let feld: Widget! = roh.map { UnsafeMutableRawPointer($0).assumingMemoryBound(to: GtkWidget.self) }
            ?? gtk_drawing_area_new()
        gtk_widget_add_css_class(feld, "swiftly-groessenregler")
        gtk_drawing_area_set_content_height(alsZeichen(feld), Int32(Self.hoehe))
        gtk_widget_set_hexpand(feld, 1)
        gtk_widget_set_focusable(feld, 1)
        // Unter dem Titel, nicht unter dem Zeichen: 12 Rand + 20 Zeichen + 14.
        gtk_widget_set_margin_start(feld, 46 - Int32(Self.rand))
        gtk_widget_set_margin_end(feld, 12 - Int32(Self.rand) + 4)
        gtk_widget_set_margin_bottom(feld, 8)
        beschriften(feld, titel)
        self.feld = feld
        anhaengen(block, feld)

        let selbst = Unmanaged.passRetained(self)
        gtk_drawing_area_set_draw_func(alsZeichen(feld), groessenreglerMalen, selbst.toOpaque(), nil)
        beiSignal(feld, "destroy") {
            selbst.takeUnretainedValue().lebt = false
            selbst.release()
        }
        let daten = selbst.toOpaque()

        let geste = gtk_gesture_drag_new()
        gtk_gesture_single_set_button(geste, 1)
        g_signal_connect_data(UnsafeMutableRawPointer(geste), "drag-begin",
                              unsafeBitCast(groesseZugBeginn, to: GCallback.self),
                              daten, nil, GConnectFlags(rawValue: 0))
        g_signal_connect_data(UnsafeMutableRawPointer(geste), "drag-update",
                              unsafeBitCast(groesseZugStand, to: GCallback.self),
                              daten, nil, GConnectFlags(rawValue: 0))
        g_signal_connect_data(UnsafeMutableRawPointer(geste), "drag-end",
                              unsafeBitCast(groesseZugEnde, to: GCallback.self),
                              daten, nil, GConnectFlags(rawValue: 0))
        gtk_widget_add_controller(feld, geste)

        let tasten = gtk_event_controller_key_new()
        g_signal_connect_data(UnsafeMutableRawPointer(tasten), "key-pressed",
                              unsafeBitCast(groesseTaste, to: GCallback.self),
                              daten, nil, GConnectFlags(rawValue: 0))
        gtk_widget_add_controller(feld, tasten)

        nachfuehren()
    }

    var wert: Double { stufen[stufe] }

    private static func stufeZu(_ wert: Double) -> Int {
        Skalierung.stufen.firstIndex(of: wert) ?? Skalierung.stufen.firstIndex(of: 1) ?? 0
    }

    /// Von außen gesetzt („Zurücksetzen"): zeigt den Wert, meldet nichts.
    func setzen(_ neu: Double) {
        stufe = Self.stufeZu(Skalierung.gerastet(neu))
        nachfuehren()
    }

    private func nachfuehren() {
        guard lebt else { return }
        let text = "\(Int((wert * 100).rounded())) %"
        gtk_label_set_text(OpaquePointer(wertfeld), text)
        gtk_widget_queue_draw(feld)
        // Wert für die Bedienhilfe: Zahl und Wortlaut.
        var namen = [GTK_ACCESSIBLE_PROPERTY_VALUE_MIN, GTK_ACCESSIBLE_PROPERTY_VALUE_MAX,
                     GTK_ACCESSIBLE_PROPERTY_VALUE_NOW, GTK_ACCESSIBLE_PROPERTY_VALUE_TEXT]
        var werte = [GValue(), GValue(), GValue(), GValue()]
        let zahlen = [(stufen.first ?? 0.8) * 100, (stufen.last ?? 1.5) * 100, wert * 100]
        for (i, z) in zahlen.enumerated() {
            g_value_init(&werte[i], g_type_from_name("gdouble"))
            g_value_set_double(&werte[i], z)
        }
        g_value_init(&werte[3], g_type_from_name("gchararray"))
        text.withCString { g_value_set_string(&werte[3], $0) }
        gtk_accessible_update_property_value(OpaquePointer(feld), 4, &namen, &werte)
        for i in werte.indices { g_value_unset(&werte[i]) }
    }

    // MARK: Lage

    fileprivate func x(fuer stufe: Int, breite: Double) -> Double {
        let n = Double(max(stufen.count - 1, 1))
        return Self.rand + (breite - 2 * Self.rand) * Double(stufe) / n
    }

    fileprivate func stufe(bei x: Double) -> Int {
        let b = Double(gtk_widget_get_width(feld))
        let n = Double(max(stufen.count - 1, 1))
        let anteil = (x - Self.rand) / max(b - 2 * Self.rand, 1)
        return min(max(Int((anteil * n).rounded()), 0), stufen.count - 1)
    }

    // MARK: Ziehen

    private var startX = 0.0

    fileprivate func zugBeginn(x: Double) {
        guard lebt else { return }
        zieht = true
        startX = x
        gtk_widget_grab_focus(feld)
        zugSetzen(x)
    }

    fileprivate func zugStand(versatz: Double) {
        guard zieht else { return }
        zugSetzen(startX + versatz)
    }

    private func zugSetzen(_ x: Double) {
        let neu = stufe(bei: x)
        guard neu != stufe else { return }
        stufe = neu
        nachfuehren()
    }

    fileprivate func zugEnde() {
        guard zieht else { return }
        zieht = false
        gewaehlt?(wert)
    }

    fileprivate func taste(_ taste: UInt32) -> Bool {
        let neu: Int
        switch taste {
        case 0xff51, 0xff54: neu = stufe - 1             // links, runter
        case 0xff53, 0xff52: neu = stufe + 1             // rechts, hoch
        case 0xff50:         neu = 0                     // Pos1
        case 0xff57:         neu = stufen.count - 1      // Ende
        default: return false
        }
        let geklemmt = min(max(neu, 0), stufen.count - 1)
        guard geklemmt != stufe else { return true }
        stufe = geklemmt
        nachfuehren()
        gewaehlt?(wert)
        return true
    }

    fileprivate var stufenzahl: Int { stufen.count }
    fileprivate var mitte: Int { stufen.firstIndex(of: 1) ?? 0 }
}

// MARK: - Rückrufe

nonisolated(unsafe) private let groesseZugBeginn: @convention(c) (
    UnsafeMutableRawPointer?, Double, Double, gpointer?
) -> Void = { geste, x, _, daten in
    guard let daten, let geste else { return }
    _ = gtk_gesture_set_state(OpaquePointer(geste), GTK_EVENT_SEQUENCE_CLAIMED)
    Unmanaged<Groessenregler>.fromOpaque(daten).takeUnretainedValue().zugBeginn(x: x)
}

nonisolated(unsafe) private let groesseZugStand: @convention(c) (
    UnsafeMutableRawPointer?, Double, Double, gpointer?
) -> Void = { _, versatz, _, daten in
    guard let daten else { return }
    Unmanaged<Groessenregler>.fromOpaque(daten).takeUnretainedValue().zugStand(versatz: versatz)
}

nonisolated(unsafe) private let groesseZugEnde: @convention(c) (
    UnsafeMutableRawPointer?, Double, Double, gpointer?
) -> Void = { _, _, _, daten in
    guard let daten else { return }
    Unmanaged<Groessenregler>.fromOpaque(daten).takeUnretainedValue().zugEnde()
}

nonisolated(unsafe) private let groesseTaste: @convention(c) (
    UnsafeMutableRawPointer?, UInt32, UInt32, UInt32, gpointer?
) -> Int32 = { _, taste, _, _, daten in
    guard let daten else { return 0 }
    return Unmanaged<Groessenregler>.fromOpaque(daten).takeUnretainedValue().taste(taste) ? 1 : 0
}

nonisolated(unsafe) private let groessenreglerMalen: @convention(c) (
    UnsafeMutablePointer<GtkDrawingArea>?, OpaquePointer?, Int32, Int32, gpointer?
) -> Void = { _, cr, breite, hoehe, daten in
    guard let cr, let daten else { return }
    let r = Unmanaged<Groessenregler>.fromOpaque(daten).takeUnretainedValue()
    guard r.lebt, breite > 0 else { return }
    let b = Double(breite), mitte = Double(hoehe) / 2
    let links = r.x(fuer: 0, breite: b), rechts = r.x(fuer: r.stufenzahl - 1, breite: b)
    let griffX = r.x(fuer: r.stufe, breite: b)

    cairo_set_line_cap(cr, CAIRO_LINE_CAP_ROUND)
    cairo_set_line_width(cr, 4)
    // Spur: Weiß bei 18 %, wie im Player.
    cairo_set_source_rgba(cr, 1, 1, 1, 0.18)
    cairo_new_path(cr)
    cairo_move_to(cr, links, mitte)
    cairo_line_to(cr, rechts, mitte)
    cairo_stroke(cr)
    // Füllung im Akzent bis zum Griff.
    let a = Stil.akzentRGB
    cairo_set_source_rgba(cr, a.0, a.1, a.2, 1)
    cairo_new_path(cr)
    cairo_move_to(cr, links, mitte)
    cairo_line_to(cr, max(griffX, links + 0.01), mitte)
    cairo_stroke(cr)
    // Rasten: kleine Punkte, die bei 100 % etwas deutlicher — dort steht
    // „wie das System".
    for i in 0..<r.stufenzahl {
        let x = r.x(fuer: i, breite: b)
        cairo_set_source_rgba(cr, 1, 1, 1, i == r.mitte ? 0.7 : 0.35)
        cairo_new_path(cr)
        cairo_arc(cr, x, mitte + 9, i == r.mitte ? 2 : 1.5, 0, 2 * .pi)
        cairo_fill(cr)
    }
    // Griff: weiß, 16 rund — so groß wie der Knauf der Schalter.
    cairo_set_source_rgba(cr, 1, 1, 1, 1)
    cairo_new_path(cr)
    cairo_arc(cr, griffX, mitte, Groessenregler.griff / 2, 0, 2 * .pi)
    cairo_fill(cr)
}
