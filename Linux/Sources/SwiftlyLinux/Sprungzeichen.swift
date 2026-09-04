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

    let cx = Double(breite) / 2, cy = Double(hoehe) / 2
    // Die Strichstärke und der Halbmesser wachsen mit dem Zeichen, damit
    // grosse und kleine gleich aussehen. Die Werte sind an der 30er Grösse
    // des Macs abgemessen.
    let r = z.mass * 0.36
    let strich = max(z.mass * 0.062, 1.2)

    cairo_save(cr)
    // **Zurück ist Vor, gespiegelt.** Ein Bild, zwei Richtungen — so kann
    // sich der eine nicht vom anderen weg entwickeln.
    if z.zurueck {
        cairo_translate(cr, cx, 0)
        cairo_scale(cr, -1, 1)
        cairo_translate(cr, -cx, 0)
    }

    cairo_set_source_rgba(cr, 1, 1, 1, 1)
    cairo_set_line_width(cr, strich)
    cairo_set_line_cap(cr, CAIRO_LINE_CAP_BUTT)

    // Der Kreis mit einer Lücke oben: von 295° im Uhrzeigersinn bis 245°.
    // Die Lücke ist damit 50 Grad breit und liegt mittig über dem Zeichen.
    let bogen = Double.pi / 180
    cairo_new_path(cr)
    cairo_arc(cr, cx, cy, r, -65 * bogen, 245 * bogen)
    cairo_stroke(cr)

    // Der Pfeilkopf sitzt am rechten Rand der Lücke und zeigt nach rechts —
    // gespiegelt also nach links, für zurück.
    let ax = cx + r * cos(-65 * bogen)
    let ay = cy + r * sin(-65 * bogen)
    let spitze = z.mass * 0.17
    cairo_new_path(cr)
    cairo_move_to(cr, ax + spitze * 0.9, ay)
    cairo_line_to(cr, ax - spitze * 0.35, ay - spitze * 0.85)
    cairo_line_to(cr, ax - spitze * 0.35, ay + spitze * 0.85)
    cairo_close_path(cr)
    cairo_fill(cr)
    cairo_restore(cr)

    // **Die Zahl steht aufrecht, auch beim Spiegeln.** Deshalb erst nach dem
    // `restore` — sonst stünde bei „zurück" eine seitenverkehrte Zehn.
    let text = "\(z.zahl)"
    cairo_select_font_face(cr, "sans-serif", CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_BOLD)
    cairo_set_font_size(cr, z.mass * 0.36)
    var mass = cairo_text_extents_t()
    cairo_text_extents(cr, text, &mass)
    cairo_move_to(cr, cx - mass.width / 2 - mass.x_bearing,
                      cy - mass.height / 2 - mass.y_bearing)
    cairo_show_text(cr, text)
}
