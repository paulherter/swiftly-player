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
    private var flaeche: OpaquePointer?
    private var mass: Int = 0
    private var teiler: Int32 = 1
    /// Das Bild, das gerade gezeichnet werden soll.
    fileprivate var bild = 0
    private var bilder = 0
    private var dauer = 1.0
    private var beginn = Date()
    private let fertig: () -> Void
    private var schonFertig = false
    private var getaktet = false

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
        FileHandle.standardError.write(Data("[Start] Bilder=\(bilder) Dauer=\(dauer)\n".utf8))
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
        // **Der Takt hält die Animation fest.** Die Frist kann sie aus
        // `App` lösen, während noch ein Takt aussteht; ein schwacher Zeiger
        // zeigte dann auf abgeräumten Speicher. Freigegeben wird sie, wenn
        // der Takt sich selbst abmeldet.
        _ = gtk_widget_add_tick_callback(feld, startTakt,
                                         Unmanaged.passRetained(self).toOpaque(), nil)
    }

    deinit {
        if let flaeche { cairo_surface_destroy(flaeche) }
        if let punkte { punkte.deallocate() }
        if let tier { lottie_animation_destroy(tier) }
    }

    /// Die Vorlage liegt neben der App, im selben `Ressourcen`-Ordner wie das
    /// Anwendungssymbol — hergeleitet aus dem Binärpfad.
    private static var vorlage: String? {
        guard let selbst = try? FileManager.default
            .destinationOfSymbolicLink(atPath: "/proc/self/exe") else { return nil }
        var baum = URL(fileURLWithPath: selbst)
        for _ in 0..<4 { baum.deleteLastPathComponent() }
        let pfad = baum.appendingPathComponent("Ressourcen/startanimation.json").path
        return FileManager.default.fileExists(atPath: pfad) ? pfad : nil
    }

    /// Ein Takt: welches Bild wäre jetzt dran?
    ///
    /// **Nach der Uhr, nicht nach dem Zähler.** Ein Zähler, der je Takt eins
    /// weiterspringt, läuft auf 144 Hz zweieinhalbmal zu schnell — die Vorlage
    /// hat ihre eigene Bildrate, und die Uhr ist der gemeinsame Nenner.
    fileprivate func weiter() -> Bool {
        guard !schonFertig else { return false }
        if bild == 0 && !getaktet {
            getaktet = true
            FileHandle.standardError.write(Data("[Start] Takt laeuft\n".utf8))
        }
        let seit = Date().timeIntervalSince(beginn)
        let neu = min(Int(seit / dauer * Double(bilder)), bilder - 1)
        if neu != bild {
            bild = neu
            gtk_widget_queue_draw(anzeige)
        }
        if seit >= dauer {
            FileHandle.standardError.write(Data("[Start] fertig nach \(seit)\n".utf8))
            abschliessen()
            return false
        }
        return true
    }

    /// **Genau einmal**, egal ob vom Ende der Animation oder von der Frist —
    /// dieselbe Zusicherung, die auf Apple die Klasse `Einmal` gibt.
    func abschliessen() {
        FileHandle.standardError.write(Data("[Start] abschliessen (schon: \(schonFertig))\n".utf8))
        guard !schonFertig else { return }
        schonFertig = true
        fertig()
    }

    /// Rechnet das aktuelle Bild in die Fläche. Gerechnet wird in
    /// **Gerätepunkten**, sonst ist die Marke auf einem feinen Schirm weich.
    fileprivate func flaecheFuer(_ breite: Int32, _ hoehe: Int32) -> OpaquePointer? {
        guard let tier else { return nil }
        let t = max(gtk_widget_get_scale_factor(anzeige), 1)
        // Quadratisch, denn die Vorlage ist es: 1024 × 1024.
        let neu = Int(min(breite, hoehe)) * Int(t)
        guard neu > 0 else { return nil }
        if neu != mass || teiler != t || punkte == nil {
            if let alt = flaeche { cairo_surface_destroy(alt); flaeche = nil }
            if let alt = punkte { alt.deallocate() }
            mass = neu
            teiler = t
            let feld = UnsafeMutablePointer<UInt32>.allocate(capacity: neu * neu)
            feld.initialize(repeating: 0, count: neu * neu)
            punkte = feld
            flaeche = cairo_image_surface_create_for_data(
                UnsafeMutableRawPointer(feld).assumingMemoryBound(to: UInt8.self),
                CAIRO_FORMAT_ARGB32, Int32(mass), Int32(mass), Int32(mass * 4))
        }
        guard let punkte else { return nil }
        lottie_animation_render(tier, size_t(bild), punkte,
                                size_t(mass), size_t(mass), size_t(mass * 4))
        if let flaeche { cairo_surface_mark_dirty(flaeche) }
        return flaeche
    }

    fileprivate var punktmass: Int { mass }
    fileprivate var punktteiler: Int32 { teiler }
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
    let a = Unmanaged<Startanimation>.fromOpaque(daten).takeUnretainedValue()
    guard let flaeche = a.flaecheFuer(breite, hoehe) else { return }
    // Die Marke steht mittig und in der Grösse, die die Vorlage vorgibt —
    // hier ein Drittel der kürzeren Fensterseite, wie auf dem Mac.
    let seite = Double(a.punktmass) / Double(a.punktteiler)
    cairo_save(cr)
    cairo_translate(cr, (Double(breite) - seite) / 2, (Double(hoehe) - seite) / 2)
    cairo_scale(cr, 1 / Double(a.punktteiler), 1 / Double(a.punktteiler))
    cairo_set_source_surface(cr, flaeche, 0, 0)
    cairo_paint(cr)
    cairo_restore(cr)
}
