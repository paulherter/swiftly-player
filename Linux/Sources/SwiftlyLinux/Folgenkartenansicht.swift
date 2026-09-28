import CGtk
import Foundation
import JellyfinKit

/// **Die nächste Folge als Karte unten rechts** — Variante C, Vorlage
/// `Sources/iOS/Folgenkartenansicht.swift`. Zeiten, Federn und Maße stehen in
/// ``Folgenkarte`` im Paket; hier nur die Zeichnung für den Schreibtisch.
///
/// Vorschaubild der Folge, darauf der Countdown-Ring mit Spielzeichen, rund
/// das X an der Ecke; darunter „S6 • F11 … in 7 s" und der Titel. Klick oder
/// Eingabe spielt die Folge, X oder Escape sagt ab (der Abspann läuft
/// weiter, am Dateiende wird nicht mehr weitergeschaltet).
///
/// **Was es hier nicht gibt, und warum** (VERHALTEN F, Eingabeart):
/// - **Wegwischen** — eine Fingergeste; mit der Maus gibt es X und Escape.
/// - **Der Zoom der Karte aufs ganze Bild** beim Start. GTK kann ein Widget
///   nicht über das laufende libVLC-Bild wachsen lassen, ohne es jedes Bild
///   neu auszulegen; die Karte blendet stattdessen weg, und die neue Folge
///   beginnt unter dem Ladeschleier wie jeder Wechsel.
///
/// Herein kommt sie von rechts aus 94 % Größe (``Folgenkarte/versatz``,
/// ``Folgenkarte/startmass``), über das Stilblatt — dessen Übergänge richten
/// sich von selbst nach „Bewegung reduzieren" (`gtk-enable-animations`).
final class Folgenkartenansicht: @unchecked Sendable {
    /// Die ganze Karte samt Zeilen — liegt als Ebene über dem Bild.
    private(set) var huelle: Widget!
    private var knopf: Widget!
    private var bild: Widget!
    private var ring: Widget!
    private var kuerzel: Widget!
    private var restzeile: Widget!
    private var titel: Widget!
    private var folgeID: String?
    private var bildAdresse: URL?
    private(set) var da = false
    fileprivate var uhr: Fuellungsuhr?
    private var takt: guint = 0
    fileprivate var lebt = true

    private let masse = Folgenkarte.iPhone
    /// Kartenbreite — ``Folgenkarte/breite(_:sichereBreite:gross:)``: der
    /// Schreibtisch nimmt das große Maß wie das iPad, höchstens 30 % der
    /// Fensterbreite.
    private(set) var breite: Int32 = 300

