import CGtk
import Foundation

/// **Drei Regler — gezeichnet, weil Adwaita sie nicht hat.**
///
/// Der Mac setzt auf den Wiedergabe-Chip im Player `slider.horizontal.3`
/// (`Sources/macOS/PlayerScreen.swift:406`): drei waagerechte Schienen mit je
/// einem Knauf an anderer Stelle. Hier stand `media-eq-symbolic`, und den Namen
/// gibt es im Adwaita-Satz nicht — auf cachy nachgesehen, kein Treffer. GTK
/// zeigt dann das Ersatzbild „fehlendes Bild", und genau das meinte Paul mit
/// „die Icons fixen".
///
/// Dieselbe Antwort wie bei ``Sprungzeichen``: was die Vorlage zeigt und der
/// Zeichensatz nicht hergibt, wird gemalt. Ein ähnlich aussehendes Zahnrad
/// wäre eine andere Auskunft — es hiesse „Einstellungen", nicht „Ton und
/// Untertitel dieser Wiedergabe".
final class Reglerzeichen: @unchecked Sendable {
    /// **Lebt die Zeichenfläche noch?** Siehe ``Sprungzeichen``: der
    /// Zeichenruf hält `self` nicht, die Fläche tut es.
    fileprivate var lebt = true
    fileprivate let mass: Double
    let anzeige: Widget

    init(mass: Double = 14) {
        self.mass = mass
        let feld: Widget! = gtk_drawing_area_new()
        gtk_widget_add_css_class(feld, "swiftly-blank")
        gtk_drawing_area_set_content_width(alsZeichen(feld), Int32(mass))
        gtk_drawing_area_set_content_height(alsZeichen(feld), Int32(mass))
        anzeige = feld!
        gtk_drawing_area_set_draw_func(alsZeichen(feld), reglerMalen,
                                       Unmanaged.passUnretained(self).toOpaque(), nil)
        beiSignal(feld, "destroy") { self.lebt = false }
    }
}

nonisolated(unsafe) private let reglerMalen: @convention(c) (
    UnsafeMutablePointer<GtkDrawingArea>?, OpaquePointer?, Int32, Int32, gpointer?
) -> Void = { _, cr, breite, hoehe, daten in
    guard let cr, let daten else { return }
    let z = Unmanaged<Reglerzeichen>.fromOpaque(daten).takeUnretainedValue()
    guard z.lebt else { return }

    let w = Double(breite), h = Double(hoehe)
    let strich = max(z.mass * 0.085, 1.0)
    let rand = w * 0.08
    // Drei Schienen auf einem Fünftel-Raster: 1/5, 1/2, 4/5 der Höhe. Die
    // Knäufe stehen versetzt — das ist die ganze Aussage des Zeichens.
    let zeilen: [(y: Double, knauf: Double)] = [
        (h * 0.22, 0.66), (h * 0.50, 0.34), (h * 0.78, 0.72),
    ]
    cairo_set_source_rgba(cr, 1, 1, 1, 1)
    cairo_set_line_width(cr, strich)
    cairo_set_line_cap(cr, CAIRO_LINE_CAP_ROUND)
    for zeile in zeilen {
        cairo_new_path(cr)
        cairo_move_to(cr, rand, zeile.y)
        cairo_line_to(cr, w - rand, zeile.y)
        cairo_stroke(cr)
    }
    // Die Knäufe zuletzt und gefüllt: sie liegen auf der Schiene, nicht
    // daneben, und müssen sie überdecken.
    for zeile in zeilen {
        let x = rand + (w - 2 * rand) * zeile.knauf
        cairo_new_path(cr)
        cairo_arc(cr, x, zeile.y, strich * 1.55, 0, 2 * Double.pi)
        cairo_fill(cr)
    }
}

/// **Ein leerer Kreis — gezeichnet, weil `radio-symbolic` etwas anderes ist.**
///
/// Der Mac setzt in der Auswahlzeile `circle` für die *nicht* gewählte Form
/// (`Sources/macOS/DarstellungView.swift:165`): ein dünner Umriss, das
/// Gegenstück zum Haken. Hier stand `radio-symbolic` — und das ist im
/// Adwaita-Satz **ein Radiogerät mit Antenne**, kein Radioknopf. Am Gerät
/// nachgesehen: neben „Als Chips über den Reihen" stand ein Kofferradio.
///
/// Einen blanken Umriss-Kreis gibt es dort nicht; `radio-checked-symbolic`
/// wäre gefüllt und hiesse „gewählt". Also gemalt, wie ``Sprungzeichen`` und
/// ``Reglerzeichen``.
final class Kreiszeichen: @unchecked Sendable {
    fileprivate var lebt = true
    fileprivate let mass: Double
    let anzeige: Widget

    init(mass: Double = 15) {
        self.mass = mass
        let feld: Widget! = gtk_drawing_area_new()
        gtk_widget_add_css_class(feld, "swiftly-blank")
        gtk_drawing_area_set_content_width(alsZeichen(feld), Int32(mass))
        gtk_drawing_area_set_content_height(alsZeichen(feld), Int32(mass))
        anzeige = feld!
        gtk_drawing_area_set_draw_func(alsZeichen(feld), kreisMalen,
                                       Unmanaged.passUnretained(self).toOpaque(), nil)
        beiSignal(feld, "destroy") { self.lebt = false }
    }
}

nonisolated(unsafe) private let kreisMalen: @convention(c) (
    UnsafeMutablePointer<GtkDrawingArea>?, OpaquePointer?, Int32, Int32, gpointer?
) -> Void = { _, cr, breite, hoehe, daten in
    guard let cr, let daten else { return }
    let z = Unmanaged<Kreiszeichen>.fromOpaque(daten).takeUnretainedValue()
    guard z.lebt else { return }
    let strich = max(z.mass * 0.09, 1.0)
    let r = Double(min(breite, hoehe)) / 2 - strich
    // `schriftSehrLeise` — dieselbe Farbe, die die Zeile ohne Auswahl trägt.
    cairo_set_source_rgba(cr, 1, 1, 1, 0.48)
    cairo_set_line_width(cr, strich)
    cairo_new_path(cr)
    cairo_arc(cr, Double(breite) / 2, Double(hoehe) / 2, r, 0, 2 * Double.pi)
    cairo_stroke(cr)
}
