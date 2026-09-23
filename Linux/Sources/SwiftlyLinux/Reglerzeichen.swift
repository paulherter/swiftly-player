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

/// **Das Lesezeichen — gezeichnet, weil beide Zeichensätze etwas anderes
/// meinen.**
///
/// Der Mac nimmt `bookmark` und `bookmark.fill` (`DetailView.swift:506`): ein
/// schlichtes Bändchen, leer oder gefüllt. Breeze hat unter
/// `bookmark-new-symbolic` ein Bändchen **mit Pluszeichen** — „neues
/// Lesezeichen anlegen", nicht „auf der Merkliste" —, und
/// `user-bookmarks-symbolic` ist ein Ordner. Beides sagt etwas anderes als
/// die Vorlage, und der Knopf hat zwei Zustände, die sich unterscheiden
/// müssen.
///
/// Dieselbe Antwort wie bei ``Sprungzeichen``, ``Reglerzeichen`` und
/// ``Kreiszeichen``.
final class Merkzeichen: @unchecked Sendable {
    fileprivate var lebt = true
    fileprivate var gefuellt: Bool
    fileprivate let mass: Double
    let anzeige: Widget

    init(gefuellt: Bool, mass: Double = 17) {
        self.gefuellt = gefuellt
        self.mass = mass
        let feld: Widget! = gtk_drawing_area_new()
        gtk_widget_add_css_class(feld, "swiftly-blank")
        gtk_drawing_area_set_content_width(alsZeichen(feld), Int32(mass))
        gtk_drawing_area_set_content_height(alsZeichen(feld), Int32(mass))
        // Mittig, sonst dehnt der Knopf die Flaeche und das Zeichen waechst mit.
        gtk_widget_set_halign(feld, GTK_ALIGN_CENTER)
        gtk_widget_set_valign(feld, GTK_ALIGN_CENTER)
        anzeige = feld!
        gtk_drawing_area_set_draw_func(alsZeichen(feld), merkMalen,
                                       Unmanaged.passUnretained(self).toOpaque(), nil)
        beiSignal(feld, "destroy") { self.lebt = false }
    }

    /// Umschalten, ohne den Knopf neu zu bauen.
    func setzen(_ neu: Bool) {
        guard neu != gefuellt else { return }
        gefuellt = neu
        gtk_widget_queue_draw(anzeige)
    }

    /// **Welche Farbe das Zeichen trägt.** Ein `Nebenknopf` färbt sein Bild
    /// über das Stilblatt; eine Zeichenfläche malt selbst, also muss sie den
    /// Wechsel auf dunkle Schrift bei aktivem Knopf mitmachen.
    fileprivate var dunkel = false
    func aufHellemGrund(_ ja: Bool) {
        guard ja != dunkel else { return }
        dunkel = ja
        gtk_widget_queue_draw(anzeige)
    }
}

nonisolated(unsafe) private let merkMalen: @convention(c) (
    UnsafeMutablePointer<GtkDrawingArea>?, OpaquePointer?, Int32, Int32, gpointer?
) -> Void = { _, cr, breite, hoehe, daten in
    guard let cr, let daten else { return }
    let z = Unmanaged<Merkzeichen>.fromOpaque(daten).takeUnretainedValue()
    guard z.lebt else { return }

    let w = Double(breite), h = Double(hoehe)
    let strich = max(z.mass * 0.088, 1.2)
    // Das Bändchen: 60 % breit, 78 % hoch, mittig, unten eine Kerbe von
    // 22 % der Höhe. Die Verhältnisse sind an `bookmark` abgemessen.
    let bb = w * 0.60, bh = h * 0.78
    let x0 = (w - bb) / 2, y0 = (h - bh) / 2
    let kerbe = bh * 0.22
    let r = strich * 0.9

    cairo_new_path(cr)
    cairo_move_to(cr, x0, y0 + r)
    cairo_arc(cr, x0 + r, y0 + r, r, Double.pi, 1.5 * Double.pi)
    cairo_line_to(cr, x0 + bb - r, y0)
    cairo_arc(cr, x0 + bb - r, y0 + r, r, 1.5 * Double.pi, 2 * Double.pi)
    cairo_line_to(cr, x0 + bb, y0 + bh)
    cairo_line_to(cr, x0 + bb / 2, y0 + bh - kerbe)
    cairo_line_to(cr, x0, y0 + bh)
    cairo_close_path(cr)

    // **Aktiv heisst Akzent am Zeichen** (Mac cb153e7f): der Aktionsknopf
    // bleibt auf `flaeche`, nur das Zeichen wechselt — #50D5DA.
    if z.dunkel { cairo_set_source_rgba(cr, Stil.akzentRGB.0, Stil.akzentRGB.1, Stil.akzentRGB.2, 1) }
    else        { cairo_set_source_rgba(cr, Stil.weissRGB.0, Stil.weissRGB.1, Stil.weissRGB.2, 1) }
    if z.gefuellt {
        cairo_fill(cr)
    } else {
        cairo_set_line_width(cr, strich)
        cairo_set_line_join(cr, CAIRO_LINE_JOIN_ROUND)
        cairo_stroke(cr)
    }
}

