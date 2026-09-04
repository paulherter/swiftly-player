import CGtk
import Foundation
import JellyfinKit

/// **Swiftlys Aussehen, in GTKs Sprache übersetzt.**
///
/// Die Zahlen und Farben hier sind keine neuen Entscheidungen — sie stehen so
/// in `Sources/Shared/Farben.swift` und `Sources/macOS/Stil.swift` und gelten
/// auf iPhone, iPad, Apple TV und Mac. Wer eine ändert, ändert sie dort und
/// trägt sie hierher nach; eine zweite Palette wäre der sichere Weg, dass die
/// Plattformen auseinanderlaufen.
///
/// **Der Mac ist die Vorlage, nicht das Gefühl.** Am 04.09.2026 standen hier
/// erst geschätzte Werte, und sie waren zu zweit falsch: die Feldfläche war
/// `erhoeht` (#1E1E22) statt `flaeche` (#161619), und der Hauptknopf trug den
/// Akzent, obwohl er auf dem Mac **weiß mit dunkler Schrift** ist. Beides
/// stand die ganze Zeit in `Macbausteine.swift` — nachgelesen statt geraten
/// wäre billiger gewesen.
///
/// **Warum reines GTK4 und nicht libadwaita.** libadwaita ist GNOMEs
/// Gestaltungsbibliothek: sie sorgt dafür, dass eine App wie eine GNOME-App
/// aussieht. Das arbeitet gegen das Ziel — Swiftly soll auf jedem System wie
/// Swiftly aussehen, nicht wie das System. Dazu kommt, dass libadwaita auf
/// Windows kaum unterstützt wird, und Windows steht auf dem Plan. Alles, was
/// unten steht, ist deshalb einfaches GTK4 mit eigenem Stilblatt.
enum Stil {

    // MARK: Farben, wörtlich aus Farben.swift

    static let grund = "#0B0B0D"
    /// Die Fläche eines Feldes und der Seitenleiste. **Nicht `erhoeht`.**
    static let flaeche = "#161619"
    static let erhoeht = "#1E1E22"
    static let akzent = "#5CD1C2"
    static let markeAkzent = Markenpfade.akzentHex     // #2FDBC0
    static let warnung = "#E8833A"
    static let schrift = "#FFFFFF"
    static let schriftLeise = "rgba(255,255,255,0.62)"
    static let schriftSehrLeise = "rgba(255,255,255,0.38)"
    static let rand = "rgba(255,255,255,0.12)"
    static let linie = "rgba(255,255,255,0.08)"

    // MARK: Maße, wörtlich aus macOS/Stil.swift

    static let ecke = 6
    static let eckeKachel = 8
    /// Felder sind runder als Knöpfe — 10 gegen 6, so wie auf dem iPhone.
    static let eckeFeld = 10
    static let randAbstand = 24
    static let kachelAbstand = 12
    static let reihenAbstand = 28

    static let seitenleisteBreite = 220
    /// Ein Zeiger trifft genauer als ein Finger: Seitenleistenzeilen sind 32
    /// hoch, nicht 44 wie am Telefon.
    static let zeileHoehe = 32
    static let hauptknopfHoehe = 48
    static let feldHoehe = 38
    /// Die Breite des Anmeldeblocks. Auf dem Mac steht `.frame(width: 360)`
    /// an jedem der beiden Felder.
    static let anmeldeBreite = 360
    static let inhaltOben = 52

    /// Poster, 2 : 3 — auf dem iPhone 112 × 168, auf dem Mac 150 × 225.
    static let kachelBreite = 150
    static let kachelHoehe = 225
    /// Weiterschauen liegt quer, 16 : 9.
    static let querBreite = 280
    static let querHoehe = 158

    // MARK: Schriftstufen — dieselbe Abstufung wie iPhone und Mac

    static let titelGross = 28
    static let titel = 22
    static let reihe = 20
    static let listentitel = 15
    static let koerper = 15
    static let kachelTitel = 14
    static let zweitzeile = 12
    static let rubrik = 11

    // MARK: Stilblatt

