// **Nur wo rlottie gebaut ist.** Auf Linux legt `Werkzeuge/rlottie-bauen.sh`
// die Bibliothek an; fuer Windows gibt es sie noch nicht. Ohne sie faellt
// die Startanimation weg — die App startet dann sofort in die Anmeldung,
// was kein Fehler ist, sondern nur weniger schoen.
#if canImport(CRlottie)
import CGtk
import CRlottie
import Foundation

/// **Die Startanimation — dieselbe Datei wie auf iPhone, Fernseher und Mac.**
///
/// Die Vorlage kommt als Lottie aus After Effects: das Dreieck fährt auf, dann
/// fahren die Buchstaben aus. In `Sources/Shared/Startanimation.swift` steht,
/// warum sie nicht nachgebaut wird — „jeder Keyframe trägt eigene
/// Bezier-Anläufe, und die von Hand nachzurechnen führt zu einer Bewegung, die
/// *fast* stimmt. Das fällt mehr auf als ein zusätzliches Paket." Das galt
/// dort für Lottie, und es gilt hier genauso.
///
/// Auf Apple spielt sie das Lottie-Paket ab. GTK kann das nicht, also rechnet
/// **rlottie** die Bilder und Cairo malt sie. rlottie schreibt BGRA mit
/// vorgewichteter Deckkraft — genau das, was `CAIRO_FORMAT_ARGB32` auf einer
/// Little-Endian-Maschine erwartet; es wird also nichts umsortiert.
///
/// **Am Bildtakt, nicht an einem Zeitgeber** — dieselbe Regel wie überall
/// hier: `g_timeout_add` liefe auf jedem Schirm mit 62 Bildern.
final class Startanimation: @unchecked Sendable {

    private var tier: OpaquePointer?
    /// **Von Hand belegt, nicht als Feld.**
    ///
    /// `cairo_image_surface_create_for_data` behält den Zeiger, den es
    /// bekommt. Ein Swift-Feld darf sich aber jederzeit verschieben, und der
    /// Zeiger aus `withUnsafeMutableBufferPointer` gilt ausdrücklich nur
    /// innerhalb des Blocks — er nach draussen zu reichen ist genau der
    /// Fehler, der die App beim ersten Bild abgeräumt hat.
    private var punkte: UnsafeMutablePointer<UInt32>?
    private var mass: Int = 0
    private var teiler: Int32 = 1
    /// Das Bild, das gerade gezeichnet werden soll.
    fileprivate var bild = 0
    private var bilder = 0
    private var dauer = 1.0
    private var beginn = Date()
    private let fertig: () -> Void
    private var schonFertig = false
    private var gestartet = false
    private var takte = 0
    /// Welches Bild schon in der Fläche steht.
    private var gerechnet = -1

    let anzeige: Widget

    /// `nil`, wenn die Vorlage fehlt oder rlottie sie nicht lesen kann. Dann
    /// gibt es keine Animation — und keinen Absturz.
    init?(fertig: @escaping () -> Void) {
        guard let quelle = Startanimation.vorlage,
              let text = try? String(contentsOfFile: quelle, encoding: .utf8) else { return nil }
        self.fertig = fertig
        // Der zweite Name ist der Schlüssel des Zwischenspeichers, der dritte
        // der Ort für nachgeladene Bilder — wir haben keine.
        guard let tier = lottie_animation_from_data(text, "swiftly-start", "") else { return nil }
        self.tier = tier
        bilder = Int(lottie_animation_get_totalframe(tier))
        dauer = lottie_animation_get_duration(tier)
        guard bilder > 0, dauer > 0 else {
            lottie_animation_destroy(tier)
            return nil
        }

        let feld: Widget! = gtk_drawing_area_new()
        gtk_widget_add_css_class(feld, "swiftly-blank")
        gtk_widget_set_hexpand(feld, 1)
        gtk_widget_set_vexpand(feld, 1)
        anzeige = feld!
        gtk_drawing_area_set_draw_func(alsZeichen(feld), startMalen,
                                       Unmanaged.passUnretained(self).toOpaque(), nil)
        // **Losfahren, wenn das Widget wirklich auf dem Schirm ist.**
        //
        // `gtk_widget_add_tick_callback` fordert nur dann Bilder an, wenn das
        // Widget schon eine Bilduhr hat — also wenn es aufgelegt ist. Vorher
        // stand der Aufruf nach `gtk_window_present`, und das genügt unter
        // Wayland nicht: das Auflegen kommt später. Gemessen: **kein
        // einziger Takt.** Eine Weile lief es trotzdem, weil eine
        // Auslegungsschleife nebenher dauernd Bilder erzwang; als die weg
        // war, stand die Animation still.
        //
        // `map` ist der Zeitpunkt, an dem es sicher ist.
        beiSignal(feld, "map") { [weak self] in self?.losfahren() }

    }

