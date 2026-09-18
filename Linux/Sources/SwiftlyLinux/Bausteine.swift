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
/// Knopf zieht sich dort über das ganze Fenster, und Paul hat das ausdrücklich
/// als Fehler markiert. Hier steht sie von Anfang an richtig.
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

/// Beschriftet einen Hauptknopf **nach**, ohne sein Symbol zu verlieren.
///
/// `gtk_button_set_label` ersetzt das ganze Kind durch eine schlichte
/// Beschriftung — und damit war der Abspielpfeil weg, sobald die Serienseite
/// „Fortsetzen" nachtrug. Der Knopf trägt eine Box aus Symbol und Text; hier
/// wird nur der Text gesetzt.
/// `symbol` setzt zusätzlich das Zeichen davor — der Knopf im Player wechselt
/// zwischen „Vorspann überspringen" und „Nächste Folge", und die beiden tragen
/// **verschiedene** Zeichen: das eine führt in derselben Folge weiter, das
/// andere aus ihr heraus. Dasselbe Zeichen für beides würde den Unterschied
/// verwischen, und der ist der einzige, den man vor dem Druck nicht
/// zurücknehmen kann (`Knopfangebot.zeichen`).
func hauptknopfBeschriften(_ knopf: Widget!, _ text: String, symbol: String? = nil) {
    guard let reihe = gtk_widget_get_first_child(knopf),
          let l = gtk_widget_get_last_child(reihe) else { return }
    gtk_label_set_text(OpaquePointer(l), text)
    if let symbol, let bild = gtk_widget_get_first_child(reihe), bild != l {
        gtk_image_set_from_icon_name(OpaquePointer(bild), symbol)
    }
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
/// Dieselbe Falle wie bei der Wortmarke: `gtk_widget_set_size_request` setzt
/// nur eine **Mindest**größe. Ein Bild von 300 Punkt verlangt 300 und bekommt
/// sie, sobald Platz da ist — die Kacheln standen doppelt so groß im Fenster
/// und das Profilbild hat die Seitenleiste von 220 auf über 700 aufgezogen.
/// `hexpand = 0` hilft nicht: das verteilt überschüssigen Platz, es begrenzt
/// keine Wunschgröße.
///
/// **Erst stand hier ein `GtkScrolledWindow`**, weil der die Wunschgröße
/// seines Kindes nicht nach oben weitergibt. Er tut es, aber er bringt auch
/// Scrollbalken mit — und die meldeten reihenweise
/// `slider reported min width -2`, weil sie in eine 26 Punkt große Kachel
/// nicht hineinpassen. Ein Käfig, der Warnungen ausspuckt, ist kein Käfig.
///
/// `GtkOverlay` kann dasselbe ohne Beiwerk: er **misst nur sein Hauptkind**.
/// Das ist hier eine leere Box mit dem gewünschten Maß; das Bild liegt als
/// Überzug darüber, wird nicht gemessen und bekommt trotzdem die volle
/// Fläche. Genau dafür ist der Überzug da.
///
/// Die Rundung gehört an die Hülle, nicht ans Bild: auf dem Mac ist
/// `Bildflaeche` ein `ZStack` aus Grund, Bild *und* Fortschrittsbalken, und
/// erst der ganze Stapel bekommt `clipShape`. Nur so liegt der Balken
/// **innerhalb** der Rundung und wird beim Schweben mitvergrößert.
///
/// Der Rückgabetyp trägt bewusst kein `!`: Swift verbietet ein implizit
/// ausgepacktes Optional in einem Tupelfach. Beides ist hier nie null.
func gerahmtesBild(breite: Int, hoehe: Int, stil: String) -> (huelle: Widget, bild: Widget) {
    let huelle: Widget! = gtk_overlay_new()
    gtk_widget_add_css_class(huelle, stil)
    gtk_widget_set_overflow(huelle, GTK_OVERFLOW_HIDDEN)
    gtk_widget_set_hexpand(huelle, 0)
    gtk_widget_set_vexpand(huelle, 0)

    // Das Maß gibt eine leere Box vor. Sie ist das Hauptkind, also das
    // einzige, das gemessen wird.
    let mass: Widget! = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0)
    gtk_widget_set_size_request(mass, Int32(breite), Int32(hoehe))
    gtk_overlay_set_child(OpaquePointer(huelle), mass)

    let bild: Widget! = gtk_picture_new()
    gtk_picture_set_content_fit(OpaquePointer(bild), GTK_CONTENT_FIT_COVER)
    gtk_picture_set_can_shrink(OpaquePointer(bild), 1)
    gtk_overlay_add_overlay(OpaquePointer(huelle), bild)
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

/// **Ein Zeichen statt Leere, wenn der Server kein Bild hat.**
///
/// Die Regel steht in `Sources/Shared/HomeView.swift` und ist dort begründet:
/// „Eine leere Flaeche sieht aus wie ein Fehler in der App, und genau so
/// wurde sie gemeldet. Ein Zeichen sagt: hier gehoert ein Bild hin, der
/// Server hat keins."
///
/// Fernseher für alles mit Serie dahinter, Filmstreifen für den Rest — 22
/// groß, sehr leise. Auf dem Mac gibt es das **nicht**; dort bleibt die
/// Fläche leer. Das ist eine Lücke dort, keine Abweichung hier.
func zeichenLegen(_ huelle: Widget!, serie: Bool) {
    let zeichen: Widget! = gtk_image_new_from_icon_name(
        serie ? "tv-symbolic" : "video-x-generic-symbolic")
    gtk_image_set_pixel_size(OpaquePointer(zeichen), 22)
    gtk_widget_add_css_class(zeichen, "swiftly-leise")
    gtk_widget_set_halign(zeichen, GTK_ALIGN_CENTER)
    gtk_widget_set_valign(zeichen, GTK_ALIGN_CENTER)
    gtk_overlay_add_overlay(OpaquePointer(huelle), zeichen)
}

/// **Genau dieses Mass, nicht mehr.**
///
/// `gtk_widget_set_size_request` ist ein Mindestmass — ein Kind darf darüber
/// hinauswachsen, und Beschriftungen tun das: Inter baut höher als SF Pro,
/// also wurde jede Zeile des Heldenblocks ein paar Punkte höher als ihr Fach
/// auf dem Mac, und die Abstände dazwischen wuchsen mit.
///
/// Ein `GtkOverlay` misst **nur sein Hauptkind**. Ist das eine leere Box mit
/// dem gewünschten Mass, steht das Fach fest; der Inhalt liegt als Überzug
/// darin und wird nicht gemessen. Dieselbe Technik wie beim Bildkäfig, nur
/// für Text.
func fach(_ kind: Widget!, breite: Int, hoehe: Int,
          senkrecht: GtkAlign = GTK_ALIGN_CENTER) -> Widget! {
    let huelle: Widget! = gtk_overlay_new()
    let mass: Widget! = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0)
    gtk_widget_set_size_request(mass, Int32(breite), Int32(hoehe))
    gtk_overlay_set_child(OpaquePointer(huelle), mass)
    gtk_widget_set_valign(kind, senkrecht)
    gtk_widget_set_halign(kind, GTK_ALIGN_FILL)
    gtk_overlay_add_overlay(OpaquePointer(huelle), kind)
    gtk_widget_set_overflow(huelle, GTK_OVERFLOW_HIDDEN)
    return huelle
}

