import CGtk
import Foundation

/// **Lautstärke im Player** — Lautsprecher-Knopf als erster der Symbolreihe;
/// beim Überfahren klappt links davon ein waagerechter Regler aus (Mac:
/// `Sources/macOS/Lautstaerkeregler.swift`).
///
/// Maße wie dort: Fach 0 → 96 in 0,18 s (ease-out), Regler 88, Spur 4, Griff
/// 12 nur beim Überfahren oder Ziehen. **Der Griff bleibt ganz in der Spur**:
/// sein Weg endet einen Radius vor jedem Ende, sonst schnitte ihn der Rand ab.
///
/// **Das Fach ist eine Zeichenfläche, deren Breite läuft.** GTK kürzt eine
/// Box nicht unter die Mindestbreite ihrer Kinder; eine Fläche, die ihren
/// Inhalt am rechten Rand (am Lautsprecher) ausrichtet, wird dagegen von der
/// eigenen Breite beschnitten — der Regler fährt aus dem Lautsprecher heraus.
///
/// **Die Prozentzahl steht unter dem Griff, im selben Feld:** am Mac liegt sie
/// unterhalb des Fachs, hier hätte das Feld dafür 14 Punkt Höhe mehr gebraucht
/// und die Symbolreihe verschoben. Bei 38 Punkt Höhe passt sie zwischen Griff
/// und Unterkante.
final class Lautstaerkeregler: @unchecked Sendable {
    static let fachBreite = 96.0
    static let reglerBreite = 88.0
    static let hoehe = 38.0
    static let griff = 12.0

    let anzeige: Widget
    private let feld: Widget
    private let zeichen: Playerzeichen

    /// 0 bis 1.
    private(set) var wert: Double
    /// Die Taste (Pfeile, M) hat den Regler kurz geöffnet.
    private var kurz = false
    private var drueber = false
    private(set) var zieht = false
    private var fortschritt = 0.0
    private var nummer = 0
    private var startX = 0.0
    fileprivate var lebt = true

    /// Der Wert hat sich durch Ziehen geändert (fortlaufend).
    var geaendert: ((Double) -> Void)?
    /// Ziehen beginnt oder endet.
    var ziehen: ((Bool) -> Void)?

    init(wert: Double, zeichen: Playerzeichen, knopf: Widget) {
        self.wert = min(max(wert, 0), 1)
        self.zeichen = zeichen
        let huelle = stapel(GTK_ORIENTATION_HORIZONTAL, abstand: 0)
        gtk_widget_set_valign(huelle, GTK_ALIGN_START)
        anzeige = huelle!

        let feld: Widget! = gtk_drawing_area_new()
        gtk_widget_add_css_class(feld, "swiftly-blank")
        gtk_drawing_area_set_content_width(alsZeichen(feld), 0)
        gtk_drawing_area_set_content_height(alsZeichen(feld), Int32(Self.hoehe))
        gtk_widget_set_valign(feld, GTK_ALIGN_START)
        gtk_widget_set_can_target(feld, 0)
        self.feld = feld
        anhaengen(huelle, feld)
        anhaengen(huelle, knopf)
        symbolNachfuehren()

        let selbst = Unmanaged.passRetained(self)
        gtk_drawing_area_set_draw_func(alsZeichen(feld), reglerFeldMalen, selbst.toOpaque(), nil)
        beiSignal(feld, "destroy") {
            selbst.takeUnretainedValue().lebt = false
            selbst.release()
        }

        beiZeiger(huelle, herein: { [weak self] in self?.drueberSetzen(true) },
                  hinaus: { [weak self] in self?.drueberSetzen(false) })

        // Das Ziehen liegt auf der ganzen Hülle, nimmt aber nur Klicks im
        // Fach an — der Lautsprecher ist ein Knopf und behält seinen Klick.
        let geste = gtk_gesture_drag_new()
        gtk_gesture_single_set_button(geste, 1)
        let daten = selbst.toOpaque()
        g_signal_connect_data(UnsafeMutableRawPointer(geste), "drag-begin",
                              unsafeBitCast(reglerZugBeginn, to: GCallback.self),
                              daten, nil, GConnectFlags(rawValue: 0))
        g_signal_connect_data(UnsafeMutableRawPointer(geste), "drag-update",
                              unsafeBitCast(reglerZugStand, to: GCallback.self),
                              daten, nil, GConnectFlags(rawValue: 0))
        g_signal_connect_data(UnsafeMutableRawPointer(geste), "drag-end",
                              unsafeBitCast(reglerZugEnde, to: GCallback.self),
                              daten, nil, GConnectFlags(rawValue: 0))
        gtk_widget_add_controller(huelle, geste)
    }