    deinit {
        if let punkte { punkte.deallocate() }
        if let tier { lottie_animation_destroy(tier) }
    }

    /// Die Vorlage liegt neben der App, im selben `Ressourcen`-Ordner wie das
    /// Anwendungssymbol — hergeleitet aus dem Binärpfad.
    private static var vorlage: String? {
        Plattform.mitgeliefert("startanimation.json")
    }

    /// **Losfahren, sobald das Fenster wirklich steht.**
    ///
    /// Der Bildtakt hing vorher schon im `init`. Gemessen: er lief **genau
    /// einmal**, bei 0,05 s, und danach nie wieder. Ein Widget, das noch in
    /// keinem Fenster hängt, hat keine Bilduhr; GTK merkt sich den Rückruf
    /// zwar, aber die Uhr fordert für ihn keine Bilder an, und was danach
    /// einmal durchkommt, bleibt ein Zufallstreffer.
    ///
    /// Auf dem Mac steht an derselben Stelle dieselbe Lehre, nur für SwiftUI:
    /// „Losfahren, sobald die Seite wirklich steht" — dort war ein
    /// `Task.sleep` das Rennen, hier die Bilduhr.
    ///
    /// **Der Takt hält die Animation fest** (Falle 4): die Frist kann sie aus
    /// `App` lösen, während noch ein Takt aussteht. Freigegeben wird sie,
    /// wenn der Takt sich abmeldet.
    func losfahren() {
        guard !gestartet else { return }
        gestartet = true
        beginn = Date()
        _ = gtk_widget_add_tick_callback(anzeige, startTakt,
                                         Unmanaged.passRetained(self).toOpaque(), nil)
    }

    /// Ein Takt: welches Bild wäre jetzt dran?
    ///
    /// **Nach der Uhr, nicht nach dem Zähler.** Ein Zähler, der je Takt eins
    /// weiterspringt, läuft auf 144 Hz zweieinhalbmal zu schnell — die Vorlage
    /// hat ihre eigene Bildrate, und die Uhr ist der gemeinsame Nenner.
    fileprivate func weiter() -> Bool {
        guard !schonFertig else { return false }
        takte += 1
        if takte % 40 == 1 {
        }
        let seit = Date().timeIntervalSince(beginn)
        let neu = min(Int(seit / dauer * Double(bilder)), bilder - 1)
        if neu != bild {
            bild = neu
            gtk_widget_queue_draw(anzeige)
        }
        if seit >= dauer {
            abschliessen()
            return false
        }
        return true
    }

    /// **Genau einmal**, egal ob vom Ende der Animation oder von der Frist —
    /// dieselbe Zusicherung, die auf Apple die Klasse `Einmal` gibt.
    func abschliessen() {
        guard !schonFertig else { return }
        schonFertig = true
        fertig()
    }

