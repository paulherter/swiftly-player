import CGtk
import Foundation
import JellyfinKit

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
///
/// **`dehnt` sagt, ob das Feld seine Spalte füllt.** Auf dem Mac hat
/// `Eingabezeile` gar keine eigene Breite (`macOS/RootView.swift:159-193`) —
/// sie kommt vom Block darum: 360 auf dem Anmeldeschirm, 460 auf den
/// Formularseiten. Hier standen überall feste 360 mit `ALIGN_CENTER`, und
/// damit schwebte in einer 460 Punkt breiten Spalte ein schmaler Streifen in
/// der Mitte.
func eingabezeile(symbol: String, platzhalter: String, geheim: Bool = false,
                  dehnt: Bool = false) -> Widget! {
    let feld: Widget! = gtk_entry_new()
    gtk_entry_set_placeholder_text(alsFeld(feld), platzhalter)
    gtk_entry_set_icon_from_icon_name(alsFeld(feld), GTK_ENTRY_ICON_PRIMARY, symbol)
    // Das Symbol soll nicht anklickbar wirken — es ist Beschriftung, kein Knopf.
    gtk_entry_set_icon_activatable(alsFeld(feld), GTK_ENTRY_ICON_PRIMARY, 0)
    if geheim { gtk_entry_set_visibility(alsFeld(feld), 0) }
    gtk_widget_set_size_request(feld, dehnt ? -1 : Int32(Stil.anmeldeBreite),
                                Int32(Stil.feldHoehe))
    gtk_widget_set_hexpand(feld, dehnt ? 1 : 0)
    gtk_widget_set_halign(feld, dehnt ? GTK_ALIGN_FILL : GTK_ALIGN_CENTER)
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

/// Ein rundes Profilzeichen: Verlauf, darüber das Bild — und **statt** des
/// Bildes der erste Buchstabe des Namens, wenn keines kommt.
///
/// **Der Buchstabe ist Rückfall, nicht Untergrund.** Wortgleich zu
/// `Sources/Shared/Bausteine.swift`, `Profilzeichen`: läge er immer darunter,
/// schiene er bei jedem Konto *mit* Bild kurz durch, bis das Bild da ist. Er
/// wird deshalb erst sichtbar, wenn ``bildLaden`` meldet, dass nichts ankam —
/// dafür gibt es dessen `fertig`-Rückruf.
///
/// Der Verlauf steht im Stilblatt an der übergebenen Klasse; er trägt immer
/// und fällt nicht auf, wenn ein Bild darüberliegt.
func profilzeichen(name: String, kante: Int, stil: String,
                   schriftstil: String) -> (huelle: Widget, bild: Widget, zeichen: Widget) {
    let (huelle, bild) = gerahmtesBild(breite: kante, hoehe: kante, stil: stil)
    let zeichen = beschriftung(String(name.prefix(1)).uppercased(), stil: schriftstil)
    gtk_widget_set_halign(zeichen, GTK_ALIGN_CENTER)
    gtk_widget_set_valign(zeichen, GTK_ALIGN_CENTER)
    gtk_widget_set_visible(zeichen, 0)
    gtk_overlay_add_overlay(OpaquePointer(huelle), zeichen)
    return (huelle, bild, zeichen!)
}

/// Lädt das Profilbild und blendet den Buchstaben ein, wenn keines kommt.
///
/// Ohne Adresse steht der Buchstabe sofort da — dann ist schon klar, dass
/// nichts kommt.
func profilbildLaden(_ teile: (huelle: Widget, bild: Widget, zeichen: Widget),
                     url: URL?, schluessel: String) {
    guard let url else {
        gtk_widget_set_visible(teile.zeichen, 1)
        return
    }
    let kiste = Zeigerkiste(teile.zeichen)
    bildLaden(teile.bild, url: url, schluessel: schluessel, sofort: true) { kam in
        guard !kam else { return }
        gtk_widget_set_visible(kiste.widget, 1)
    }
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
/// - Parameter zeichnung: Ein selbst gemaltes Zeichen statt eines Namens aus
///   dem Zeichensatz — für die Fälle, in denen Adwaita nichts Passendes hat
///   (siehe ``Reglerzeichen``). Hat Vorrang vor `symbol`.
func chip(_ text: String, symbol: String? = nil, aktiv: Bool = false,
          nurSymbol: Bool = false, zeichnung: Widget? = nil) -> Widget! {
    let knopf: Widget! = gtk_button_new()
    gtk_widget_add_css_class(knopf, "swiftly-chip")
    if aktiv { gtk_widget_add_css_class(knopf, "swiftly-aktiv") }
    gtk_widget_set_valign(knopf, GTK_ALIGN_CENTER)
    // Zeichen und Wort im Abstand 6 — die Masse des Macs (`Chip`).
    let reihe = stapel(GTK_ORIENTATION_HORIZONTAL, abstand: 6)
    // **Sonst klebt der Inhalt am linken Rand.**
    //
    // Ein Knopf streckt sein Kind auf die volle Breite; die Reihe wird also
    // so breit wie der Knopf, und das Bild darin sitzt am Anfang, nicht in
    // der Mitte. Bei einem Knopf mit Wort faellt das nicht auf, weil der
    // Inhalt die Breite ohnehin ausfuellt — bei einem Zeichen allein schon:
    // es stand sichtbar links statt mittig. Am Geraet gemeldet.
    gtk_widget_set_halign(reihe, GTK_ALIGN_CENTER)
    if let zeichnung {
        anhaengen(reihe, zeichnung)
    } else if let symbol {
        let bild: Widget! = gtk_image_new_from_icon_name(symbol)
        gtk_image_set_pixel_size(OpaquePointer(bild), 12)
        anhaengen(reihe, bild)
    }
    // **Nur das Zeichen, aber weiter in seiner Kapsel.**
    //
    // In der Werkzeugleiste des Players sagt das Zeichen genug; eine
    // Beschriftung daneben macht die Leiste breiter, ohne etwas zu erklaeren.
    // Der Rahmen bleibt — ein nacktes Zeichen ueber bewegtem Bild sieht aus,
    // als schwebe es dort zufaellig. Woertlich die Aenderung, die die
    // Mac-Fassung am 08.09.2026 bekommen hat.
    //
    // Verloren geht die Beschriftung nicht: sie wird zum Kurzhinweis unter
    // dem Zeiger und zu dem, was eine Vorlesehilfe ansagt (E8).
    if nurSymbol {
        gtk_widget_add_css_class(knopf, "swiftly-nursymbol")
        gtk_widget_set_tooltip_text(knopf, text)
        beschriften(knopf, text)
    } else {
        anhaengen(reihe, beschriftung(text))
    }
    gtk_button_set_child(alsKnopf(knopf), reihe)
    return knopf
}

// MARK: - Nebenknopf, Plakette, Reiter

/// Nebenknopf der Knopfreihe: abgerundetes Quadrat, **nur Symbol**, 48 × 48.
///
/// Der Fernseher hat sich bewusst gegen Beschriftungen entschieden —
/// „Merkliste erreicht eigentlich das Merklistensymbol an sich". Aktiv ist er
/// weiß mit dunkler Schrift, sonst Weiß 14 % (schwebend 22 %).
func nebenknopf(_ symbol: String, name: String? = nil, aktiv: Bool = false,
                zeichnung: Widget? = nil) -> Widget! {
    let knopf: Widget! = gtk_button_new()
    // E8: ohne Namen ist ein Knopf ohne Beschriftung für eine Vorlesehilfe
    // nur „Taste". Auf dem Mac steht dafür `accessibilityLabel`.
    if let name { beschriften(knopf, name) }
    gtk_widget_add_css_class(knopf, "swiftly-neben")
    if aktiv { gtk_widget_add_css_class(knopf, "swiftly-aktiv") }
    if let zeichnung {
        gtk_button_set_child(alsKnopf(knopf), zeichnung)
    } else {
        let bild: Widget! = gtk_image_new_from_icon_name(symbol)
        gtk_image_set_pixel_size(OpaquePointer(bild), 17)
        gtk_button_set_child(alsKnopf(knopf), bild)
    }
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
/// **Eine Karte, keine zwei Striche.**
///
/// Auf dem Mac ist jede Zeilengruppe eine gefuellte Flaeche in `Stil.flaeche`
/// mit `eckeFlaeche` (`macOS/Einstellungszeilen.swift:30`). Hier standen
/// stattdessen eine Linie darueber und eine darunter, sonst nichts — die
/// Zeilen lagen nackt auf dem Seitengrund. Damit sah jede Einstellungsseite
/// anders aus als dieselbe Seite auf dem Mac, und die Gruppen ohne
/// Ueberschrift sahen ueberhaupt nicht wie Gruppen aus.
func zeilengruppe() -> (aussen: Widget, raum: Widget) {
    let aussen = stapel(GTK_ORIENTATION_VERTICAL, abstand: 0)
    gtk_widget_add_css_class(aussen, "swiftly-karte")
    let raum = stapel(GTK_ORIENTATION_VERTICAL, abstand: 0)
    anhaengen(aussen, raum)
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
    gtk_label_set_ellipsize(OpaquePointer(t), PANGO_ELLIPSIZE_END)
    anhaengen(text, t)
    if let unter {
        let u = beschriftung(unter, stil: "swiftly-zweitzeile")
        gtk_widget_add_css_class(u, "swiftly-fuss")
        gtk_label_set_xalign(OpaquePointer(u), 0)
        // **Die Unterzeile darf kuerzen.** Ohne das bestimmt der laengste Satz
        // die Naturbreite der ganzen Spalte — „Download titles to this
        // computer and watch without a connection" zog die Einstellungsseite
        // ueber den Fensterrand, und die rechte Spalte stand draussen.
        gtk_label_set_ellipsize(OpaquePointer(u), PANGO_ELLIPSIZE_END)
        gtk_label_set_max_width_chars(OpaquePointer(u), 34)
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
    // **38 x 22 mit 16er Knauf — und die 46 x 28 waren ein Fehlgriff.**
    //
    // Sie standen hier mit Verweis auf `Stil.swift:795`. Diese Zeile gibt es
    // nur in `Sources/Shared/Stil.swift`, dem iPhone-Blatt: dort ist der
    // Schalter fuer den Finger gebaut. `Sources/macOS/Stil.swift` ist 295
    // Zeilen lang und hat gar keine 795. Der Mac hat seinen eigenen
    // `Schalter` (`Sources/macOS/Einstellungszeilen.swift:128-143`), und der
    // ist ausdruecklich verkleinert — der Dateikopf dort sagt: „Zeilen sind
    // 44 statt 52 hoch … Anders ist nur, was mit dem Zeiger zu tun hat."
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


/// **Ein Platzhalter in der Form dessen, was kommt** (E17).
///
/// Statt eines Laderings, der nur „warte" sagt. Die Seite ist dann leer, nicht
/// am Warten — und wenn die Daten eintreffen, wechselt nichts die Form.
func ladefeld(breite: Int, hoehe: Int, schmal: Bool = false) -> Widget! {
    let feld: Widget! = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0)
    gtk_widget_add_css_class(feld, "swiftly-ladefeld")
    if schmal { gtk_widget_add_css_class(feld, "swiftly-schmal") }
    gtk_widget_set_size_request(feld, Int32(breite), Int32(hoehe))
    gtk_widget_set_halign(feld, GTK_ALIGN_START)
    gtk_widget_set_valign(feld, GTK_ALIGN_START)
    return feld
}

/// Drei Folgenzeilen als Platzhalter — Standbild, Titel, Nebenzeile.
///
/// Die Maße sind die des Macs (`SerienView.swift:327`): 160 x 90 für das
/// Standbild, darüber 220 x 14 und 90 x 11 für die zwei Zeilen.
func folgenPlatzhalter(rand: Int) -> Widget! {
    let block = stapel(GTK_ORIENTATION_VERTICAL, abstand: 18)
    gtk_widget_set_margin_start(block, Int32(rand))
    gtk_widget_set_margin_end(block, Int32(rand))
    for _ in 0 ..< 3 {
        let zeile = stapel(GTK_ORIENTATION_HORIZONTAL, abstand: 16)
        anhaengen(zeile, ladefeld(breite: 160, hoehe: 90))
        let texte = stapel(GTK_ORIENTATION_VERTICAL, abstand: 8)
        gtk_widget_set_valign(texte, GTK_ALIGN_CENTER)
        anhaengen(texte, ladefeld(breite: 220, hoehe: 14, schmal: true))
        anhaengen(texte, ladefeld(breite: 90, hoehe: 11, schmal: true))
        anhaengen(zeile, texte)
        anhaengen(block, zeile)
    }
    return block
}

/// Ein Raster aus Plakatplatzhaltern — für Reiter, die ein Raster füllen.
func rasterPlatzhalter(anzahl: Int = 8, rand: Int) -> Widget! {
    let reihe = stapel(GTK_ORIENTATION_HORIZONTAL, abstand: Int32(Stil.kachelAbstand))
    gtk_widget_set_margin_start(reihe, Int32(rand))
    gtk_widget_set_margin_end(reihe, Int32(rand))
    for _ in 0 ..< anzahl {
        anhaengen(reihe, ladefeld(breite: Stil.kachelBreite, hoehe: Stil.kachelHoehe))
    }
    return reihe
}


/// Zwei Reihen als Platzhalter — Überschrift und Kacheln in ihrer Form.
///
/// Für die Startseite beim allerersten Laden. Danach bleibt stehen, was da
/// ist, und wird ersetzt, sobald die neuen Reihen kommen.
func reihenPlatzhalter(rand: Int) -> Widget! {
    let block = stapel(GTK_ORIENTATION_VERTICAL, abstand: Int32(Stil.reihenAbstand))
    for i in 0 ..< 2 {
        let reihe = stapel(GTK_ORIENTATION_VERTICAL, abstand: 14)
        let kopf = ladefeld(breite: i == 0 ? 190 : 150, hoehe: 20, schmal: true)
        gtk_widget_set_margin_start(kopf, Int32(rand))
        anhaengen(reihe, kopf)
        let quer = i == 0
        let kacheln = stapel(GTK_ORIENTATION_HORIZONTAL, abstand: Int32(Stil.kachelAbstand))
        gtk_widget_set_margin_start(kacheln, Int32(rand))
        gtk_widget_set_margin_end(kacheln, Int32(rand))
        for _ in 0 ..< (quer ? 4 : 6) {
            anhaengen(kacheln, ladefeld(breite: quer ? Stil.querBreite : Stil.kachelBreite,
                                        hoehe: quer ? Stil.querHoehe : Stil.kachelHoehe))
        }
        anhaengen(reihe, kacheln)
        anhaengen(block, reihe)
    }
    return block
}


/// **Die Plakette einer Kachel** (E16) — Haken, offene Folgen oder Staffeln.
///
/// Welche Auskunft gilt, entscheidet ``Anzeigeregeln/kachelmarke(art:staffeln:gesehen:offeneFolgen:)``
/// im Paket: gesehen schlägt alles, offene Folgen schlagen die Staffelzahl,
/// ein ungesehener Film bekommt nichts — eine Zahl, die immer eins wäre, ist
/// keine Auskunft. Der **Wortlaut** steht hier, weil er am Katalog hängt.
func kachelmarkeLegen(_ huelle: Widget!, item: Item) {
    guard let marke = Anzeigeregeln.kachelmarke(art: item.type,
                                                staffeln: item.childCount,
                                                gesehen: item.userData?.played,
                                                offeneFolgen: item.userData?.unplayedItemCount)
    else { return }

    let feld: Widget!
    switch marke {
    case .gesehen:
        feld = gtk_image_new_from_icon_name("object-select-symbolic")
    case .offen(let n):
        // **„6 offen", nicht „6".** Eine nackte Zahl auf einer Kachel sagt
        // nicht, was sie zaehlt — der Mac setzt denselben Wortlaut
        // (`Sources/macOS/Macbausteine.swift:531`, `wortlaut`).
        feld = beschriftung(String(format: uebersetzt("%lld offen"), n))
    case .staffeln(let n):
        feld = beschriftung(n == 1 ? uebersetzt("1 Staffel")
                                   : String(format: uebersetzt("%lld Staffeln"), n))
    }
    gtk_widget_add_css_class(feld, "swiftly-kachelmarke")
    gtk_widget_set_halign(feld, GTK_ALIGN_END)
    gtk_widget_set_valign(feld, GTK_ALIGN_START)
    gtk_overlay_add_overlay(OpaquePointer(huelle), feld)
}


/// Ein kleiner Pfeil- oder Minusknopf am rechten Rand einer Listenzeile.
///
/// **Nicht `insensitive`, wenn er nicht geht** — GTK legt darüber seinen
/// eigenen Schleier, und der sieht aus wie ein Fehler. Stattdessen halbe
/// Deckung und ein Rückruf, der nichts tut; dieselbe Lehre wie beim aktiven
/// Konto im Profil.
func listenpfeil(_ symbol: String, an: Bool, _ tun: @escaping () -> Void) -> Widget! {
    let knopf: Widget! = gtk_button_new()
    gtk_widget_add_css_class(knopf, "swiftly-listenpfeil")
    gtk_button_set_child(alsKnopf(knopf), gtk_image_new_from_icon_name(symbol))
    gtk_widget_set_valign(knopf, GTK_ALIGN_CENTER)
    if !an { gtk_widget_set_opacity(knopf, 0.3) }
    beiSignal(knopf, "clicked") { if an { tun() } }
    return knopf
}

/// Eine Zeile, die eine von mehreren Möglichkeiten trägt — Haken rechts bei
/// der gewählten.
///
/// **Kein `GtkCheckButton`** (E4): der Haken ist ein Zeichen in Akzent, und
/// der Akzent steht hier für Auswahl (E2).
func auswahlzeile(_ text: String, an: Bool, _ tun: @escaping () -> Void) -> Widget! {
    let knopf: Widget! = gtk_button_new()
    gtk_widget_add_css_class(knopf, "swiftly-zeilenrumpf")
    let zeile = stapel(GTK_ORIENTATION_HORIZONTAL, abstand: 10)
    // **Keine eigenen Raender.** `swiftly-zeilenrumpf` traegt schon 44
    // Mindesthoehe und 14 seitlich; die 14/10 hier oben drauf machten die
    // Zeile hoeher als jede andere Zeile derselben Karte.
    // **Das Zeichen steht links, wie auf dem Mac** — Haken bei der gewaehlten,
    // leerer Kreis bei den uebrigen, und die gewaehlte Zeile traegt den Akzent
    // (E2: der Akzent traegt Auswahl).
    //
    // **Der leere Kreis wird gemalt.** Hier stand `radio-symbolic`, und das
    // ist im Adwaita-Satz ein *Kofferradio mit Antenne*. Am Geraet
    // nachgesehen — es stand tatsaechlich eines in der Zeile. Siehe
    // ``Kreiszeichen``.
    let zeichen: Widget!
    if an {
        zeichen = gtk_image_new_from_icon_name("object-select-symbolic")
        gtk_image_set_pixel_size(OpaquePointer(zeichen), 15)
        gtk_widget_add_css_class(zeichen, "swiftly-akzentzeile")
    } else {
        let kreis = Kreiszeichen(mass: 15)
        zeichen = kreis.anzeige
        // Die Zeichenflaeche haelt ihr Zeichen; ohne diesen Zugriff stirbt
        // es beim Verlassen des Aufrufs. Derselbe Fall wie bei ``Kulisse``.
        beiSignal(zeichen, "destroy") { _ = kreis }
    }
    gtk_widget_set_size_request(zeichen, 22, -1)
    gtk_widget_set_valign(zeichen, GTK_ALIGN_CENTER)
    anhaengen(zeile, zeichen)
    let l = beschriftung(text, stil: "swiftly-koerper")
    gtk_label_set_xalign(OpaquePointer(l), 0)
    gtk_widget_set_hexpand(l, 1)
    if an { gtk_widget_add_css_class(l, "swiftly-akzentzeile") }
    anhaengen(zeile, l)
    gtk_button_set_child(alsKnopf(knopf), zeile)
    beiSignal(knopf, "clicked", tun)
    return knopf
}

/// Der Schalter aus ``schalterzeile(symbol:titel:unter:an:umgeschaltet:)``,
/// aber ohne Zeile drumherum — für Listen, die schon eine eigene haben.
///
/// **„Klein" heisst hier ohne Zeile, nicht kleiner.** Der Mac kennt nur eine
/// Baugroesse (`Einstellungszeilen.swift:128`); die Reihenliste in der
/// Darstellung benutzt denselben `Schalter` wie jede andere Zeile.
func kleinerSchalter(an: Bool, _ umgeschaltet: @escaping (Bool) -> Void) -> Widget! {
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
    gtk_widget_add_css_class(knopf, "swiftly-blank")
    gtk_button_set_child(alsKnopf(knopf), schalter)
    gtk_widget_set_valign(knopf, GTK_ALIGN_CENTER)
    beiSignal(knopf, "clicked") {
        zustand.toggle()
        anmalen()
        umgeschaltet(zustand)
    }
    return knopf
}

/// **Zwei Spalten, linksbündig — die Anordnung des Macs.**
///
/// Wiedergabe, Darstellung und Einstellungen tragen sie alle drei
/// (`macOS/WiedergabeEinstellungenView.swift:38` und Geschwister). Der
/// Zwischenraum ist doppelter Seitenrand, damit die Karten zueinander stehen
/// wie zum Fensterrand, und beide Spalten sind gleich breit — sonst zieht die
/// vollere die andere auf einen Streifen zusammen.
///
/// Hier stand dieselbe Rechnung dreimal nicht: nur die Einstellungsseite war
/// zweispaltig, Wiedergabe und Darstellung standen einspaltig in einer
/// schmalen Säule. Drei Seiten, drei Anmutungen — genau die fehlende
/// Kontinuität.
func zweispalter(in block: Widget!) -> (links: Widget, rechts: Widget) {
    let spalten = stapel(GTK_ORIENTATION_HORIZONTAL,
                         abstand: Int32(Stil.randAbstand * 2))
    gtk_widget_set_valign(spalten, GTK_ALIGN_START)
    let links = stapel(GTK_ORIENTATION_VERTICAL, abstand: 0)
    let rechts = stapel(GTK_ORIENTATION_VERTICAL, abstand: 0)
    for spalte in [links, rechts] {
        gtk_widget_set_hexpand(spalte, 1)
        gtk_widget_set_halign(spalte, GTK_ALIGN_FILL)
        gtk_widget_set_valign(spalte, GTK_ALIGN_START)
        gtk_widget_set_size_request(spalte, 300, -1)
        anhaengen(spalten, spalte)
    }
    let gleich = gtk_size_group_new(GTK_SIZE_GROUP_HORIZONTAL)
    gtk_size_group_add_widget(gleich, links)
    gtk_size_group_add_widget(gleich, rechts)
    anhaengen(block, spalten)
    return (links!, rechts!)
}
