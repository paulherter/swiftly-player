import CGtk
import Foundation

/// **Der Kreispfeil mit der Zahl — gezeichnet, nicht gesucht.**
///
/// Der Mac nimmt `gobackward.10` und `goforward.30` aus SF Symbols: ein
/// offener Kreis mit einem Pfeilkopf oben und der Sprungweite in der Mitte.
/// Adwaita hat nichts dergleichen; die nächstbesten Zeichen
/// (`media-seek-backward`) sind zwei Dreiecke und sagen nichts über die
/// Weite.
///
/// Das ist keine Kleinigkeit: **die Weite steht in den Einstellungen** (B2),
/// zehn zurück und dreissig vor sind nur die Vorgabe. Ein festes Zeichen
/// könnte sie gar nicht zeigen. Also wird gezeichnet — dann stimmt jede Zahl,
/// und beide Richtungen sind dasselbe Bild, einmal gespiegelt.
final class Sprungzeichen: @unchecked Sendable {
    /// **Lebt die Zeichenfläche noch?** Siehe den `destroy`-Auftrag im
    /// Initialisierer.
    fileprivate var lebt = true

    fileprivate let zurueck: Bool
    fileprivate var zahl: Int
    fileprivate let mass: Double
    let anzeige: Widget

    init(zurueck: Bool, zahl: Int, mass: Double = 30) {
        self.zurueck = zurueck
        self.zahl = zahl
        self.mass = mass
        let feld: Widget! = gtk_drawing_area_new()
        gtk_widget_add_css_class(feld, "swiftly-blank")
        gtk_drawing_area_set_content_width(alsZeichen(feld), Int32(mass))
        gtk_drawing_area_set_content_height(alsZeichen(feld), Int32(mass))
        anzeige = feld!
        gtk_drawing_area_set_draw_func(alsZeichen(feld), sprungMalen,
                                       Unmanaged.passUnretained(self).toOpaque(), nil)
        // **Die Zeichenfläche hält das Zeichen, nicht `App`.**
        //
        // Der Zeichenruf oben bekommt `self` *unretained*. Gehalten wurde es
        // bisher allein von einem Feld in `App` — und das wird bei **jedem**
        // Start des Players überschrieben, weil `spielerSeiteBauen` die
        // Steuerung jedes Mal neu aufbaut. Das alte Zeichen stirbt damit in
        // dem Moment, in dem das neue entsteht; seine Fläche hängt aber noch
        // in der alten Spielerseite, die 380 ms lang nach unten fährt und
        // dabei weitergezeichnet wird. Wer in dieser Zeit den nächsten Film
        // startet, malt auf freigegebenem Speicher.
        //
        // Derselbe Fehler wie in ``Kulisse`` (`a6d697b`) und in der
        // ``Startanimation`` (`71dce00`), an derselben Sorte Stelle. Der
        // starke Zugriff im Auftrag hält das Zeichen, solange seine Fläche
        // lebt; die Wache in `malen` fängt den Rest.
        beiSignal(feld, "destroy") { self.lebt = false }
    }

    /// Wie stark das Zeichen gerade ausschlägt. Der Mac nimmt dafür
    /// `.symbolEffect(.bounce)` — „spielt einmal ab und geht von selbst in
    /// die Ruhelage zurück". Ein Sprung ohne Rückmeldung fühlt sich an, als
    /// wäre der Knopf nicht angekommen.
    fileprivate var wucht: Double = 0

    /// Ein Ausschlag. Zählt **jeden** Druck, auch den zehnten hintereinander.
    func stupsen() {
        laufen(auf: anzeige, dauer: 0.34) { [weak self] e in
            guard let self else { return }
            self.wucht = sin(Double.pi * e)
            gtk_widget_queue_draw(self.anzeige)
        } fertig: { [weak self] in
            guard let self else { return }
            self.wucht = 0
            gtk_widget_queue_draw(self.anzeige)
        }
    }

    /// Die Weite kann sich in den Einstellungen ändern, während der Player
    /// steht. Dann wird neu gezeichnet, nicht neu gebaut.
    func setzeZahl(_ neu: Int) {
        guard neu != zahl else { return }
        zahl = neu
        gtk_widget_queue_draw(anzeige)
    }
}