    /// Rechnet das aktuelle Bild und gibt eine **frische** Fläche darauf.
    ///
    /// **Warum jedes Mal eine neue.** Erst hielt ich eine Fläche über alle
    /// Bilder und erklärte sie nach jedem Rechnen für verändert. Cairo legt
    /// aber von einer Fläche, die einmal als Quelle gedient hat, eine
    /// Momentaufnahme an — und `cairo_surface_mark_dirty` bricht dann ab:
    ///
    ///     cairo-surface.c:1739: Assertion
    ///     `! _cairo_surface_has_snapshots (surface)' failed.
    ///
    /// Das war das schwarze Fenster über fünf Anläufe. Nicht die Animation
    /// war kaputt und nicht ihr Abgang: **die App stürzte beim zweiten Bild
    /// ab.** Deshalb kam auch nie ein zweiter Takt — es gab keinen Prozess
    /// mehr, der hätte takten können.
    ///
    /// `cairo_image_surface_create_for_data` kopiert nichts, es legt nur eine
    /// Hülle um den Puffer. Eine je Bild kostet also fast nichts und hat
    /// keine Vorgeschichte.
    fileprivate func malen(_ cr: OpaquePointer, _ breite: Int32, _ hoehe: Int32) {
        guard let tier else { return }
        let t = max(gtk_widget_get_scale_factor(anzeige), 1)
        // **Die Marke ist ein Zeichen, kein Hintergrund** — gedeckelt bei 360.
        let seite = min(Int(min(breite, hoehe)), 360)
        let neu = seite * Int(t)
        guard neu > 0 else { return }

        if neu != mass || teiler != t || punkte == nil {
            if let alt = punkte { alt.deallocate() }
            mass = neu
            teiler = t
            let feld = UnsafeMutablePointer<UInt32>.allocate(capacity: neu * neu)
            feld.initialize(repeating: 0, count: neu * neu)
            punkte = feld
            gerechnet = -1
        }
        guard let punkte else { return }

        if gerechnet != bild {
            gerechnet = bild
            lottie_animation_render(tier, size_t(bild), punkte,
                                    size_t(mass), size_t(mass), size_t(mass * 4))
        }

        guard let flaeche = cairo_image_surface_create_for_data(
            UnsafeMutableRawPointer(punkte).assumingMemoryBound(to: UInt8.self),
            CAIRO_FORMAT_ARGB32, Int32(mass), Int32(mass), Int32(mass * 4))
        else { return }
        defer { cairo_surface_destroy(flaeche) }

        let kante = Double(mass) / Double(teiler)
        cairo_save(cr)
        cairo_translate(cr, (Double(breite) - kante) / 2, (Double(hoehe) - kante) / 2)
        cairo_scale(cr, 1 / Double(teiler), 1 / Double(teiler))
        cairo_set_source_surface(cr, flaeche, 0, 0)
        cairo_paint(cr)
        cairo_restore(cr)
    }

}

nonisolated(unsafe) private let startTakt: @convention(c) (
    UnsafeMutablePointer<GtkWidget>?, OpaquePointer?, gpointer?
) -> gboolean = { _, _, daten in
    guard let daten else { return 0 }
    let a = Unmanaged<Startanimation>.fromOpaque(daten)
    if a.takeUnretainedValue().weiter() { return 1 }
    a.release()
    return 0   // G_SOURCE_REMOVE
}

nonisolated(unsafe) private let startMalen: @convention(c) (
    UnsafeMutablePointer<GtkDrawingArea>?, OpaquePointer?, Int32, Int32, gpointer?
) -> Void = { _, cr, breite, hoehe, daten in
    guard let cr, let daten else { return }
    Unmanaged<Startanimation>.fromOpaque(daten).takeUnretainedValue()
        .malen(cr, breite, hoehe)
}

#else

import CGtk

/// **Ohne rlottie gibt es keine Startanimation** — und das darf die
/// Aufrufstellen nichts angehen. Der Platzhalter hat denselben Konstruktor
/// wie das Original, nur schlägt er fehl; damit läuft der Zweig in ``App``
/// gar nicht erst an, und dort steht kein einziges `#if`.
final class Startanimation {
    let anzeige: Widget
    init?(fertig: @escaping () -> Void) { return nil }
}

#endif
