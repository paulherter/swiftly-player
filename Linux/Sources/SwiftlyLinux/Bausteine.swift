import CGtk
import Foundation

/// Die Bausteine, die der Mac hat — in GTK nachgebaut, mit seinen Zahlen.
///
/// **Warum nachgebaut und nicht geteilt.** `Macbausteine.swift` ist SwiftUI;
/// davon lässt sich hier nichts benutzen. Was geteilt wird, ist die *Zahl* —
/// jede Größe unten steht in `Stil` und stammt aus `Sources/macOS/Stil.swift`.
/// Wer hier eine ändert, ohne sie dort zu ändern, hat die Plattformen gerade
/// auseinanderlaufen lassen.
///
/// **Die Symbole sind der eine Punkt, an dem es nicht aufgeht.** Apple zeichnet
/// SF Symbols, die es auf Linux nicht gibt und die auch nicht mitgeliefert
/// werden dürfen. Genommen wird deshalb das nächstliegende aus dem
/// Adwaita-Satz; welches wofür steht, ist unten je Stelle vermerkt.

// MARK: - Eingabefeld

/// Ein Feld wie `Eingabezeile` auf dem Mac: Symbol links, 38 hoch, Ecke 10,
/// Haarlinie in Weiß 12 %, im Fokus der Akzent. Die Maße stehen im Stilblatt.
func eingabezeile(symbol: String, platzhalter: String, geheim: Bool = false) -> Widget! {
    let feld: Widget! = gtk_entry_new()
    gtk_entry_set_placeholder_text(alsFeld(feld), platzhalter)
    gtk_entry_set_icon_from_icon_name(alsFeld(feld), GTK_ENTRY_ICON_PRIMARY, symbol)
    // Das Symbol soll nicht anklickbar wirken — es ist Beschriftung, kein Knopf.
    gtk_entry_set_icon_activatable(alsFeld(feld), GTK_ENTRY_ICON_PRIMARY, 0)
    if geheim { gtk_entry_set_visibility(alsFeld(feld), 0) }
    gtk_widget_set_size_request(feld, Int32(Stil.anmeldeBreite), Int32(Stil.feldHoehe))
    gtk_widget_set_hexpand(feld, 0)
    gtk_widget_set_halign(feld, GTK_ALIGN_CENTER)
    return feld
}

// MARK: - Hauptknopf

/// Weiß mit dunkler Schrift, 48 hoch, Symbol und Text mit 9 Abstand.
///
/// **Nicht im Akzent.** Der stand hier zuerst und war falsch: auf dem Mac ist
/// der Hauptknopf `Stil.schrift` auf `Stil.grund`, der Akzent trägt dort
/// ausschließlich Auswahl.
///
/// Die Breite ist die des Anmeldeblocks. Auf dem Mac fehlt sie noch — der
/// Knopf zieht sich dort über das ganze Fenster, und Hier steht sie von Anfang
/// an richtig.
func hauptknopf(_ text: String, symbol: String = "go-next-symbolic") -> Widget! {
    let knopf: Widget! = gtk_button_new()
    gtk_widget_add_css_class(knopf, "swiftly-haupt")
    let reihe = stapel(GTK_ORIENTATION_HORIZONTAL, abstand: 9)
    gtk_widget_set_halign(reihe, GTK_ALIGN_CENTER)
    anhaengen(reihe, gtk_image_new_from_icon_name(symbol))
    anhaengen(reihe, beschriftung(text))
    gtk_button_set_child(alsKnopf(knopf), reihe)
    gtk_widget_set_size_request(knopf, Int32(Stil.anmeldeBreite), Int32(Stil.hauptknopfHoehe))
    gtk_widget_set_hexpand(knopf, 0)
    gtk_widget_set_halign(knopf, GTK_ALIGN_CENTER)
    return knopf
}

// MARK: - Seitenleiste