    /// Wird einmal beim Start geladen und gilt für das ganze Programm.
    ///
    /// GTKs Stilblätter kennen dieselben Begriffe wie im Netz — Farbe,
    /// Rundung, Abstand —, nur die Auswahl geschieht über Widget-Namen statt
    /// über Marken. `.swiftly-*` sind unsere eigenen Klassen; alles ohne
    /// Punkt ist ein GTK-Typ.
    static var blatt: String {
        """
        window, .background, scrolledwindow, viewport, stack {
            background-color: \(grund);
            color: \(schrift);
        }

        label { color: \(schrift); }
        .dim-label { color: \(schriftLeise); }
        .swiftly-leise { color: \(schriftSehrLeise); }
        .swiftly-warnung { color: \(warnung); }

        /* Die Schriftstufen des Macs, eins zu eins. */
        .swiftly-titel-gross { font-size: \(titelGross)px; font-weight: 700; }
        .swiftly-titel       { font-size: \(titel)px; font-weight: 600; }
        .swiftly-reihe       { font-size: \(reihe)px; font-weight: 600; }
        .swiftly-listentitel { font-size: \(listentitel)px; font-weight: 600; }
        .swiftly-koerper     { font-size: \(koerper)px; }
        .swiftly-kacheltitel { font-size: \(kachelTitel)px; font-weight: 500; }
        .swiftly-zweitzeile  { font-size: \(zweitzeile)px; }
        .swiftly-rubrik {
            font-size: \(rubrik)px;
            font-weight: 600;
            letter-spacing: 0.7px;
        }

        /* MARK: Eingabefeld
           Auf dem Mac ein eigener Baustein statt des Systemfeldes: die Fläche
           ist `flaeche`, der Rahmen eine Haarlinie in Weiß 12 %, die Ecke 10.
           Im Fokus wird der Rahmen zum Akzent bei halber Deckung. */
        entry {
            background-color: \(flaeche);
            background-image: none;
            color: \(schrift);
            border: 1px solid \(rand);
            border-radius: \(eckeFeld)px;
            min-height: \(feldHoehe)px;
            padding: 0 12px;
            font-size: \(koerper)px;
            caret-color: \(akzent);
            box-shadow: none;
        }
        entry:focus {
            border-color: rgba(92,209,194,0.5);
            outline: none;
            box-shadow: none;
        }
        entry placeholder, entry text placeholder { color: \(schriftSehrLeise); }
        /* Das Symbol im Feld: 17 breit, dahinter 9 Luft — die Zahlen der
           `Eingabezeile` auf dem Mac. */
        entry image { color: \(schriftSehrLeise); min-width: 17px; margin-right: 9px; }

        /* MARK: Hauptknopf — weiß mit dunkler Schrift, nicht im Akzent. */
        button {
            background-image: none;
            background-color: transparent;
            border: none;
            box-shadow: none;
            color: \(schrift);
            border-radius: \(ecke)px;
            padding: 0;
        }
        button.swiftly-haupt {
            background-color: \(schrift);
            color: \(grund);
            min-height: \(hauptknopfHoehe)px;
            padding: 0 30px;
            font-size: 16px;
            font-weight: 600;
        }
        button.swiftly-haupt:hover { background-color: rgba(255,255,255,0.88); }
        /* Der Mac legt `.opacity(0.4)` über den ganzen Knopf. Dieselbe
           Wirkung, nur ausgerechnet: Weiß zu 40 % über dem Grund. */
        button.swiftly-haupt:disabled {
            background-color: rgba(255,255,255,0.40);
            color: rgba(11,11,13,0.55);
        }

        button.swiftly-flach {
            background-color: transparent;
            color: \(schriftLeise);
            font-size: \(koerper)px;
            min-height: \(zeileHoehe)px;
            padding: 0 10px;
        }
        button.swiftly-flach:hover {
            background-color: rgba(255,255,255,0.06);
            color: \(schrift);
        }

        /* MARK: Seitenleiste
           Fläche wie das Feld, Zeilen 32 hoch. Der Akzent trägt die Auswahl —
           dieselbe Regel wie auf iOS. Der Schwebezustand bekommt bewusst nur
           Weiß: er zeigt „hier steht der Zeiger", keine Wahl. */
        .swiftly-seitenleiste { background-color: \(flaeche); }

        button.swiftly-zeile {
            min-height: \(zeileHoehe)px;
            padding: 0 10px;
            color: \(schriftLeise);
            font-size: \(koerper)px;
            font-weight: 500;
        }
        button.swiftly-zeile:hover {
            background-color: rgba(255,255,255,0.06);
            color: \(schrift);
        }
        button.swiftly-zeile.swiftly-aktiv {
            background-color: rgba(92,209,194,0.10);
            color: \(akzent);
        }
        button.swiftly-zeile image { min-width: 17px; }

        button.swiftly-profil {
            min-height: 40px;
            padding: 0 10px;
        }
        button.swiftly-profil:hover { background-color: rgba(255,255,255,0.06); }

        .swiftly-trennlinie { background-color: \(linie); min-height: 1px; }

        /* Auf dem Mac schwebt die Titelzeile über dem Grund, ohne Kante.
           Dieselbe Wirkung: gleiche Farbe, keine Linie, kein Schatten. */
        headerbar {
            background-color: \(flaeche);
            background-image: none;
            border: none;
            box-shadow: none;
            min-height: 38px;
        }

        /* Plakate: eigener Grund, solange das Bild noch nicht da ist. */
        .swiftly-plakat {
            background-color: \(erhoeht);
            border-radius: \(eckeKachel)px;
        }

        /* Das Raster: GTK malt Auswahl- und Randflächen, die wir nicht
           wollen — es soll nur anordnen. */
        flowbox, flowboxchild {
            background-color: transparent;
            background-image: none;
            padding: 0;
            border: none;
        }
        flowboxchild:selected, flowboxchild:focus { outline: none; box-shadow: none; }

        /* Das Benutzerbild ist rund. 26 Punkt, wie auf dem Mac. */
        .swiftly-profilbild {
            border-radius: 13px;
            background-color: \(erhoeht);
        }

        scrollbar { background-color: transparent; }
        scrollbar slider {
            background-color: rgba(255,255,255,0.22);
            border-radius: 8px;
            min-width: 6px;
            min-height: 6px;
        }
        scrollbar slider:hover { background-color: rgba(255,255,255,0.36); }
        """
    }

