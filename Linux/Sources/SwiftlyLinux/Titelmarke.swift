import CGtk
import Foundation
import JellyfinKit

/// Ein vermessenes, zugeschnittenes Logo als Textur.
///
/// Der Zeiger ist eine Referenz, die der Speicher hält und nie freigibt: es
/// gibt je Adresse höchstens ein Logo, und es ist klein.
struct Titellogo: @unchecked Sendable {
    let textur: OpaquePointer
    let messung: Logomessung
}

/// Merkt Logos je Adresse; „kein brauchbares Logo" merkt es sich ebenfalls,
/// damit nicht jede Seite neu holt. Angefasst nur auf GTKs Hauptfaden.
///
/// Zuschneiden und Messen (`Titelmarkenmass`, im Paket) laufen abseits davon.
enum Titellogospeicher {
    nonisolated(unsafe) private static var bekannt: [URL: Titellogo] = [:]
    nonisolated(unsafe) private static var leer: Set<URL> = []

    /// `.some(nil)`: Adresse ohne brauchbares Logo. `nil`: noch nicht versucht.
    static func gemerkt(_ url: URL) -> Titellogo?? {
        if let da = bekannt[url] { return .some(da) }
        return leer.contains(url) ? .some(nil) : nil
    }

    static func merken(_ url: URL, _ logo: Titellogo?) {
        if let logo { bekannt[url] = logo } else { leer.insert(url) }
    }

    /// Entpacken, vormultipliziert lesen, vermessen, auf die deckende Fläche
    /// zuschneiden. Dunkle Logos werden zur weißen Silhouette (gleicher Alpha).
    /// Auf jedem Faden erlaubt.
    static func vermessen(_ daten: Data) -> Titellogo? {
        daten.withUnsafeBytes { puffer -> Titellogo? in
            guard let basis = puffer.baseAddress, let lader = gdk_pixbuf_loader_new() else { return nil }
            defer { g_object_unref(UnsafeMutableRawPointer(lader)) }
            var fehler: UnsafeMutablePointer<GError>?
            let geschrieben = gdk_pixbuf_loader_write(lader, basis.assumingMemoryBound(to: guchar.self),
                                                      gsize(puffer.count), &fehler) != 0
            if let f = fehler { g_error_free(f); fehler = nil }
            let geschlossen = gdk_pixbuf_loader_close(lader, &fehler) != 0
            if let f = fehler { g_error_free(f) }
            guard geschrieben, geschlossen, let bild = gdk_pixbuf_loader_get_pixbuf(lader),
                  gdk_pixbuf_get_bits_per_sample(bild) == 8 else { return nil }
            let alpha = gdk_pixbuf_get_has_alpha(bild) != 0
            let kanaele = Int(gdk_pixbuf_get_n_channels(bild))
            guard kanaele == (alpha ? 4 : 3) else { return nil }
            let b = Int(gdk_pixbuf_get_width(bild)), h = Int(gdk_pixbuf_get_height(bild))
            let schritt = Int(gdk_pixbuf_get_rowstride(bild))
            guard b > 0, h > 0, let pixel = gdk_pixbuf_read_pixel_bytes(bild) else { return nil }
            defer { g_bytes_unref(pixel) }
            var laenge: gsize = 0
            guard let roh = g_bytes_get_data(pixel, &laenge)?.assumingMemoryBound(to: UInt8.self),
                  Int(laenge) >= (h - 1) * schritt + b * kanaele else { return nil }

            // GdkPixbuf liefert nicht vormultipliziert; das Paket misst und
            // GTK zeichnet vormultipliziert.
            var rgba = [UInt8](repeating: 0, count: b * h * 4)
            for y in 0..<h {
                for x in 0..<b {
                    let q = y * schritt + x * kanaele
                    let z = (y * b + x) * 4
                    let a = alpha ? Int(roh[q + 3]) : 255
                    rgba[z] = UInt8((Int(roh[q]) * a + 127) / 255)
                    rgba[z + 1] = UInt8((Int(roh[q + 1]) * a + 127) / 255)
                    rgba[z + 2] = UInt8((Int(roh[q + 2]) * a + 127) / 255)
                    rgba[z + 3] = UInt8(a)
                }
            }
            guard let m = Titelmarkenmass.messen(rgba: rgba, breite: b, hoehe: h) else { return nil }
            let dunkel = Titelmarkenmass.istDunkel(luminanz: m.luminanz)
            var zu = [UInt8](repeating: 0, count: m.breite * m.hoehe * 4)
            for y in 0..<m.hoehe {
                for x in 0..<m.breite {
                    let q = ((y + m.y) * b + x + m.x) * 4
                    let z = (y * m.breite + x) * 4
                    let a = rgba[q + 3]
                    if dunkel {
                        // Weiß, vormultipliziert: alle Kanäle gleich Alpha.
                        zu[z] = a; zu[z + 1] = a; zu[z + 2] = a
                    } else {
                        zu[z] = rgba[q]; zu[z + 1] = rgba[q + 1]; zu[z + 2] = rgba[q + 2]
                    }
                    zu[z + 3] = a
                }
            }
            let textur: OpaquePointer? = zu.withUnsafeBytes { p in
                guard let bytes = g_bytes_new(p.baseAddress, gsize(p.count)) else { return nil }
                defer { g_bytes_unref(bytes) }
                return gdk_memory_texture_new(Int32(m.breite), Int32(m.hoehe),
                                              GDK_MEMORY_R8G8B8A8_PREMULTIPLIED,
                                              bytes, gsize(m.breite * 4))
            }
            guard let textur else { return nil }
            return Titellogo(textur: textur, messung: m)
        }
    }
}