    init(ausloesen: @escaping () -> Void, abbrechen: @escaping () -> Void) {
        let aussen = stapel(GTK_ORIENTATION_VERTICAL, abstand: Int32(masse.abstand))
        gtk_widget_add_css_class(aussen, "swiftly-folgenkarte")
        gtk_widget_add_css_class(aussen, "swiftly-folgenkarte-weg")
        gtk_widget_set_halign(aussen, GTK_ALIGN_END)
        gtk_widget_set_valign(aussen, GTK_ALIGN_END)
        gtk_widget_set_can_target(aussen, 0)
        huelle = aussen

        // Die Karte: ein Knopf mit Bild und Ring, das X liegt darüber.
        let ecke: Widget! = gtk_overlay_new()
        let knopf: Widget! = gtk_button_new()
        gtk_widget_add_css_class(knopf, "swiftly-kartenbild")
        gtk_widget_set_overflow(knopf, GTK_OVERFLOW_HIDDEN)
        let innen: Widget! = gtk_overlay_new()
        let bild: Widget! = gtk_picture_new()
        gtk_picture_set_content_fit(OpaquePointer(bild), GTK_CONTENT_FIT_COVER)
        gtk_picture_set_can_shrink(OpaquePointer(bild), 1)
        gtk_overlay_set_child(OpaquePointer(innen), bild)
        let ring: Widget! = gtk_drawing_area_new()
        gtk_drawing_area_set_content_width(alsZeichen(ring), Int32(masse.ring))
        gtk_drawing_area_set_content_height(alsZeichen(ring), Int32(masse.ring))
        gtk_widget_set_halign(ring, GTK_ALIGN_CENTER)
        gtk_widget_set_valign(ring, GTK_ALIGN_CENTER)
        gtk_widget_set_can_target(ring, 0)
        gtk_drawing_area_set_draw_func(alsZeichen(ring), ringMalen,
                                       Unmanaged.passUnretained(self).toOpaque(), nil)
        gtk_overlay_add_overlay(OpaquePointer(innen), ring)
        gtk_button_set_child(alsKnopf(knopf), innen)
        beiSignal(knopf, "clicked", ausloesen)
        gtk_overlay_set_child(OpaquePointer(ecke), knopf)

        // Das runde X an der Kartenecke (wie bei Max): Karte weg, Countdown
        // aus, Abspann läuft.
        let zu: Widget! = gtk_button_new()
        gtk_widget_add_css_class(zu, "swiftly-kartenzu")
        let kreuz = Playerzeichen("schliessen", groesse: 11)
        gtk_button_set_child(alsKnopf(zu), kreuz.anzeige)
        gtk_widget_set_halign(zu, GTK_ALIGN_END)
        gtk_widget_set_valign(zu, GTK_ALIGN_START)
        beschriften(zu, uebersetzt("Karte schließen"))
        gtk_widget_set_tooltip_text(zu, uebersetzt("Karte schließen"))
        beiSignal(zu, "clicked") {
            Protokoll.schreib("[Karte] × gedrückt")
            abbrechen()
        }
        gtk_overlay_add_overlay(OpaquePointer(ecke), zu)
        anhaengen(aussen, ecke)

        // Die zwei Zeilen darunter.
        let zeilen = stapel(GTK_ORIENTATION_VERTICAL, abstand: 3)
        gtk_widget_set_can_target(zeilen, 0)
        let oben = stapel(GTK_ORIENTATION_HORIZONTAL, abstand: 12)
        kuerzel = beschriftung("", stil: "swiftly-kartenklein")
        gtk_label_set_xalign(OpaquePointer(kuerzel), 0)
        gtk_widget_set_hexpand(kuerzel, 1)
        gtk_label_set_ellipsize(OpaquePointer(kuerzel), PANGO_ELLIPSIZE_END)
        anhaengen(oben, kuerzel)
        restzeile = beschriftung("", stil: "swiftly-kartenklein")
        gtk_widget_add_css_class(restzeile, "swiftly-tnum")
        anhaengen(oben, restzeile)
        anhaengen(zeilen, oben)
        titel = beschriftung("", stil: "swiftly-kartentitel")
        gtk_label_set_xalign(OpaquePointer(titel), 0)
        gtk_label_set_ellipsize(OpaquePointer(titel), PANGO_ELLIPSIZE_END)
        gtk_label_set_single_line_mode(OpaquePointer(titel), 1)
        anhaengen(zeilen, titel)
        anhaengen(aussen, zeilen)

        self.knopf = knopf
        self.bild = bild
        self.ring = ring
        gtk_widget_set_visible(aussen, 0)

        // Die Ebene hält das Objekt; nach dem Abräumen zeigt nichts mehr hin.
        let selbst = Unmanaged.passRetained(self)
        beiSignal(aussen, "destroy") {
            let k = selbst.takeUnretainedValue()
            k.lebt = false
            k.takt = 0
            k.huelle = nil; k.knopf = nil; k.bild = nil; k.ring = nil
            k.kuerzel = nil; k.restzeile = nil; k.titel = nil
            selbst.release()
        }
    }

    /// Den Stand übernehmen — die Folge, ob die Karte steht, die Uhr des
    /// Countdowns und die restlichen Sekunden.
    func setzen(folge: Item?, bild adresse: URL?, da neu: Bool, uhr neueUhr: Fuellungsuhr?,
                rest: Int, fensterbreite: Int32) {
        guard lebt, huelle != nil else { return }
        let b = Int32(Folgenkarte.breite(masse, sichereBreite: Double(fensterbreite), gross: true)
            .rounded())
        if b > 0, b != breite || gtk_widget_get_width(knopf) == 0 {
            breite = b
            gtk_widget_set_size_request(knopf, b, b * 9 / 16)
            gtk_widget_set_size_request(huelle, b, -1)
        }
        if let folge, folge.id != folgeID {
            folgeID = folge.id
            // Aus dem Paket (`folgenkuerzel`), nicht mehr von Hand: stand hier
            // fest als „F", auch auf Englisch — dort ist es „E" (gemeldet
            // 27.09.2026).
            let k = folge.folgenkuerzel ?? folge.name
            gtk_label_set_text(OpaquePointer(kuerzel), k)
            gtk_label_set_text(OpaquePointer(titel), folge.name)
            beschriften(knopf, String(format: uebersetzt("Nächste Folge abspielen: %@"), k))
        }
        if adresse != bildAdresse {
            bildAdresse = adresse
            gtk_picture_set_paintable(OpaquePointer(bild), nil)
            if let adresse {
                bildLaden(bild, url: adresse, schluessel: Bildschluessel.fuer(adresse), sofort: true)
            }
        }
        gtk_label_set_text(OpaquePointer(restzeile), String(format: uebersetzt("in %lld s"), Int64(rest)))
        if neu != da {
            da = neu
            Protokoll.schreib("[Karte] \(neu ? "herein" : "hinaus")")
            fflush(nil)
            if neu {
                gtk_widget_set_visible(huelle, 1)
                // Erst sichtbar, dann im nächsten Bild die Klasse weg — sonst
                // übergeht GTK den Übergang.
                nachFrist(Folgenkarte.erscheinenVerzug) { [weak self] in
                    guard let self, self.lebt, self.da, let h = self.huelle else { return }
                    gtk_widget_remove_css_class(h, "swiftly-folgenkarte-weg")
                }
            } else {
                gtk_widget_add_css_class(huelle, "swiftly-folgenkarte-weg")
            }
            gtk_widget_set_can_target(huelle, neu ? 1 : 0)
        }
        uhr = neueUhr
        if da, uhr != nil {
            gtk_widget_queue_draw(ring)
            if takt == 0 {
                takt = gtk_widget_add_tick_callback(ring, ringTakt,
                                                    Unmanaged.passUnretained(self).toOpaque(), nil)
            }
        } else if takt != 0 {
            gtk_widget_remove_tick_callback(ring, takt)
            takt = 0
        }
    }