// MARK: - Chip

/// Filter- und Sortierchip. Aktiv ist er weiß mit dunkler Schrift, sonst
/// leise mit einer Haarlinie darum — 28 hoch, 12 seitlich, vollrund.
///
/// Die halbfette Schrift im aktiven Zustand steht so auf dem Mac und ist
/// kein Zufall: der Chip wird dadurch minimal breiter, und das ist die
/// einzige Stelle, an der man die Wahl auch ohne Farbe sieht.
func chip(_ text: String, symbol: String? = nil, aktiv: Bool = false) -> Widget! {
    let knopf: Widget! = gtk_button_new()
    gtk_widget_add_css_class(knopf, "swiftly-chip")
    if aktiv { gtk_widget_add_css_class(knopf, "swiftly-aktiv") }
    gtk_widget_set_valign(knopf, GTK_ALIGN_CENTER)
    // Zeichen und Wort im Abstand 6 — die Masse des Macs (`Chip`).
    let reihe = stapel(GTK_ORIENTATION_HORIZONTAL, abstand: 6)
    if let symbol {
        let bild: Widget! = gtk_image_new_from_icon_name(symbol)
        gtk_image_set_pixel_size(OpaquePointer(bild), 12)
        anhaengen(reihe, bild)
    }
    anhaengen(reihe, beschriftung(text))
    gtk_button_set_child(alsKnopf(knopf), reihe)
    return knopf
}