/// Eine Zeile der Seitenleiste: Symbol (17 breit), 10 Abstand, Beschriftung.
/// 32 hoch, Ecke 6. Aktiv trägt sie den Akzent auf 10 % Akzentfläche.
func seitenleistenzeile(symbol: String, text: String, aktiv: Bool) -> Widget! {
    let knopf: Widget! = gtk_button_new()
    gtk_widget_add_css_class(knopf, "swiftly-zeile")
    if aktiv { gtk_widget_add_css_class(knopf, "swiftly-aktiv") }
    let reihe = stapel(GTK_ORIENTATION_HORIZONTAL, abstand: 10)
    let bild: Widget! = gtk_image_new_from_icon_name(symbol)
    anhaengen(reihe, bild)
    let schrift = beschriftung(text)
    gtk_widget_set_hexpand(schrift, 1)
    gtk_label_set_xalign(OpaquePointer(schrift), 0)
    anhaengen(reihe, schrift)
    gtk_button_set_child(alsKnopf(knopf), reihe)
    return knopf
}

/// „BIBLIOTHEKEN" — 11 halbfett, gesperrt, sehr leise, in Versalien.
///
/// Die Versalien macht hier der Aufrufer, nicht das Stilblatt: GTKs CSS kennt
/// kein `text-transform`.
func rubrik(_ text: String) -> Widget! {
    let l = beschriftung(text.uppercased(), stil: "swiftly-rubrik")
    gtk_widget_add_css_class(l, "swiftly-leise")
    gtk_label_set_xalign(OpaquePointer(l), 0)
    gtk_widget_set_margin_start(l, 10)
    gtk_widget_set_margin_end(l, 10)
    return l
}

/// Die Haarlinie über der Profilzeile.
func trennlinie() -> Widget! {
    let l: Widget! = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0)
    gtk_widget_add_css_class(l, "swiftly-trennlinie")
    gtk_widget_set_size_request(l, -1, 1)
    return l
}

/// Ein waagerechter Abstandhalter — schiebt die Sortierchips nach rechts.
func luftQuer() -> Widget! {
    let l: Widget! = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0)
    gtk_widget_set_hexpand(l, 1)
    return l
}

/// Ein senkrechter Abstandhalter. GTK hat kein `Spacer`, aber eine leere Box
/// mit `vexpand` tut dasselbe.
func luft() -> Widget! {
    let l: Widget! = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0)
    gtk_widget_set_vexpand(l, 1)
    return l
}

// MARK: - Bildkäfig

/// **Ein `GtkPicture` wächst auf die Größe seines Bildes.** Der Käfig hält es
/// auf dem Maß, das dasteht.
///
/// Das ist dieselbe Falle wie bei der Wortmarke, nur an drei weiteren
/// Stellen: `gtk_widget_set_size_request` setzt nur eine **Mindest**größe.
/// Ein Bild von 300 Punkt Breite verlangt 300 und bekommt sie, sobald Platz
/// da ist — die Kacheln standen deshalb doppelt so groß im Fenster, und das
/// Profilbild hat die Seitenleiste von 220 auf über 700 aufgezogen. Mit
/// `hexpand = 0` ist dem nicht beizukommen: das steuert nur, wer *überschüssigen*
/// Platz bekommt, nicht wie groß etwas von sich aus sein will.
///
/// GTK kennt keine Höchstgröße. Was es kennt, ist ein `GtkScrolledWindow`, und
/// der gibt die Wunschgröße seines Kindes **nicht** nach oben weiter
/// (`propagate-natural-width` ist von Haus aus aus). Mit beiden Richtungen auf
/// `NEVER` zwingt er das Kind zudem auf die eigene Größe, statt es zu
/// beschneiden — es wird also skaliert, nicht abgeschnitten.
///
/// Am Bild selbst darf deshalb **keine** Größe stehen: mit `can_shrink` ist
/// seine Mindestgröße null, und dann gilt allein das Maß des Käfigs.
func bildkaefig(_ bild: Widget!, breite: Int, hoehe: Int) -> Widget! {
    gtk_picture_set_can_shrink(OpaquePointer(bild), 1)
    let kaefig: Widget! = gtk_scrolled_window_new()
    gtk_widget_add_css_class(kaefig, "swiftly-kaefig")
    gtk_scrolled_window_set_policy(OpaquePointer(kaefig), GTK_POLICY_NEVER, GTK_POLICY_NEVER)
    gtk_scrolled_window_set_child(OpaquePointer(kaefig), bild)
    gtk_widget_set_size_request(kaefig, Int32(breite), Int32(hoehe))
    gtk_widget_set_hexpand(kaefig, 0)
    gtk_widget_set_vexpand(kaefig, 0)
    gtk_widget_set_overflow(kaefig, GTK_OVERFLOW_HIDDEN)
    return kaefig
}