    // MARK: Zustand

    private var offen: Bool { drueber || zieht || kurz }

    /// Von außen gesetzt (Taste, Stumm): malt neu und tauscht das Symbol.
    func setzen(_ neu: Double) {
        wert = min(max(neu, 0), 1)
        symbolNachfuehren()
        if lebt { gtk_widget_queue_draw(feld) }
    }

    /// Klappt den Regler auf oder zu — für die Tasten, 1,2 s lang.
    func kurzZeigen(_ an: Bool) {
        kurz = an
        nachfuehren()
    }

    private func drueberSetzen(_ an: Bool) {
        drueber = an
        nachfuehren()
    }

    private func nachfuehren() {
        guard lebt else { return }
        fahren(zu: offen ? 1 : 0)
        gtk_widget_queue_draw(feld)
    }

    /// Symbol wie am Mac: stumm bei 0, leise unter der Hälfte, sonst laut.
    private func symbolNachfuehren() {
        zeichen.setzeName(wert <= 0 ? "lautsprecher-stumm"
                          : wert < 0.5 ? "lautsprecher-leise" : "lautsprecher-laut")
        if let knopf = gtk_widget_get_parent(zeichen.anzeige) {
            beschriften(knopf, wert <= 0 ? uebersetzt("Ton an") : uebersetzt("Ton aus"))
            gtk_widget_set_tooltip_text(knopf, wert <= 0 ? uebersetzt("Ton an") : uebersetzt("Ton aus"))
        }
    }

    // MARK: Fahrt

    /// 0,18 s ease-out, vom jetzigen Stand aus — eine neue Fahrt löst die alte ab.
    private func fahren(zu ziel: Double) {
        nummer += 1
        let meine = nummer
        let von = fortschritt
        guard abs(von - ziel) > 0.001 else { return }
        if bewegungReduziert() || gtk_widget_get_mapped(feld) == 0 {
            fortschrittSetzen(ziel)
            return
        }
        laufen(auf: feld, dauer: 0.18, linear: true, schritt: { [weak self] t in
            guard let self, self.lebt, self.nummer == meine else { return }
            self.fortschrittSetzen(von + (ziel - von) * Kennlinie.easeOut.wert(t))
        }, fertig: {})
    }

    private func fortschrittSetzen(_ p: Double) {
        fortschritt = p
        gtk_drawing_area_set_content_width(alsZeichen(feld), Int32((p * Self.fachBreite).rounded()))
        gtk_widget_queue_draw(feld)
    }

    // MARK: Ziehen

    /// Mitte des Griffs. **Der Griff bleibt ganz in der Spur** — sein Weg endet
    /// einen Radius vor jedem Ende.
    static func griffX(_ wert: Double, breite: Double) -> Double {
        griff / 2 + (breite - griff) * min(max(wert, 0), 1)
    }

    /// Linke Kante der Spur im Feld — rechtsbündig, 4 Punkt vor dem Rand.
    fileprivate func spurLinks(_ feldBreite: Double) -> Double {
        feldBreite - Self.fachBreite + 4
    }

    fileprivate func zugBeginn(x: Double) {
        guard fortschritt > 0.5 else { return }
        startX = x
        zieht = true
        ziehen?(true)
        zugSetzen(x)
    }

    fileprivate func zugSetzen(_ x: Double) {
        let b = Double(gtk_widget_get_width(feld))
        let links = spurLinks(b)
        let neu = min(max((x - links - Self.griff / 2) / (Self.reglerBreite - Self.griff), 0), 1)
        setzen(neu)
        geaendert?(neu)
    }

    fileprivate func zugStand(versatz: Double) {
        guard zieht else { return }
        zugSetzen(startX + versatz)
    }

    fileprivate func zugEnde() {
        guard zieht else { return }
        zieht = false
        ziehen?(false)
        nachfuehren()
    }

    fileprivate var prozentZeigen: Bool { zieht || kurz }
    fileprivate var fortschrittWert: Double { fortschritt }
}