// MARK: - Nebenknopf, Plakette, Reiter

/// Nebenknopf der Knopfreihe: abgerundetes Quadrat, **nur Symbol**, 48 × 48.
///
/// Der Fernseher hat sich bewusst gegen Beschriftungen entschieden —
/// „Merkliste erreicht eigentlich das Merklistensymbol an sich". Aktiv ist er
/// weiß mit dunkler Schrift, sonst Weiß 14 % (schwebend 22 %).
func nebenknopf(_ symbol: String, name: String? = nil, aktiv: Bool = false) -> Widget! {
    let knopf: Widget! = gtk_button_new()
    // E8: ohne Namen ist ein Knopf ohne Beschriftung für eine Vorlesehilfe
    // nur „Taste". Auf dem Mac steht dafür `accessibilityLabel`.
    if let name { beschriften(knopf, name) }
    gtk_widget_add_css_class(knopf, "swiftly-neben")
    if aktiv { gtk_widget_add_css_class(knopf, "swiftly-aktiv") }
    let bild: Widget! = gtk_image_new_from_icon_name(symbol)
    gtk_image_set_pixel_size(OpaquePointer(bild), 17)
    gtk_button_set_child(alsKnopf(knopf), bild)
    gtk_widget_set_size_request(knopf, Int32(Stil.hauptknopfHoehe),
                                Int32(Stil.hauptknopfHoehe))
    return knopf
}

/// Schaltet einen Nebenknopf um. **Der Zustand des Knopfes ist die Antwort**
/// (D6) — es gibt keine Rückfrage und keine Meldung.
func knopfzustand(_ knopf: Widget!, aktiv: Bool, symbol: String) {
    if aktiv { gtk_widget_add_css_class(knopf, "swiftly-aktiv") }
    else { gtk_widget_remove_css_class(knopf, "swiftly-aktiv") }
    let bild: Widget! = gtk_image_new_from_icon_name(symbol)
    gtk_image_set_pixel_size(OpaquePointer(bild), 17)
    gtk_button_set_child(alsKnopf(knopf), bild)
}

/// Die Freigabeplakette — 10 halbfett, 5 × 2 innen, Ecke 3, Haarlinie.
func plakette(_ text: String) -> Widget! {
    let l = beschriftung(text, stil: "swiftly-plakette")
    gtk_widget_set_valign(l, GTK_ALIGN_CENTER)
    return l
}

/// Ein Reiter: 15, aktiv halbfett mit einem 2 Punkt starken Akzentstrich
/// darunter. Die Haarlinie darunter läuft über die volle Breite — die
/// zeichnet der Aufrufer, nicht der Knopf.
func reiterknopf(_ text: String, aktiv: Bool) -> Widget! {
    let knopf: Widget! = gtk_button_new()
    gtk_widget_add_css_class(knopf, "swiftly-reiter")
    if aktiv { gtk_widget_add_css_class(knopf, "swiftly-aktiv") }
    let stapelchen = stapel(GTK_ORIENTATION_VERTICAL, abstand: 8)
    anhaengen(stapelchen, beschriftung(text))
    let strich: Widget! = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0)
    gtk_widget_add_css_class(strich, "swiftly-reiterstrich")
    gtk_widget_set_size_request(strich, -1, 2)
    anhaengen(stapelchen, strich)
    gtk_button_set_child(alsKnopf(knopf), stapelchen)
    return knopf
}

// MARK: - Einstellungszeilen

/// Eine Gruppe von Zeilen: Haarlinie oben, Haarlinie unten, sonst nichts.
/// Keine Karten — dieselbe Entscheidung wie auf dem iPhone.
func zeilengruppe() -> (aussen: Widget, raum: Widget) {
    let aussen = stapel(GTK_ORIENTATION_VERTICAL, abstand: 0)
    anhaengen(aussen, trennlinie())
    let raum = stapel(GTK_ORIENTATION_VERTICAL, abstand: 0)
    anhaengen(aussen, raum)
    anhaengen(aussen, trennlinie())
    return (aussen!, raum!)
}