/// Ein Bild mit gerundeter Kante — Plakat, Querkachel, Profilbild.
///
/// **Die Rundung gehört an die Hülle, nicht an den Käfig.** Auf dem Mac ist
/// `Bildflaeche` ein `ZStack` aus Grund, Bild *und* Fortschrittsbalken, und
/// erst der ganze Stapel bekommt `.clipShape(RoundedRectangle(…))`. Der Balken
/// liegt damit **innerhalb** der Rundung und wird beim Schweben mitvergrößert.
///
/// Hier lag er zuerst daneben — als Geschwister des Käfigs in einem eigenen
/// Überzug. Jetzt ist die Hülle der Überzug: sie trägt Rundung, Beschnitt und
/// Größe, das Bild sitzt darin, der Balken darüber.
///
/// Der Rückgabetyp trägt bewusst kein `!`: Swift verbietet ein implizit
/// ausgepacktes Optional in einem Tupelfach. Beides ist hier nie null.
func gerahmtesBild(breite: Int, hoehe: Int, stil: String) -> (huelle: Widget, bild: Widget) {
    let bild: Widget! = gtk_picture_new()
    gtk_picture_set_content_fit(OpaquePointer(bild), GTK_CONTENT_FIT_COVER)
    let kaefig = bildkaefig(bild, breite: breite, hoehe: hoehe)

    let huelle: Widget! = gtk_overlay_new()
    gtk_overlay_set_child(OpaquePointer(huelle), kaefig)
    gtk_widget_add_css_class(huelle, stil)
    gtk_widget_set_overflow(huelle, GTK_OVERFLOW_HIDDEN)
    gtk_widget_set_size_request(huelle, Int32(breite), Int32(hoehe))
    gtk_widget_set_hexpand(huelle, 0)
    gtk_widget_set_vexpand(huelle, 0)
    return (huelle!, bild!)
}

/// Legt den Fortschrittsbalken unten **in** die Bildhülle.
///
/// Zwei Lagen, wie auf dem Mac: eine Spur in Weiß 16 % über die ganze Breite
/// und darauf der Akzent, so breit wie der gesehene Anteil. Drei Punkt hoch —
/// nicht vier. GTK kennt keinen Anteil als Breitenangabe, aber die Kachel hat
/// eine feste Breite, also lässt er sich ausrechnen.
func balkenLegen(_ huelle: Widget!, breite: Int, anteil: Double) {
    let spur: Widget! = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0)
    gtk_widget_add_css_class(spur, "swiftly-balkenspur")
    gtk_widget_set_size_request(spur, -1, 3)
    gtk_widget_set_valign(spur, GTK_ALIGN_END)
    gtk_widget_set_halign(spur, GTK_ALIGN_FILL)
    gtk_overlay_add_overlay(OpaquePointer(huelle), spur)

    let balken: Widget! = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0)
    gtk_widget_add_css_class(balken, "swiftly-balken")
    gtk_widget_set_size_request(balken, Int32(Double(breite) * min(max(anteil, 0), 1)), 3)
    gtk_widget_set_valign(balken, GTK_ALIGN_END)
    gtk_widget_set_halign(balken, GTK_ALIGN_START)
    gtk_overlay_add_overlay(OpaquePointer(huelle), balken)
}

// MARK: - Chip

/// Filter- und Sortierchip. Aktiv ist er weiß mit dunkler Schrift, sonst
/// leise mit einer Haarlinie darum — 28 hoch, 12 seitlich, vollrund.
///
/// Die halbfette Schrift im aktiven Zustand steht so auf dem Mac und ist
/// kein Zufall: der Chip wird dadurch minimal breiter, und das ist die
/// einzige Stelle, an der man die Wahl auch ohne Farbe sieht.
func chip(_ text: String, aktiv: Bool) -> Widget! {
    let knopf: Widget! = gtk_button_new_with_label(text)
    gtk_widget_add_css_class(knopf, "swiftly-chip")
    if aktiv { gtk_widget_add_css_class(knopf, "swiftly-aktiv") }
    gtk_widget_set_valign(knopf, GTK_ALIGN_CENTER)
    return knopf
}