/// **Das Filterzeichen — drei Striche, nach unten kuerzer.**
///
/// Der Mac nimmt `line.3.horizontal.decrease` fuer den Filterknopf der
/// Bibliothek (`BibliothekView.swift`). Breeze hat einen Trichter
/// (`view-filter-symbolic`), Adwaita gar nichts — und unter Windows gibt es
/// nur Adwaita. Also gemalt, wie die vier Zeichen davor.
///
/// **Die Farbe kommt vom Stilblatt**, nicht aus dem Zeichen: der Knopf wechselt
/// beim Oeffnen von `schriftLeise` auf `schrift`, und `gtk_widget_get_color`
/// liest genau den Ton, den das Stilblatt der Flaeche gerade gibt.
final class Filterzeichen: @unchecked Sendable {
    fileprivate var lebt = true
    let anzeige: Widget

    init(mass: Int32 = 12) {
        let feld: Widget! = gtk_drawing_area_new()
        gtk_widget_add_css_class(feld, "swiftly-blank")
        gtk_widget_add_css_class(feld, "swiftly-malzeichen")
        gtk_drawing_area_set_content_width(alsZeichen(feld), mass)
        gtk_drawing_area_set_content_height(alsZeichen(feld), mass)
        gtk_widget_set_valign(feld, GTK_ALIGN_CENTER)
        anzeige = feld!
        gtk_drawing_area_set_draw_func(alsZeichen(feld), filterMalen,
                                       Unmanaged.passUnretained(self).toOpaque(), nil)
        beiSignal(feld, "destroy") { self.lebt = false }
    }
}

nonisolated(unsafe) private let filterMalen: @convention(c) (
    UnsafeMutablePointer<GtkDrawingArea>?, OpaquePointer?, Int32, Int32, gpointer?
) -> Void = { flaeche, cr, breite, hoehe, daten in
    guard let cr, let daten else { return }
    let z = Unmanaged<Filterzeichen>.fromOpaque(daten).takeUnretainedValue()
    guard z.lebt else { return }
    var farbe = GdkRGBA()
    gtk_widget_get_color(z.anzeige, &farbe)
    cairo_set_source_rgba(cr, Double(farbe.red), Double(farbe.green),
                          Double(farbe.blue), Double(farbe.alpha))
    let w = Double(breite), h = Double(hoehe)
    let strich = max(w * 0.14, 1.4)
    cairo_set_line_width(cr, strich)
    cairo_set_line_cap(cr, CAIRO_LINE_CAP_ROUND)
    for (i, anteil) in [1.0, 0.64, 0.28].enumerated() {
        let y = h * (0.22 + 0.28 * Double(i))
        let laenge = (w - strich) * anteil
        cairo_move_to(cr, (w - laenge) / 2, y)
        cairo_line_to(cr, (w + laenge) / 2, y)
    }
    cairo_stroke(cr)
}