/// Eine Gruppe mit Überschrift darüber — „QUALITÄT", „SPRACHE", „VERHALTEN".
func einstellungsgruppe(_ titel: String) -> (aussen: Widget, raum: Widget) {
    let aussen = stapel(GTK_ORIENTATION_VERTICAL, abstand: 0)
    let kopf = rubrik(titel)
    gtk_widget_set_margin_start(kopf, 0)
    gtk_widget_set_margin_top(kopf, 26)
    gtk_widget_set_margin_bottom(kopf, 8)
    anhaengen(aussen, kopf)
    let gruppe = zeilengruppe()
    anhaengen(aussen, gruppe.aussen)
    return (aussen!, gruppe.raum)
}

/// Der Trennstrich **innerhalb** einer Gruppe: eingerückt um 48, damit er
/// unter dem Symbol beginnt und nicht davor.
func zeilenstrich() -> Widget! {
    let l = trennlinie()
    gtk_widget_set_margin_start(l, 48)
    return l
}

/// Der Rumpf jeder Zeile: Symbol (22 breit), 14 Abstand, Titel, Unterzeile,
/// rechts etwas. Mindestens 44 hoch, 12 seitlich.
private func zeilenrumpf(symbol: String, titel: String, unter: String?,
                         akzent: Bool, rechts: Widget?) -> Widget! {
    let reihe = stapel(GTK_ORIENTATION_HORIZONTAL, abstand: 14)
    let bild: Widget! = gtk_image_new_from_icon_name(symbol)
    gtk_image_set_pixel_size(OpaquePointer(bild), 15)
    gtk_widget_set_size_request(bild, 22, -1)
    anhaengen(reihe, bild)

    let text = stapel(GTK_ORIENTATION_VERTICAL, abstand: 2)
    gtk_widget_set_valign(text, GTK_ALIGN_CENTER)
    gtk_widget_set_hexpand(text, 1)
    let t = beschriftung(titel, stil: "swiftly-koerper")
    gtk_label_set_xalign(OpaquePointer(t), 0)
    anhaengen(text, t)
    if let unter {
        let u = beschriftung(unter, stil: "swiftly-zweitzeile")
        gtk_widget_add_css_class(u, "swiftly-fuss")
        gtk_label_set_xalign(OpaquePointer(u), 0)
        anhaengen(text, u)
    }
    anhaengen(reihe, text)
    if let rechts { anhaengen(reihe, rechts) }
    if akzent { gtk_widget_add_css_class(reihe, "swiftly-akzentzeile") }
    return reihe
}

/// Eine Zeile mit Wert rechts und optionalem Pfeil.
func wertezeile(symbol: String, titel: String, unter: String? = nil,
                wert: String? = nil, akzent: Bool = false, pfeil: Bool = false,
                auswahl: (() -> Void)? = nil) -> Widget! {
    let rechts = stapel(GTK_ORIENTATION_HORIZONTAL, abstand: 8)
    gtk_widget_set_valign(rechts, GTK_ALIGN_CENTER)
    if let wert, !wert.isEmpty {
        let w = beschriftung(wert, stil: "swiftly-kacheltitel")
        gtk_widget_add_css_class(w, "dim-label")
        anhaengen(rechts, w)
    }
    if pfeil {
        let p: Widget! = gtk_image_new_from_icon_name("go-next-symbolic")
        gtk_image_set_pixel_size(OpaquePointer(p), 12)
        gtk_widget_add_css_class(p, "swiftly-leise")
        anhaengen(rechts, p)
    }
    let rumpf = zeilenrumpf(symbol: symbol, titel: titel, unter: unter,
                            akzent: akzent, rechts: rechts)
    guard let auswahl else {
        gtk_widget_add_css_class(rumpf, "swiftly-zeilenrumpf")
        return rumpf
    }
    let knopf: Widget! = gtk_button_new()
    gtk_widget_add_css_class(knopf, "swiftly-einstellzeile")
    gtk_button_set_child(alsKnopf(knopf), rumpf)
    beiSignal(knopf, "clicked", auswahl)
    return knopf
}