    /// Lädt das Stilblatt in die Anzeige.
    static func anwenden() {
        let anbieter = gtk_css_provider_new()
        gtk_css_provider_load_from_string(anbieter, blatt)
        if let anzeige = gdk_display_get_default() {
            // `GtkStyleProvider` ist eine Schnittstelle, kein Typ, den Swift
            // benennen kann — wie `GtkEditable`. Der Anbieter geht deshalb
            // als undurchsichtiger Zeiger hinein.
            gtk_style_context_add_provider_for_display(
                anzeige, OpaquePointer(anbieter),
                800)   // GTK_STYLE_PROVIDER_PRIORITY_APPLICATION
        }
        g_object_unref(UnsafeMutableRawPointer(anbieter))
    }

    // MARK: Wortmarke

    /// Legt die Wortmarke einmal als SVG-Datei ab und gibt den Pfad zurück.
    ///
    /// Der Pfad selbst kommt aus `Markenpfade` im geteilten Paket — dieselbe
    /// Zeichenkette, aus der die Apple-Fassungen ihre Vektorform bauen. GTK
    /// liest SVG über librsvg; fehlt das, gibt es einen Textrückfall.
    static func wortmarkeDatei(hoehe: Int) -> String? {
        let r = Markenpfade.wortmarkeRahmen
        let svg = """
        <svg xmlns="http://www.w3.org/2000/svg" \
        viewBox="\(r.x) \(r.y) \(r.breite) \(r.hoehe)" \
        width="\(Int(Double(hoehe) * r.breite / r.hoehe))" height="\(hoehe)">
        <path d="\(Markenpfade.wortmarke)" fill="\(schrift)"/>
        <path d="\(Markenpfade.wortmarkeAkzent)" fill="\(markeAkzent)"/>
        </svg>
        """
        let ziel = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("swiftly-wortmarke-\(hoehe).svg")
        do {
            try svg.write(to: ziel, atomically: true, encoding: .utf8)
            return ziel.path
        } catch {
            return nil
        }
    }

    /// Die Wortmarke als Widget, in der gewünschten Höhe.
    ///
    /// **44 auf der Anmeldung, 28 in der Seitenleiste** — beides steht so in
    /// `Sources/macOS/RootView.swift` und `HauptView.swift`. Geraten war sie
    /// vorher 64, und das war eineinhalbmal zu groß.
    ///
    /// **Zwei Fallen liegen hier hintereinander.**
    ///
    /// `GtkImage` nimmt seine Größenangabe nur für Symbole; eine geladene
    /// Datei zeigt es in deren eigener Größe und ignoriert den Wunsch. Also
    /// `GtkPicture`.
    ///
    /// Aber `gtk_widget_set_size_request` setzt nur eine **Mindest**größe.
    /// Ein `GtkPicture` wächst darüber hinaus, sobald Platz da ist — deshalb
    /// stand die Marke danach zweieinhalbmal zu groß im Fenster. Es braucht
    /// zusätzlich `hexpand`/`vexpand` auf null und eine Ausrichtung, sonst
    /// nimmt sie sich, was der Stapel ihr anbietet.
    ///
    /// Die Breite folgt dem Seitenverhältnis des Rahmens (3005 zu 1024, also
    /// knapp 2,94 zu 1) statt geraten zu werden.
    static func wortmarke(hoehe: Int = 44, links: Bool = false) -> Widget! {
        let r = Markenpfade.wortmarkeRahmen
        let breite = Int(Double(hoehe) * r.breite / r.hoehe)
        // Doppelt so fein anlegen, damit es auf feinen Bildschirmen scharf bleibt.
        guard let datei = wortmarkeDatei(hoehe: hoehe * 2) else {
            return beschriftung("swiftly", stil: "swiftly-titel-gross")
        }
        let bild: Widget! = gtk_picture_new_for_filename(datei)
        gtk_picture_set_content_fit(OpaquePointer(bild), GTK_CONTENT_FIT_CONTAIN)
        gtk_picture_set_can_shrink(OpaquePointer(bild), 1)
        gtk_widget_set_size_request(bild, Int32(breite), Int32(hoehe))
        gtk_widget_set_hexpand(bild, 0)
        gtk_widget_set_vexpand(bild, 0)
        gtk_widget_set_halign(bild, links ? GTK_ALIGN_START : GTK_ALIGN_CENTER)
        gtk_widget_set_valign(bild, GTK_ALIGN_CENTER)
        return bild
    }
}
