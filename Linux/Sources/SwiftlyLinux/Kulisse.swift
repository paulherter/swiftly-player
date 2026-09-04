import CGtk
import Foundation
import JellyfinKit

/// **Das Kopfbild — maskiert, nicht übermalt.**
///
/// Der Mac blendet die Kulisse mit einer *Maske* aus: das Bild wird an den
/// Rändern durchsichtig, und was dahinter liegt, kommt durch. Deshalb gibt es
/// dort keine Kante, egal was dahinter steht.
///
/// Hier standen zuerst zwei Verlaufsflächen **über** dem Bild. Das sieht
/// gleich aus, ist es aber nicht: eine übermalte Kante muss farblich exakt
/// zum Untergrund passen — an jeder Stelle, bei jedem Scrollstand, bei jeder
/// Fensterlage. Sechs Anläufe, sechs Säume: mal hell, mal schwarz, mal ein
/// weisser Faden, der beim Verschieben kam und ging.
///
/// Cairo kann das, was SwiftUI kann. `cairo_mask` malt eine Quelle **durch**
/// ein Muster; zwei geschachtelte Gruppen multiplizieren die beiden Masken,
/// genau wie zwei `.mask`-Aufrufe hintereinander. Damit kann keine Kante mehr
/// entstehen — wo die Maske null ist, ist schlicht nichts gemalt.
///
/// Die Stützstellen sind die des Fernsehers, dort nach vier Umbauten
/// entstanden. Nur die senkrechte ist gestaucht: auf dem Mac ragt die Kulisse
/// über die Kopfzone hinaus und läuft erst darunter aus, was dort ein
/// `zIndex` erlaubt. In einer GTK-Box malt das nächste Geschwister darüber,
/// also endet die Blende hier innerhalb der 380 Punkte.
final class Kulisse {

    /// Die Punkte des Bildes, so wie Cairo sie erwartet. Der Puffer muss
    /// leben, solange die Fläche lebt — deshalb liegt er hier.
    private var punkte: [UInt8] = []
    private var flaeche: OpaquePointer?
    private var breite = 0
    private var hoehe = 0

    let anzeige: Widget

    init() {
        let feld: Widget! = gtk_drawing_area_new()
        gtk_widget_add_css_class(feld, "swiftly-blank")
        gtk_widget_set_hexpand(feld, 1)
        gtk_widget_set_size_request(feld, -1, Int32(Stil.heldHoehe))
        anzeige = feld!
        gtk_drawing_area_set_draw_func(OpaquePointer(feld), kulisseMalen,
                                       Unmanaged.passUnretained(self).toOpaque(), nil)
    }

    deinit { flaecheLoesen() }

    private func flaecheLoesen() {
        if let flaeche { cairo_surface_destroy(flaeche); self.flaeche = nil }
    }

    /// Nimmt ein heruntergeladenes Bild an.
    func setzen(_ daten: Data) {
        daten.withUnsafeBytes { puffer in
            guard let basis = puffer.baseAddress,
                  let bytes = g_bytes_new(basis, gsize(puffer.count)) else { return }
            defer { g_bytes_unref(bytes) }
            var fehler: UnsafeMutablePointer<GError>?
            guard let textur = gdk_texture_new_from_bytes(bytes, &fehler) else {
                if let fehler { g_error_free(fehler) }
                return
            }
            defer { g_object_unref(UnsafeMutableRawPointer(textur)) }

            breite = Int(gdk_texture_get_width(textur))
            hoehe = Int(gdk_texture_get_height(textur))
            guard breite > 0, hoehe > 0 else { return }

            // Cairo will die Zeilenlänge, die es selbst vorgibt.
            let takt = Int(cairo_format_stride_for_width(CAIRO_FORMAT_RGB24, Int32(breite)))
            punkte = [UInt8](repeating: 0, count: takt * hoehe)
            punkte.withUnsafeMutableBufferPointer { speicher in
                guard let ziel = speicher.baseAddress else { return }
                // `gdk_texture_download` liefert BGRA zu acht Bit — auf einem
                // Rechner mit niedrigwertigem Byte zuerst ist das genau
                // Cairos ARGB32.
                gdk_texture_download(textur, ziel, gsize(takt))
            }
            flaecheLoesen()
            punkte.withUnsafeMutableBufferPointer { speicher in
                guard let ziel = speicher.baseAddress else { return }
                flaeche = cairo_image_surface_create_for_data(
                    ziel, CAIRO_FORMAT_RGB24, Int32(breite), Int32(hoehe), Int32(takt))
            }
        }
        gtk_widget_queue_draw(anzeige)
    }