    /// Wie weit die Karte über dem unteren Rand steht — über der Zeitleiste,
    /// solange die Steuerung offen ist.
    func unten(_ abstand: Int32) {
        guard lebt, let huelle else { return }
        let vorher = Double(gtk_widget_get_margin_bottom(huelle))
        guard Int32(vorher) != abstand else { return }
        sanft(auf: huelle, von: vorher, nach: Double(abstand)) { [weak self] wert in
            guard let self, self.lebt, let h = self.huelle else { return }
            gtk_widget_set_margin_bottom(h, Int32(wert.rounded()))
        }
    }

    fileprivate func ringZeichnen() {
        guard lebt, let ring else { return }
        gtk_widget_queue_draw(ring)
    }

    fileprivate var anteil: Double { uhr?.anteil() ?? 0 }
}

nonisolated(unsafe) private let ringTakt: @convention(c) (
    UnsafeMutablePointer<GtkWidget>?, OpaquePointer?, gpointer?
) -> gboolean = { _, _, daten in
    guard let daten else { return 0 }
    Unmanaged<Folgenkartenansicht>.fromOpaque(daten).takeUnretainedValue().ringZeichnen()
    return 1
}

/// Countdown-Ring mit Spielzeichen — wörtlich `Countdownring` aus
/// `Sources/Shared/Folgenkartenteile.swift`: Schwarz 50 %, Spur Weiß 18 %,
/// Füllung im Akzent mit runden Enden, Strich 3/56 des Durchmessers, das
/// Dreieck 30 % groß und um 3 % nach rechts.
nonisolated(unsafe) private let ringMalen: @convention(c) (
    UnsafeMutablePointer<GtkDrawingArea>?, OpaquePointer?, Int32, Int32, gpointer?
) -> Void = { _, cr, breite, hoehe, daten in
    guard let cr, let daten else { return }
    let k = Unmanaged<Folgenkartenansicht>.fromOpaque(daten).takeUnretainedValue()
    guard k.lebt else { return }
    let d = Double(min(breite, hoehe))
    let m = (x: Double(breite) / 2, y: Double(hoehe) / 2)
    let strich = d * 3 / 56
    cairo_set_source_rgba(cr, 0, 0, 0, 0.5)
    cairo_arc(cr, m.x, m.y, d / 2, 0, 2 * .pi)
    cairo_fill(cr)
    let r = d / 2 - strich
    cairo_set_line_width(cr, strich)
    cairo_set_source_rgba(cr, 1, 1, 1, 0.18)
    cairo_arc(cr, m.x, m.y, r, 0, 2 * .pi)
    cairo_stroke(cr)
    let anteil = k.anteil
    if anteil > 0 {
        let a = Stil.akzentRGB
        cairo_set_source_rgba(cr, a.0, a.1, a.2, 1)
        cairo_set_line_cap(cr, CAIRO_LINE_CAP_ROUND)
        cairo_arc(cr, m.x, m.y, r, -.pi / 2, -.pi / 2 + 2 * .pi * anteil)
        cairo_stroke(cr)
    }
    // Spielzeichen: gleichseitig, 30 % des Durchmessers hoch.
    let h = d * 0.3, w = h * 0.87
    let x0 = m.x - w / 2 + d * 0.03 + w * 0.08
    cairo_set_source_rgba(cr, 1, 1, 1, 1)
    cairo_move_to(cr, x0, m.y - h / 2)
    cairo_line_to(cr, x0 + w, m.y)
    cairo_line_to(cr, x0, m.y + h / 2)
    cairo_close_path(cr)
    cairo_fill(cr)
}