/// Die beiden Widgets des Titelfachs, über Fadengrenzen getragen; angefasst
/// wird nur auf dem Hauptfaden.
struct Titelfelder: @unchecked Sendable {
    let bild: Widget!
    let text: Widget!

    static func zeigen(_ logo: Titellogo, in f: Titelfelder, weich: Bool) {
        let g = Titelmarkenmass.groesse(seitenverhaeltnis: logo.messung.seitenverhaeltnis,
                                        dichte: logo.messung.dichte,
                                        zeile: Double(Stil.titelGross), maxBreite: 640,
                                        maxHoehe: 42)
        gtk_widget_set_size_request(f.bild, Int32(g.breite.rounded()), Int32(g.hoehe.rounded()))
        gtk_picture_set_paintable(OpaquePointer(f.bild), logo.textur)
        guard weich, !Schubsperre.faehrt else {
            gtk_widget_set_opacity(f.bild, 1)
            gtk_widget_set_opacity(f.text, 0)
            return
        }
        laufen(auf: f.bild, dauer: bewegungReduziert() ? Stil.zeitReduziert : 0.22) { e in
            gtk_widget_set_opacity(f.bild, e)
            gtk_widget_set_opacity(f.text, 1 - e)
        } fertig: {
            gtk_widget_set_opacity(f.bild, 1)
            gtk_widget_set_opacity(f.text, 0)
        }
    }
}

extension App {
    /// **Titel als Logo** im festen Titelfach der Film- und Serienseite
    /// (Mac: `Titelmarke(platz: .fach(hoehe: 42))`).
    ///
    /// Der Text steht an seinem Platz; ist der Schalter an und führt der
    /// Server ein Logo, blendet es weich über ihn. Größe nach
    /// `Titelmarkenmass.groesse` (Titelzeile 28, Fach 640 × 42): das Logo
    /// bleibt in der Höhe des Fachs, nichts darunter wandert. Scheitert der
    /// Abruf oder gibt es keins, bleibt der Text.
    func titelmarkeAnbinden(_ huelle: Widget!, text: Widget!, titel: Item) {
        guard wahlen.titelAlsLogo, let adressen,
              let url = Bildwahl.logo(titel, adressen: adressen) else { return }
        let bildfeld: Widget! = gtk_picture_new()
        gtk_picture_set_can_shrink(OpaquePointer(bildfeld), 1)
        gtk_picture_set_content_fit(OpaquePointer(bildfeld), GTK_CONTENT_FIT_FILL)
        gtk_widget_set_halign(bildfeld, GTK_ALIGN_START)
        gtk_widget_set_valign(bildfeld, GTK_ALIGN_CENTER)
        gtk_widget_set_can_target(bildfeld, 0)
        gtk_widget_set_opacity(bildfeld, 0)
        gtk_overlay_add_overlay(OpaquePointer(huelle), bildfeld)

        let felder = Titelfelder(bild: bildfeld, text: text)
        if let gemerkt = Titellogospeicher.gemerkt(url) {
            if let logo = gemerkt { Titelfelder.zeigen(logo, in: felder, weich: false) }
            return
        }
        let zeichen = Lebenszeichen(bildfeld)
        Task.detached { [self] in
            _ = self
            var logo: Titellogo?
            if let daten = await Bildlager.shared.laden(url, schluessel: Bildschluessel.fuer(url)) {
                logo = Titellogospeicher.vermessen(daten)
            }
            let ergebnis = logo
            aufHauptfaden {
                Titellogospeicher.merken(url, ergebnis)
                guard zeichen.lebt, let ergebnis else { return }
                Titelfelder.zeigen(ergebnis, in: felder, weich: true)
            }
        }
    }
}