    /// **Die Stützstellen des Fernsehers**, dort nach vier Umbauten
    /// entstanden. Angegeben ist die Sichtbarkeit des Bildes.
    private static let quer: [(Double, Double)] = [
        (0.00, 0.00), (0.15, 0.05), (0.29, 0.22), (0.45, 0.50),
        (0.57, 0.75), (0.70, 0.90), (0.85, 0.98), (1.00, 1.00),
    ]
    private static let hoch: [(Double, Double)] = [
        (0.00, 1.00), (0.55, 1.00), (0.65, 0.92), (0.78, 0.70),
        (0.88, 0.38), (0.95, 0.12), (1.00, 0.00),
    ]

    fileprivate func malen(_ cr: OpaquePointer, _ w: Double, _ h: Double) {
        guard let flaeche, breite > 0, hoehe > 0 else { return }

        // **`max(breite * 0,62, 520)` — die Rechnung des Macs**, rechtsbündig.
        let bb = max(w * 0.62, 520)
        let x0 = w - bb

        // Füllend einpassen: die grössere der beiden Streckungen gewinnt,
        // der Rest wird beschnitten.
        let s = max(bb / Double(breite), h / Double(hoehe))
        let bx = x0 + (bb - Double(breite) * s) / 2
        let by = (h - Double(hoehe) * s) / 2

        cairo_save(cr)
        cairo_rectangle(cr, x0, 0, bb, h)
        cairo_clip(cr)

        // Zwei Gruppen: die innere trägt das Bild, die äussere das Bild mal
        // der ersten Maske. Die zweite Maske trifft dann beide zusammen —
        // dasselbe wie zwei `.mask` hintereinander auf dem Mac.
        cairo_push_group(cr)
        cairo_push_group(cr)
        cairo_save(cr)
        cairo_translate(cr, bx, by)
        cairo_scale(cr, s, s)
        cairo_set_source_surface(cr, flaeche, 0, 0)
        cairo_paint(cr)
        cairo_restore(cr)
        cairo_pop_group_to_source(cr)

        let waagerecht = cairo_pattern_create_linear(x0, 0, x0 + bb, 0)
        for (stelle, deckung) in Self.quer {
            cairo_pattern_add_color_stop_rgba(waagerecht, stelle, 1, 1, 1, deckung)
        }
        cairo_mask(cr, waagerecht)
        cairo_pattern_destroy(waagerecht)
        cairo_pop_group_to_source(cr)

        let senkrecht = cairo_pattern_create_linear(0, 0, 0, h)
        for (stelle, deckung) in Self.hoch {
            cairo_pattern_add_color_stop_rgba(senkrecht, stelle, 1, 1, 1, deckung)
        }
        cairo_mask(cr, senkrecht)
        cairo_pattern_destroy(senkrecht)

        cairo_restore(cr)
    }
}

/// Form: `(GtkDrawingArea*, cairo_t*, int, int, gpointer)`.
nonisolated(unsafe) private let kulisseMalen: @convention(c) (
    UnsafeMutablePointer<GtkDrawingArea>?, OpaquePointer?, Int32, Int32, gpointer?
) -> Void = { _, cr, breite, hoehe, daten in
    guard let cr, let daten else { return }
    Unmanaged<Kulisse>.fromOpaque(daten).takeUnretainedValue()
        .malen(cr, Double(breite), Double(hoehe))
}