/// Malt den Kreispfeil. Die Zeichenfunktion bringt Breite und Höhe mit —
/// wieder eine eigene Form, wieder ein eigener Rückruf.
nonisolated(unsafe) private let sprungMalen: @convention(c) (
    UnsafeMutablePointer<GtkDrawingArea>?, OpaquePointer?, Int32, Int32, gpointer?
) -> Void = { _, cr, breite, hoehe, daten in
    guard let cr, let daten else { return }
    let z = Unmanaged<Sprungzeichen>.fromOpaque(daten).takeUnretainedValue()
    guard z.lebt else { return }

    let cx = Double(breite) / 2, cy = Double(hoehe) / 2
    // Halbmesser, Strich und Pfeilkopf wachsen mit dem Zeichen, damit ein
    // grosses und ein kleines gleich aussehen. Die Verhältnisse sind an
    // einem Probelauf gegen `gobackward.10` abgemessen.
    let r = z.mass * 0.34
    let strich = max(z.mass * 0.068, 1.2)
    let bogen = Double.pi / 180
    let stelle = -76 * bogen

    // **Der Ausschlag umfasst das ganze Zeichen, Zahl eingeschlossen.**
    // Deshalb eine Sicherung um alles, nicht nur um den Bogen.
    cairo_save(cr)
    if z.wucht > 0.001 {
        let f = 1 + 0.18 * z.wucht
        cairo_translate(cr, cx, cy)
        cairo_scale(cr, f, f)
        cairo_translate(cr, -cx, -cy)
    }

    cairo_save(cr)
    // **Zurück ist Vor, gespiegelt.** Ein Bild, zwei Richtungen — so kann
    // sich das eine nicht vom anderen weg entwickeln.
    if z.zurueck {
        cairo_translate(cr, cx, 0)
        cairo_scale(cr, -1, 1)
        cairo_translate(cr, -cx, 0)
    }

    cairo_set_source_rgba(cr, 1, 1, 1, 1)
    cairo_set_line_width(cr, strich)
    cairo_set_line_cap(cr, CAIRO_LINE_CAP_BUTT)

    // Der Kreis mit einer Lücke oben: von −76° im Uhrzeigersinn bis 250°.
    cairo_new_path(cr)
    cairo_arc(cr, cx, cy, r, stelle, 250 * bogen)
    cairo_stroke(cr)

    // Der Pfeilkopf sitzt am Ende der Lücke und ist **in die Laufrichtung
    // gedreht** — ungedreht stand er quer und sah aus wie ein Fähnchen.
    let spitze = z.mass * 0.088
    cairo_save(cr)
    cairo_translate(cr, cx + r * cos(stelle), cy + r * sin(stelle))
    cairo_rotate(cr, stelle + 90 * bogen)
    cairo_new_path(cr)
    cairo_move_to(cr, spitze * 1.5, 0)
    cairo_line_to(cr, -spitze * 0.5, -spitze * 1.05)
    cairo_line_to(cr, -spitze * 0.5, spitze * 1.05)
    cairo_close_path(cr)
    cairo_fill(cr)
    cairo_restore(cr)
    cairo_restore(cr)

    // **Die Farbe muss noch einmal gesetzt werden.** `cairo_restore` nimmt
    // nicht nur die Spiegelung zurück, sondern die ganze Malerei — samt
    // Quelle. Ohne diese Zeile stand die Zahl in der Farbe, die vor dem
    // `save` galt: im Probelauf unsichtbar auf dem Grund, in der App
    // zufällig das, was GTK zuletzt gesetzt hatte.
    let text = "\(z.zahl)"
    cairo_set_source_rgba(cr, 1, 1, 1, 1)
    cairo_select_font_face(cr, "sans-serif", CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_BOLD)
    cairo_set_font_size(cr, z.mass * 0.34)
    var mass = cairo_text_extents_t()
    cairo_text_extents(cr, text, &mass)
    cairo_move_to(cr, cx - mass.width / 2 - mass.x_bearing,
                      cy - mass.height / 2 - mass.y_bearing)
    cairo_show_text(cr, text)
    cairo_restore(cr)
}

/// **Abspielen und Pause — auch gezeichnet, und mit einem Übergang.**
///
/// Adwaitas `media-playback-pause-symbolic` ist bei 48 Punkt ein klobiger
/// Doppelbalken; der Mac nimmt `pause.fill`, zwei schlanke Stäbe mit runden
/// Enden, und dazu `.contentTransition(.symbolEffect(.replace.offUp))`.
///
/// Der Kommentar dort ist eindeutig, warum das nicht bloss Zierde ist: „der
/// Knopf muss in demselben Moment umspringen, in dem der Ton aufhört, sonst
/// wirkt der ganze Player träge." Ein Bildwechsel ohne Übergang ist genau das
/// Stockige — es fehlt nicht Zeit, es fehlt die Bewegung.
final class Abspielzeichen: @unchecked Sendable {
    /// **Lebt die Zeichenfläche noch?** Siehe ``Sprungzeichen``.
    fileprivate var lebt = true
    fileprivate var pause: Bool
    /// 0 … 1 über den Wechsel. Bei 1 steht das neue Zeichen.
    fileprivate var lauf: Double = 1
    fileprivate let mass: Double
    let anzeige: Widget