/// Eine Zeile mit Schalter. **Kein `GtkSwitch`** — der bringt die Kapselform,
/// die Farbe und die Maße des Systems mit (E4).
func schalterzeile(symbol: String, titel: String, unter: String? = nil,
                   an: Bool, umgeschaltet: @escaping (Bool) -> Void) -> Widget! {
    var zustand = an
    let schalter: Widget! = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0)
    gtk_widget_add_css_class(schalter, "swiftly-schalter")
    gtk_widget_set_size_request(schalter, 38, 22)
    gtk_widget_set_valign(schalter, GTK_ALIGN_CENTER)
    let knauf: Widget! = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0)
    gtk_widget_add_css_class(knauf, "swiftly-knauf")
    gtk_widget_set_size_request(knauf, 16, 16)
    gtk_widget_set_valign(knauf, GTK_ALIGN_CENTER)
    anhaengen(schalter, knauf)

    func anmalen() {
        if zustand {
            gtk_widget_add_css_class(schalter, "swiftly-aktiv")
            gtk_widget_set_halign(knauf, GTK_ALIGN_END)
        } else {
            gtk_widget_remove_css_class(schalter, "swiftly-aktiv")
            gtk_widget_set_halign(knauf, GTK_ALIGN_START)
        }
    }
    anmalen()

    let knopf: Widget! = gtk_button_new()
    gtk_widget_add_css_class(knopf, "swiftly-einstellzeile")
    gtk_button_set_child(alsKnopf(knopf),
                         zeilenrumpf(symbol: symbol, titel: titel, unter: unter,
                                     akzent: false, rechts: schalter))
    beiSignal(knopf, "clicked") {
        zustand.toggle()
        anmalen()
        umgeschaltet(zustand)
    }
    return knopf
}

/// Die Werteliste. Auf dem iPhone ein Blatt von unten; hier klappt sie
/// **unter der Zeile** auf — „Auswahl bleibt am Ort", dieselbe Regel wie bei
/// der Staffelpille (E5).
func werteliste<W: Equatable>(_ eintraege: [(String, W)], gewaehlt: W,
                              waehlen: @escaping (W) -> Void) -> Widget! {
    let liste = stapel(GTK_ORIENTATION_VERTICAL, abstand: 0)
    gtk_widget_add_css_class(liste, "swiftly-werteliste")
    for (name, wert) in eintraege {
        let knopf: Widget! = gtk_button_new()
        gtk_widget_add_css_class(knopf, "swiftly-wertzeile")
        if wert == gewaehlt { gtk_widget_add_css_class(knopf, "swiftly-aktiv") }
        let reihe = stapel(GTK_ORIENTATION_HORIZONTAL, abstand: 8)
        let l = beschriftung(name, stil: "swiftly-koerper")
        gtk_label_set_xalign(OpaquePointer(l), 0)
        gtk_widget_set_hexpand(l, 1)
        anhaengen(reihe, l)
        if wert == gewaehlt {
            let haken: Widget! = gtk_image_new_from_icon_name("object-select-symbolic")
            gtk_image_set_pixel_size(OpaquePointer(haken), 13)
            anhaengen(reihe, haken)
        }
        gtk_button_set_child(alsKnopf(knopf), reihe)
        beiSignal(knopf, "clicked") { waehlen(wert) }
        anhaengen(liste, knopf)
    }
    return liste
}

/// Senkrechte Luft von fester Höhe.
func luftHoch(_ hoehe: Int32) -> Widget! {
    let l: Widget! = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0)
    gtk_widget_set_size_request(l, -1, hoehe)
    return l
}


// MARK: - Was ein Nachladen überleben muss

/// **Zwischen dem Start einer Aufgabe und ihrer Antwort kann die Seite neu
/// gebaut worden sein.** Dann ist der Zeiger, den die Aufgabe trägt, längst
/// freigegeben — und das Nachtragen greift in fremden Speicher.
///
/// Genau so ist die App am 04.09.2026 gestorben: die Detailseite zeigt sofort
/// den mageren Listeneintrag und baut sich neu, sobald der volle Satz da ist.
/// Wer dazwischen den Plan holte, trug ihn in eine Zeile ein, die es nicht
/// mehr gab. Absturz in libgtk, keine eigene Zeile im Rückweg.
///
/// ``bildLaden`` hält das Bildfeld deshalb seit je fest. Alles andere, was
/// nachträgt, muss dasselbe tun — hier einmal aufgeschrieben.
func gehalten(_ w: Widget!) -> Zeigerkiste {
    g_object_ref(w)
    return Zeigerkiste(w)
}

func losgelassen(_ kiste: Zeigerkiste) {
    g_object_unref(kiste.widget)
}