// MARK: - Rückrufe

nonisolated(unsafe) private let reglerZugBeginn: @convention(c) (
    UnsafeMutableRawPointer?, Double, Double, gpointer?
) -> Void = { geste, x, y, daten in
    guard let daten, let geste else { return }
    let r = Unmanaged<Lautstaerkeregler>.fromOpaque(daten).takeUnretainedValue()
    // Nur im Fach: rechts davon liegt der Lautsprecher-Knopf.
    guard r.lebt, x < Double(gtk_widget_get_width(r.anzeige)) - Double(Playermass.knopf),
          r.fortschrittWert > 0.5 else { return }
    _ = gtk_gesture_set_state(OpaquePointer(geste), GTK_EVENT_SEQUENCE_CLAIMED)
    r.zugBeginn(x: x)
}

nonisolated(unsafe) private let reglerZugStand: @convention(c) (
    UnsafeMutableRawPointer?, Double, Double, gpointer?
) -> Void = { _, versatz, _, daten in
    guard let daten else { return }
    Unmanaged<Lautstaerkeregler>.fromOpaque(daten).takeUnretainedValue().zugStand(versatz: versatz)
}

nonisolated(unsafe) private let reglerZugEnde: @convention(c) (
    UnsafeMutableRawPointer?, Double, Double, gpointer?
) -> Void = { _, _, _, daten in
    guard let daten else { return }
    Unmanaged<Lautstaerkeregler>.fromOpaque(daten).takeUnretainedValue().zugEnde()
}

nonisolated(unsafe) private let reglerFeldMalen: @convention(c) (
    UnsafeMutablePointer<GtkDrawingArea>?, OpaquePointer?, Int32, Int32, gpointer?
) -> Void = { _, cr, breite, hoehe, daten in
    guard let cr, let daten else { return }
    let r = Unmanaged<Lautstaerkeregler>.fromOpaque(daten).takeUnretainedValue()
    guard r.lebt, breite > 0 else { return }
    let p = r.fortschrittWert
    let b = Double(breite), mitte = Double(hoehe) / 2
    let links = r.spurLinks(b)
    let laenge = Lautstaerkeregler.reglerBreite
    let wert = r.wert
    let x = links + Lautstaerkeregler.griffX(wert, breite: laenge)

    func kapsel(_ von: Double, _ bis: Double) {
        cairo_new_path(cr)
        cairo_move_to(cr, von + 2, mitte)
        cairo_line_to(cr, max(bis - 2, von + 2), mitte)
    }
    cairo_set_line_cap(cr, CAIRO_LINE_CAP_ROUND)
    cairo_set_line_width(cr, 4)
    // Spur: Weiß bei 18 %.
    cairo_set_source_rgba(cr, 1, 1, 1, 0.18 * p)
    kapsel(links, links + laenge)
    cairo_stroke(cr)
    // Füllung in Akzent bis zur Mitte des Griffs.
    if wert > 0 {
        let a = Stil.akzentRGB
        cairo_set_source_rgba(cr, a.0, a.1, a.2, p)
        kapsel(links, x)
        cairo_stroke(cr)
    }
    // Griff: weiß, 12 rund, wächst mit dem Fach von 60 % auf 100 %.
    cairo_set_source_rgba(cr, 1, 1, 1, p)
    cairo_new_path(cr)
    cairo_arc(cr, x, mitte, Lautstaerkeregler.griff / 2 * (0.6 + 0.4 * p), 0, 2 * .pi)
    cairo_fill(cr)
    // Prozent klein unter dem Griff, nur beim Ziehen oder Tasten.
    if r.prozentZeigen {
        let text = "\(Int((wert * 100).rounded())) %"
        cairo_select_font_face(cr, "sans-serif", CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_BOLD)
        cairo_set_font_size(cr, 11)
        var mass = cairo_text_extents_t()
        cairo_text_extents(cr, text, &mass)
        // #CCCCCC wie `Stil.schriftLeise`.
        cairo_set_source_rgba(cr, 0.8, 0.8, 0.8, 1)
        let mitteX = min(max(x, mass.width / 2 + 1), b - mass.width / 2 - 1)
        cairo_move_to(cr, mitteX - mass.width / 2 - mass.x_bearing, Double(hoehe) - 3)
        cairo_show_text(cr, text)
    }
}