    init(pause: Bool, mass: Double = 48) {
        self.pause = pause
        self.mass = mass
        let feld: Widget! = gtk_drawing_area_new()
        gtk_widget_add_css_class(feld, "swiftly-blank")
        gtk_drawing_area_set_content_width(alsZeichen(feld), Int32(mass))
        gtk_drawing_area_set_content_height(alsZeichen(feld), Int32(mass))
        anzeige = feld!
        gtk_drawing_area_set_draw_func(alsZeichen(feld), abspielMalen,
                                       Unmanaged.passUnretained(self).toOpaque(), nil)
        // Dieselbe Halterung wie bei ``Sprungzeichen`` — dort steht, warum.
        beiSignal(feld, "destroy") { self.lebt = false }
    }

    func setzen(_ neu: Bool) {
        guard neu != pause else { return }
        pause = neu
        lauf = 0
        // **90 ms und keine Fahrt.** Erst fuhr das alte Zeichen nach oben
        // hinaus und das neue kam von unten nach — das sah bei zwei so
        // verschiedenen Formen nach Durcheinander aus und dauerte zu lang.
        // Ein kurzes Ueberblenden liest sich als Umschalten, nicht als
        // Bewegung.
        laufen(auf: anzeige, dauer: 0.09) { [weak self] e in
            self?.lauf = e
            self.map { gtk_widget_queue_draw($0.anzeige) }
        } fertig: { [weak self] in
            self?.lauf = 1
            self.map { gtk_widget_queue_draw($0.anzeige) }
        }
    }
}

/// Ein Stab mit runden Enden — der Baustein der Pause.
private func stab(_ cr: OpaquePointer, _ x: Double, _ y: Double,
                  _ b: Double, _ h: Double) {
    let r = b / 2
    cairo_new_path(cr)
    cairo_arc(cr, x + r, y + r, r, Double.pi, 3 * Double.pi / 2)
    cairo_arc(cr, x + b - r, y + r, r, 3 * Double.pi / 2, 2 * Double.pi)
    cairo_arc(cr, x + b - r, y + h - r, r, 0, Double.pi / 2)
    cairo_arc(cr, x + r, y + h - r, r, Double.pi / 2, Double.pi)
    cairo_close_path(cr)
    cairo_fill(cr)
}

nonisolated(unsafe) private let abspielMalen: @convention(c) (
    UnsafeMutablePointer<GtkDrawingArea>?, OpaquePointer?, Int32, Int32, gpointer?
) -> Void = { _, cr, breite, hoehe, daten in
    guard let cr, let daten else { return }
    let z = Unmanaged<Abspielzeichen>.fromOpaque(daten).takeUnretainedValue()
    guard z.lebt else { return }
    let cx = Double(breite) / 2, cy = Double(hoehe) / 2
    let m = z.mass

    /// Malt eines der beiden Zeichen, mit Deckkraft und Versatz nach oben.
    func zeichen(_ pause: Bool, _ deckung: Double, _ versatz: Double) {
        guard deckung > 0.01 else { return }
        cairo_save(cr)
        cairo_translate(cr, 0, versatz)
        cairo_set_source_rgba(cr, 1, 1, 1, deckung)
        if pause {
            // Zwei Stäbe: je 0,155 breit, 0,52 hoch, 0,105 auseinander.
            let b = m * 0.155, h = m * 0.52, luecke = m * 0.105
            stab(cr, cx - luecke / 2 - b, cy - h / 2, b, h)
            stab(cr, cx + luecke / 2, cy - h / 2, b, h)
        } else {
            // Ein Dreieck mit runden Ecken: derselbe Weg gefüllt **und**
            // gestrichen, mit runden Stössen — dann sind die Spitzen rund,
            // ohne dass jede einzeln gerechnet werden muss.
            let r = m * 0.26, ecke = m * 0.055
            cairo_set_line_join(cr, CAIRO_LINE_JOIN_ROUND)
            cairo_set_line_width(cr, ecke * 2)
            cairo_new_path(cr)
            // Etwas nach rechts gerückt: der Schwerpunkt eines Dreiecks liegt
            // links von seiner Mitte, sonst sähe es aus, als stünde es schief.
            let vx = cx + m * 0.045
            cairo_move_to(cr, vx + r, cy)
            cairo_line_to(cr, vx - r * 0.62, cy - r * 0.9)
            cairo_line_to(cr, vx - r * 0.62, cy + r * 0.9)
            cairo_close_path(cr)
            cairo_fill_preserve(cr)
            cairo_stroke(cr)
        }
        cairo_restore(cr)
    }

    let e = min(max(z.lauf, 0), 1)
    zeichen(!z.pause, 1 - e, 0)
    zeichen(z.pause, e, 0)
}
